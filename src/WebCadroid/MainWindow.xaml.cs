using System.Diagnostics;
using System.IO;
using System.Net.WebSockets;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using WebCadroid.Services;
using WebCadroid.Types;
using WebCadroid.Types.Enums;

namespace WebCadroid;

/// <summary>
/// Interaction logic for MainWindow.xaml
/// </summary>
public partial class MainWindow : Window 
{
    private readonly AdbService _adbService;
    private readonly IVirtualCamService _virtualCamService;
    private readonly DispatcherTimer _refreshTimer;
    private bool _isLoading = false;

    private DeviceModel? _activeDevice = null;
    private CancellationTokenSource? _streamCts;

    private bool _isPreviewTabVisible = false;
    private bool _isPreviewPaused = false;

    public MainWindow() 
    {
        InitializeComponent();

        _adbService = new AdbService();
        _virtualCamService = new VirtualCamService();
        _virtualCamService.Initialize();

        _refreshTimer = new DispatcherTimer
        {
            Interval = TimeSpan.FromSeconds(2)
        };
        _refreshTimer.Tick += async (s, e) => await LoadDevicesAsync();

        Loaded += async (s, e) =>
        {
            await LoadDevicesAsync();
            _refreshTimer.Start();
        };

        Unloaded += (s, e) => _refreshTimer.Stop();
    }

    private async Task LoadDevicesAsync()
    {
        if (_isLoading) return;

        try
        {
            _isLoading = true;
            var fetchedDevices = await _adbService.GetConnectedDevicesAsync();
            var currentDevices = DevicesDataGrid.ItemsSource as List<DeviceModel> ?? new List<DeviceModel>();

            // Update device list while preserving active streaming status
            foreach (var device in fetchedDevices)
            {
                if (_activeDevice != null && device.DeviceId == _activeDevice.DeviceId)
                {
                    device.Status = StreamStatus.Streaming;
                }
            }

            if (!AreDeviceListsEqual(currentDevices, fetchedDevices))
            {
                DevicesDataGrid.ItemsSource = fetchedDevices;
            }
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[MainWindow] Error loading devices: {ex.Message}");
        }
        finally
        {
            _isLoading = false;
        }
    }
    
    private async void ConnectButton_Click(object sender, RoutedEventArgs e)
    {
        var button = sender as Button;
        if (button?.DataContext is not DeviceModel selectedDevice) return;

        // If device is already streaming, disconnect it
        if (selectedDevice.Status == StreamStatus.Streaming)
        {
            StopStream();
            selectedDevice.Status = StreamStatus.Available;
            _activeDevice = null;
            return;
        }

        // If connecting to a new device, stop any currently active stream
        if (_activeDevice != null && _activeDevice != selectedDevice)
        {
            StopStream();
            _activeDevice.Status = StreamStatus.Available;
        }

        _activeDevice = selectedDevice;
        _activeDevice.Status = StreamStatus.Streaming;

        // Start WebSocket video stream
        await StartWebSocketStreamAsync(_activeDevice.DeviceId, 8080);
    }

    private bool AreDeviceListsEqual(List<DeviceModel> list1, List<DeviceModel> list2)
    {
        if (list1.Count != list2.Count) return false;
        
        for (int i = 0; i < list1.Count; i++)
        {
            if (list1[i].DeviceId != list2[i].DeviceId || 
                list1[i].Status != list2[i].Status)
            {
                return false;
            }
        }
        return true;
    }

    private void TitleBar_MouseDown(object sender, MouseButtonEventArgs e) 
    {
        if (e.ChangedButton == MouseButton.Left)
        {
            this.DragMove();
        }
    }

    private void MinimizeButton_Click(object sender, RoutedEventArgs e) 
    {
        this.WindowState = WindowState.Minimized;
    }

    private void CloseButton_Click(object sender, RoutedEventArgs e) 
    {
        this.Close();
    }

    private void SwitchMode_Checked(object sender, RoutedEventArgs e)
    {
        if (DevicesGridBody == null || PreviewContainer == null) return;

        if (DevicesTabRadio.IsChecked == true)
        {
            _isPreviewTabVisible = false;
            DevicesGridBody.Visibility = Visibility.Visible;
            PreviewContainer.Visibility = Visibility.Collapsed;
        }
        else if (PreviewTabRadio.IsChecked == true)
        {
            _isPreviewTabVisible = true;
            DevicesGridBody.Visibility = Visibility.Collapsed;
            PreviewContainer.Visibility = Visibility.Visible;
        }
    }

    private void TogglePreviewButton_Click(object sender, RoutedEventArgs e)
    {
        _isPreviewPaused = !_isPreviewPaused;
        if (_isPreviewPaused)
        {
            TogglePreviewBtn.Content = "Resume Preview";
            PreviewPausedOverlay.Visibility = Visibility.Visible;
        }
        else
        {
            TogglePreviewBtn.Content = "Pause Preview";
            PreviewPausedOverlay.Visibility = Visibility.Collapsed;
        }
    }

    protected override void OnClosed(EventArgs e)
    {
        StopStream();
        _virtualCamService.Dispose();
        base.OnClosed(e);
    }

    private void StopStream()
    {
        _streamCts?.Cancel();
        _streamCts?.Dispose();
        _streamCts = null;

        ShowNoStreamUI();
    }

    private void ShowNoStreamUI()
    {
        Dispatcher.Invoke(() =>
        {
            NoStreamBorder.Visibility = Visibility.Visible;
            StreamImageContainer.Visibility = Visibility.Collapsed;
            StreamImage.Source = null;
            _isPreviewPaused = false;
            TogglePreviewBtn.Content = "Pause Preview";
            PreviewPausedOverlay.Visibility = Visibility.Collapsed;
        });
    }

    private async Task StartWebSocketStreamAsync(string deviceId, int port)
    {
        StopStream();
        _streamCts = new CancellationTokenSource();
        var cancellationToken = _streamCts.Token;

        await Task.Run(async () =>
        {
            ClientWebSocket? ws = null;
            try
            {
                await _adbService.SetupForwardPortAsync(deviceId, port, port);

                ws = new ClientWebSocket();
                using var connectCts = new CancellationTokenSource(TimeSpan.FromSeconds(5));
                using var linkedCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, connectCts.Token);

                await ws.ConnectAsync(new Uri($"ws://127.0.0.1:{port}"), linkedCts.Token);

                if (ws.State != WebSocketState.Open)
                {
                    ShowNoStreamUI();
                    return;
                }

                Dispatcher.Invoke(() =>
                {
                    NoStreamBorder.Visibility = Visibility.Collapsed;
                    StreamImageContainer.Visibility = Visibility.Visible;
                });

                var buffer = new byte[65536];
                using var frameMs = new MemoryStream();

                while (!cancellationToken.IsCancellationRequested && ws.State == WebSocketState.Open)
                {
                    var result = await ws.ReceiveAsync(new ArraySegment<byte>(buffer), cancellationToken);
                    if (result.MessageType == WebSocketMessageType.Close)
                    {
                        break;
                    }

                    frameMs.Write(buffer, 0, result.Count);

                    if (result.EndOfMessage)
                    {
                        byte[] imageBytes = frameMs.ToArray();
                        frameMs.SetLength(0);

                        // 1. Forward frame to virtual camera driver
                        _virtualCamService.SendFrame(imageBytes);

                        // 2. Render preview only when preview tab is visible and preview is not paused
                        if (_isPreviewTabVisible && !_isPreviewPaused)
                        {
                            _ = Dispatcher.BeginInvoke(new Action(() =>
                            {
                                try
                                {
                                    if (_isPreviewTabVisible && !_isPreviewPaused)
                                    {
                                        using var ms = new MemoryStream(imageBytes);
                                        var bitmap = new BitmapImage();
                                        bitmap.BeginInit();
                                        bitmap.CacheOption = BitmapCacheOption.OnLoad;
                                        bitmap.StreamSource = ms;
                                        bitmap.EndInit();
                                        bitmap.Freeze();

                                        StreamImage.Source = bitmap;
                                    }
                                }
                                catch { }
                            }), DispatcherPriority.Render);
                        }
                    }
                }
            }
            catch (Exception ex)
            {
                Debug.WriteLine($"[MainWindow] WebSocket stream terminated: {ex.Message}");
            }
            finally
            {
                if (ws != null)
                {
                    try
                    {
                        if (ws.State == WebSocketState.Open)
                        {
                            await ws.CloseAsync(WebSocketCloseStatus.NormalClosure, "Closing", CancellationToken.None);
                        }
                    }
                    catch { }
                    ws.Dispose();
                }

                ShowNoStreamUI();

                Dispatcher.Invoke(() =>
                {
                    if (_activeDevice != null && _activeDevice.DeviceId == deviceId)
                    {
                        _activeDevice.Status = StreamStatus.Available;
                        _activeDevice = null;
                    }
                });
            }
        }, cancellationToken);
    }
}