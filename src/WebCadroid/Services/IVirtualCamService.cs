using WebCadroid.Types;

namespace WebCadroid.Services;

public interface IVirtualCamService : IDisposable {
    /// <summary>
    /// Initialize a virtual camera service and register the DLL
    /// </summary>
    bool Initialize();

    /// <summary>
    /// Creating virtual camera with attributes: Width, Height and FPS
    /// </summary>
    bool CreateInstance(CameraConfig config);

    /// <summary>
    /// Send a compresseg JPEG into camera
    /// </summary>
    void SendFrame(byte[] jpegBytes, bool isCap = false);

    /// <summary>
    /// Activity status for virtual camera
    /// </summary>
    bool IsActive { get; }
}