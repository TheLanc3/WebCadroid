using System;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading.Tasks;

namespace WebCadroid.Services;

public class VirtualCamService : IVirtualCamService, IDisposable
{
    // Импорт C-API из softcam.dll
    [DllImport("Utils/softcam.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr scCreateCamera(int width, int height, float framerate);

    [DllImport("Utils/softcam.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern void scDeleteCamera(IntPtr camera);

    [DllImport("Utils/softcam.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern void scSendFrame(IntPtr camera, byte[] imageBits);

    [DllImport("Utils/softcam.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern bool scWaitForConnection(IntPtr camera, float timeout);

    [DllImport("Utils/softcam.dll", CallingConvention = CallingConvention.Cdecl)]
    [return: MarshalAs(UnmanagedType.I1)]
    private static extern bool scIsConnected(IntPtr camera);

    private const int FrameWidth = 1280;
    private const int FrameHeight = 720;
    private const float FrameRate = 30.0f;
    private const int BufferSize = FrameWidth * FrameHeight * 3; // BGR24

    private IntPtr _camera = IntPtr.Zero;
    private bool _isInitialized;

    public bool IsActive => _isInitialized && _camera != IntPtr.Zero;

    public bool Initialize()
    {
        try
        {
            // 1. Автоматически регистрируем фильтр в системе через regsvr32
            RegisterDll();

            // 2. Создаем экземпляр виртуальной камеры через экспортируемую функцию
            _camera = scCreateCamera(FrameWidth, FrameHeight, FrameRate);

            if (_camera == IntPtr.Zero)
            {
                Debug.WriteLine("[VirtualCamService] Не удалось создать камеру через scCreateCamera.");
                return false;
            }

            _isInitialized = true;
            Debug.WriteLine("[VirtualCamService] Виртуальная камера Softcam успешно создана!");
            return true;
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[VirtualCamService] Ошибка инициализации P/Invoke: {ex.Message}");
            return false;
        }
    }

    public void SendFrame(byte[] jpegBytes)
    {
        if (!IsActive || jpegBytes == null || jpegBytes.Length == 0) return;

        Task.Run(() =>
        {
            try
            {
                using var ms = new MemoryStream(jpegBytes);
                using var originalBmp = new Bitmap(ms);
                using var resizedBmp = new Bitmap(originalBmp, new Size(FrameWidth, FrameHeight));

                // DirectShow требует BGR24 снизу вверх (Bottom-Up)
                resizedBmp.RotateFlip(RotateFlipType.Rotate180FlipY);

                BitmapData data = resizedBmp.LockBits(
                    new Rectangle(0, 0, FrameWidth, FrameHeight),
                    ImageLockMode.ReadOnly,
                    PixelFormat.Format24bppRgb
                );

                try
                {
                    byte[] pixelBuffer = new byte[BufferSize];

                    // Построчное копирование с учетом Stride (убирает диагональный сдвиг)
                    int bytesPerPixel = 3;
                    int rowSize = FrameWidth * bytesPerPixel;

                    for (int y = 0; y < FrameHeight; y++)
                    {
                        IntPtr sourceRow = IntPtr.Add(data.Scan0, y * data.Stride);
                        Marshal.Copy(sourceRow, pixelBuffer, y * rowSize, rowSize);
                    }

                    scSendFrame(_camera, pixelBuffer);
                }
                finally
                {
                    resizedBmp.UnlockBits(data);
                }
            }
            catch (Exception ex)
            {
                Debug.WriteLine($"[VirtualCamService] Ошибка кадра: {ex.Message}");
            }
        });
    }

    private void RegisterDll()
    {
        string dllPath = Path.Combine("Utils", "softcam.dll");
        if (!File.Exists(dllPath)) return;

        try
        {
            var startInfo = new ProcessStartInfo
            {
                FileName = "regsvr32.exe",
                Arguments = $"/s \"{dllPath}\"",
                UseShellExecute = true,
                Verb = "runas"
            };

            using var process = Process.Start(startInfo);
            process?.WaitForExit(3000);
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[VirtualCamService] Ошибка регистрации: {ex.Message}");
        }
    }

    public void Dispose()
    {
        if (_camera != IntPtr.Zero)
        {
            scDeleteCamera(_camera);
            _camera = IntPtr.Zero;
        }
        _isInitialized = false;
    }
}