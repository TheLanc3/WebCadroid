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
    [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    private static extern bool SetDllDirectory(string lpPathName);

    // Softcam C-API imports
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

    private readonly byte[] _pixelBuffer = new byte[BufferSize];
    private readonly object _frameLock = new();

    private IntPtr _camera = IntPtr.Zero;
    private bool _isInitialized;

    public bool IsActive => _isInitialized && _camera != IntPtr.Zero;

    public bool Initialize()
    {
        try
        {
            // Set DLL search directory so softcam.dll is always located correctly
            string utilsDir = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "Utils");
            SetDllDirectory(utilsDir);

            // Register Softcam DirectShow filter if present
            RegisterDll();

            // Create virtual camera instance
            _camera = scCreateCamera(FrameWidth, FrameHeight, FrameRate);

            if (_camera == IntPtr.Zero)
            {
                Debug.WriteLine("[VirtualCamService] Failed to create virtual camera instance.");
                return false;
            }

            _isInitialized = true;
            Debug.WriteLine("[VirtualCamService] Virtual camera initialized successfully.");
            return true;
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[VirtualCamService] Initialization error: {ex.Message}");
            return false;
        }
    }

    public void SendFrame(byte[] jpegBytes)
    {
        if (!IsActive || jpegBytes == null || jpegBytes.Length == 0) return;

        Task.Run(() =>
        {
            lock (_frameLock)
            {
                try
                {
                    using var ms = new MemoryStream(jpegBytes);
                    using var originalBmp = new Bitmap(ms);
                    using var resizedBmp = (originalBmp.Width == FrameWidth && originalBmp.Height == FrameHeight)
                        ? (Bitmap)originalBmp.Clone()
                        : new Bitmap(originalBmp, new Size(FrameWidth, FrameHeight));

                    // DirectShow requires bottom-up BGR24
                    resizedBmp.RotateFlip(RotateFlipType.RotateNoneFlipY);

                    BitmapData data = resizedBmp.LockBits(
                        new Rectangle(0, 0, FrameWidth, FrameHeight),
                        ImageLockMode.ReadOnly,
                        PixelFormat.Format24bppRgb
                    );

                    try
                    {
                        const int bytesPerPixel = 3;
                        int rowSize = FrameWidth * bytesPerPixel;

                        for (int y = 0; y < FrameHeight; y++)
                        {
                            IntPtr sourceRow = IntPtr.Add(data.Scan0, y * data.Stride);
                            Marshal.Copy(sourceRow, _pixelBuffer, y * rowSize, rowSize);
                        }

                        scSendFrame(_camera, _pixelBuffer);
                    }
                    finally
                    {
                        resizedBmp.UnlockBits(data);
                    }
                }
                catch (Exception ex)
                {
                    Debug.WriteLine($"[VirtualCamService] Frame error: {ex.Message}");
                }
            }
        });
    }

    private void RegisterDll()
    {
        string dllPath = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "Utils", "softcam.dll");
        if (!File.Exists(dllPath)) return;

        try
        {
            var startInfo = new ProcessStartInfo
            {
                FileName = "regsvr32.exe",
                Arguments = $"/s \"{dllPath}\"",
                UseShellExecute = true,
                Verb = "runas",
                CreateNoWindow = true
            };

            using var process = Process.Start(startInfo);
            process?.WaitForExit(3000);
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[VirtualCamService] DLL registration note: {ex.Message}");
        }
    }

    public void Dispose()
    {
        lock (_frameLock)
        {
            if (_camera != IntPtr.Zero)
            {
                scDeleteCamera(_camera);
                _camera = IntPtr.Zero;
            }
            _isInitialized = false;
        }
        GC.SuppressFinalize(this);
    }
}