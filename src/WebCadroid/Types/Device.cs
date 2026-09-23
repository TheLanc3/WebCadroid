using System.ComponentModel;
using System.Runtime.CompilerServices;
using WebCadroid.Types.Enums;

namespace WebCadroid.Types;

public class DeviceModel : INotifyPropertyChanged {
    private StreamStatus _status = StreamStatus.NotOpened;
    public string DeviceId { get; set; } = string.Empty;
    public string DeviceName { get; set; } = string.Empty;
    public StreamStatus Status
    {
        get => _status;
        set
        {
            if (_status != value)
            {
                _status = value;
                OnPropertyChanged();
                OnPropertyChanged(nameof(IsConnected));
            }
        }
    }

    public bool IsConnected => Status == StreamStatus.Streaming;

    public event PropertyChangedEventHandler? PropertyChanged;

    protected void OnPropertyChanged([CallerMemberName] string? propertyName = null)
    {
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
    }
}