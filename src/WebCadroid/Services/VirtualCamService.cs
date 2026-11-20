using System.Diagnostics;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;
using WebCadroid.Types;

namespace WebCadroid.Services;

public class VirtualCamService : IVirtualCamService, IDisposable {
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
    private int BufferSize { get => _config.FrameWidth * _config.FrameHeight * 3; } // BGR24

#pragma warning disable CS8618 // Non-nullable field must contain a non-null value when exiting constructor. Consider adding the 'required' modifier or declaring as nullable.
    private byte[] _pixelBuffer;
    private readonly object _frameLock = new();

    private IntPtr _camera = IntPtr.Zero;
    private bool _isInitialized;

    private CameraConfig _config;
#pragma warning restore CS8618 // Non-nullable field must contain a non-null value when exiting constructor. Consider adding the 'required' modifier or declaring as nullable.


    public bool IsActive => _isInitialized && _camera != IntPtr.Zero;

    public bool Initialize() {
        try {
            // Set DLL search directory so softcam.dll is always located correctly
            string utilsDir = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "Utils");
            SetDllDirectory(utilsDir);

            // Register Softcam DirectShow filter if present
            RegisterDll();

            _isInitialized = true;
            Debug.WriteLine("[VirtualCamService] Virtual camera initialized successfully.");
            return true;
        }
        catch (Exception ex) {
            Debug.WriteLine($"[VirtualCamService] Initialization error: {ex.Message}");
            return false;
        }
    }

    public bool CreateInstance(CameraConfig config) {
        DeleteInstance();

        _config = config;
        _pixelBuffer = new byte[BufferSize];
        _camera = scCreateCamera(config.FrameWidth, config.FrameHeight, config.FrameRate);

        if (_camera == IntPtr.Zero) {
            Debug.WriteLine("[VirtualCamService] Failed to create virtual camera instance.");
            return false;
        }

        Debug.WriteLine("[VirtualCamService] Virtual camera instance successfully created.");
        return true;
    }

    private void DeleteInstance() {
        if (_camera != IntPtr.Zero) {
            lock (_frameLock) {
                scDeleteCamera(_camera);
                _camera = IntPtr.Zero;   
            }
        }
    }

    public void SendFrame(byte[] jpegBytes, bool isCap = false) {
        if (!IsActive || jpegBytes == null || jpegBytes.Length == 0) return;

        Task.Run(() => {
            lock (_frameLock) {
                try {
                    using MemoryStream ms = new(jpegBytes);
                    using Bitmap originalBmp = new(ms);
                    using Bitmap resizedBmp = (originalBmp.Width == _config.FrameWidth 
                        && originalBmp.Height == _config.FrameHeight)
                        ? (Bitmap)originalBmp.Clone()
                        : new Bitmap(originalBmp, new Size(_config.FrameWidth, _config.FrameHeight));

                    // DirectShow requires bottom-up BGR24
                    if (!isCap) {
                        if (_config.VerticalFlip)
                            resizedBmp.RotateFlip(RotateFlipType.RotateNoneFlipY);

                        if (_config.HorizontalFlip)
                            resizedBmp.RotateFlip(RotateFlipType.RotateNoneFlipX);
                    }

                    BitmapData data = resizedBmp.LockBits(
                        new Rectangle(0, 0, _config.FrameWidth, _config.FrameHeight),
                        ImageLockMode.ReadOnly,
                        PixelFormat.Format24bppRgb
                    );

                    try {
                        const int bytesPerPixel = 3;
                        int rowSize = _config.FrameWidth * bytesPerPixel;

                        for (int y = 0; y < _config.FrameHeight; y++) {
                            IntPtr sourceRow = IntPtr.Add(data.Scan0, y * data.Stride);
                            Marshal.Copy(sourceRow, _pixelBuffer, y * rowSize, rowSize);
                        }

                        scSendFrame(_camera, _pixelBuffer);
                    }
                    finally {
                        resizedBmp.UnlockBits(data);
                    }
                }
                catch (Exception ex) {
                    Debug.WriteLine($"[VirtualCamService] Frame error: {ex.Message}");
                }
            }
        });
    }

    private void RegisterDll() {
        string dllPath = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "Utils", "softcam.dll");
        if (!File.Exists(dllPath)) return;

        try {
            ProcessStartInfo startInfo = new() {
                FileName = "regsvr32.exe",
                Arguments = $"/s \"{dllPath}\"",
                UseShellExecute = true,
                Verb = "runas",
                CreateNoWindow = true
            };

            using Process? process = Process.Start(startInfo);
            process?.WaitForExit(3000);
        }
        catch (Exception ex) {
            Debug.WriteLine($"[VirtualCamService] DLL registration note: {ex.Message}");
        }
    }

    public void Dispose() {
        lock (_frameLock) {
            DeleteInstance();
            _isInitialized = false;
        }
        GC.SuppressFinalize(this);
    }
}