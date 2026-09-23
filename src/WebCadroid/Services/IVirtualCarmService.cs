using System;
using System.Threading.Tasks;

namespace WebCadroid.Services;

public interface IVirtualCamService : IDisposable
{
    /// <summary>
    /// Инициализирует виртуальную камеру и регистрирует DLL в системе
    /// </summary>
    bool Initialize();

    /// <summary>
    /// Передает сжатый JPEG-кадр в виртуальную камеру
    /// </summary>
    void SendFrame(byte[] jpegBytes);

    /// <summary>
    /// Состояние активности виртуальной камеры
    /// </summary>
    bool IsActive { get; }
}