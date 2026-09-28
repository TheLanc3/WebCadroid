using System;
using System.Threading.Tasks;

namespace WebCadroid.Services;

public interface IVirtualCamService : IDisposable {
    /// <summary>
    /// Initialize a virtual camera and register the DLL
    /// </summary>
    bool Initialize();

    /// <summary>
    /// Send a compresseg JPEG into camera
    /// </summary>
    void SendFrame(byte[] jpegBytes);

    /// <summary>
    /// Activity status for virtual camera
    /// </summary>
    bool IsActive { get; }
}