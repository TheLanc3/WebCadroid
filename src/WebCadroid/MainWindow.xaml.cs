using System.Diagnostics;
using System.IO;
using System.Net.WebSockets;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;

using Forms = System.Windows.Forms;
using Button = System.Windows.Controls.Button;

using WebCadroid.Services;
using WebCadroid.Types;
using WebCadroid.Types.Enums;
using WebCadroid.ViewModels;
using System.Windows.Resources;

namespace WebCadroid;

/// <summary>
/// Interaction logic for MainWindow.xaml
/// </summary>
public partial class MainWindow : Window {
    private readonly AdbService _adbService;
    private readonly IVirtualCamService _virtualCamService;
    private readonly DispatcherTimer _refreshTimer;
    private bool _isLoading = false;
    private Forms.NotifyIcon _notifyIcon;

    private DeviceModel? _activeDevice = null;
    private CancellationTokenSource? _streamCts;

    private bool _isPreviewTabVisible = false;
    private bool _isPreviewPaused = false;

    #pragma warning disable CS8618 // Non-nullable field must contain a non-null value when exiting constructor. Consider adding the 'required' modifier or declaring as nullable.

    public MainWindow() {
        InitializeComponent();
        InitializeNotifyIcon();

        _adbService = new AdbService();
        _virtualCamService = new VirtualCamService();
        _virtualCamService.Initialize();

        ShowStreamCap();

        _refreshTimer = new DispatcherTimer {
            Interval = TimeSpan.FromSeconds(2)
        };
        _refreshTimer.Tick += async (s, e) => await LoadDevicesAsync();

        Loaded += async (s, e) => {
            await LoadDevicesAsync();
            _refreshTimer.Start();
        };

        Unloaded += (s, e) => _refreshTimer.Stop();
    }
#pragma warning restore CS8618 // Non-nullable field must contain a non-null value when exiting constructor. Consider adding the 'required' modifier or declaring as nullable.


    private void InitializeNotifyIcon() {
        _notifyIcon = new() {
            Icon = GetNotifyIcon("inactive"), 
            Visible = false
        };

        _notifyIcon.Click += (sender, e) => {
            this.Show();
            this.WindowState = WindowState.Normal;
            this.Activate();
            _notifyIcon.Visible = false;
        };

        this.DataContext = new NotifyViewModel(_notifyIcon);
    }

    protected override void OnStateChanged(EventArgs e) {
        if (this.WindowState == WindowState.Minimized) {
            this.Hide();
            _notifyIcon.Visible = true;
        }

        base.OnStateChanged(e);
    }

    private async Task LoadDevicesAsync() {
        if (_isLoading) return;

        try {
            _isLoading = true;
            List<DeviceModel> fetchedDevices = 
                await _adbService.GetConnectedDevicesAsync();
            List<DeviceModel> currentDevices = DevicesDataGrid.ItemsSource as List<DeviceModel> ?? new List<DeviceModel>();

            // Update device list while preserving active streaming status
            foreach (DeviceModel device in fetchedDevices)
                if (_activeDevice != null && device.DeviceId == _activeDevice.DeviceId)
                    device.Status = StreamStatus.Streaming;

            if (!AreDeviceListsEqual(currentDevices, fetchedDevices))
                DevicesDataGrid.ItemsSource = fetchedDevices;
        }
        catch (Exception ex) {
            Debug.WriteLine($"[MainWindow] Error loading devices: {ex.Message}");
        }
        finally {
            _isLoading = false;
        }
    }
    private async void ConnectButton_Click(object sender, RoutedEventArgs e) {
        Button button = (Button)sender;
        if (button?.DataContext is not DeviceModel selectedDevice) return;

        // If device is already streaming, disconnect it
        if (selectedDevice.Status == StreamStatus.Streaming) {
            StopStream();
            selectedDevice.Status = StreamStatus.Available;
            _activeDevice = null;
            return;
        }

        // If connecting to a new device, stop any currently active stream
        if (_activeDevice != null && _activeDevice != selectedDevice) {
            StopStream();
            _activeDevice.Status = StreamStatus.Available;
        }

        _activeDevice = selectedDevice;
        _activeDevice.Status = StreamStatus.Streaming;

        // Start WebSocket video stream
        await StartWebSocketStreamAsync(_activeDevice.DeviceId, 8080);
    }
    private bool AreDeviceListsEqual(List<DeviceModel> list1, 
                                    List<DeviceModel> list2) {
        if (list1.Count != list2.Count) return false;
        
        for (int i = 0; i < list1.Count; i++)
            if (list1[i].DeviceId != list2[i].DeviceId || 
                list1[i].Status != list2[i].Status)
                return false;
        return true;
    }
    private void TitleBar_MouseDown(object sender, MouseButtonEventArgs e) {
        if (e.ChangedButton == MouseButton.Left)
            this.DragMove();
    }

    private void MinimizeButton_Click(object sender, RoutedEventArgs e) {
        this.Hide();
        _notifyIcon.Visible = true;
    }

    private void CloseButton_Click(object sender, RoutedEventArgs e) => this.Close();

    private void SwitchMode_Checked(object sender, RoutedEventArgs e) {
        if (DevicesGridBody == null || PreviewContainer == null) return;

        if (DevicesTabRadio.IsChecked == true) {
            _isPreviewTabVisible = false;
            DevicesGridBody.Visibility = Visibility.Visible;
            PreviewContainer.Visibility = Visibility.Collapsed;
        }
        else if (PreviewTabRadio.IsChecked == true) {
            _isPreviewTabVisible = true;
            DevicesGridBody.Visibility = Visibility.Collapsed;
            PreviewContainer.Visibility = Visibility.Visible;
        }
    }

    private void TogglePreviewButton_Click(object sender, RoutedEventArgs e) {
        _isPreviewPaused = !_isPreviewPaused;
        if (_isPreviewPaused) {
            TogglePreviewBtn.Content = "Resume Preview";
            PreviewPausedOverlay.Visibility = Visibility.Visible;
        }
        else {
            TogglePreviewBtn.Content = "Pause Preview";
            PreviewPausedOverlay.Visibility = Visibility.Collapsed;
        }
    }

    protected override void OnClosed(EventArgs e) {
        StopStream();
        _virtualCamService.Dispose();
        _notifyIcon?.Dispose();
        base.OnClosed(e);
    }

    private void StopStream() {
        _streamCts?.Cancel();
        _streamCts?.Dispose();
        _streamCts = null;
        
        _notifyIcon.Icon = GetNotifyIcon("inactive");
        
        ShowStreamCap();
        ShowNoStreamUI();
    }

    private void ShowNoStreamUI() {
        Dispatcher.Invoke(() => {
            NoStreamBorder.Visibility = Visibility.Visible;
            StreamImageContainer.Visibility = Visibility.Collapsed;
            StreamImage.Source = null;
            _isPreviewPaused = false;
            TogglePreviewBtn.Content = "Pause Preview";
            PreviewPausedOverlay.Visibility = Visibility.Collapsed;
        });
    }

    private Icon GetNotifyIcon(string type) 
    {
        Uri resourceUri = new($"Resources/NotifyIcons/webcadroid-{type}.ico", UriKind.Relative);
        StreamResourceInfo imageStream = System.Windows.Application.GetResourceStream(resourceUri);

        using Stream stream = imageStream.Stream;
        return new Icon(stream);
    }

    private void ShowStreamCap() {
        Uri resourceUri = new("Resources/WebCadroidNoStream.png", UriKind.Relative);
        StreamResourceInfo imageStream = 
            System.Windows.Application.GetResourceStream(resourceUri);
        using MemoryStream imageMs = new();

        imageStream.Stream.CopyTo(imageMs);
        byte[] imageBytes = imageMs.ToArray();
        imageMs.SetLength(0);

        _virtualCamService.SendFrame(imageBytes);
    }
    private async Task StartWebSocketStreamAsync(string deviceId, int port) {
        StopStream();
        _streamCts = new CancellationTokenSource();
        CancellationToken cancellationToken = _streamCts.Token;
        _notifyIcon.Icon = GetNotifyIcon("stream");

        await Task.Run(async () => {
            ClientWebSocket? ws = null;
            try {
                await _adbService.SetupForwardPortAsync(deviceId, port, port);

                ws = new ClientWebSocket();
                using CancellationTokenSource connectCts = new(TimeSpan.FromSeconds(5));
                using CancellationTokenSource linkedCts = 
                    CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, connectCts.Token);

                await ws.ConnectAsync(new Uri($"ws://127.0.0.1:{port}"), linkedCts.Token);

                if (ws.State != WebSocketState.Open) {
                    ShowNoStreamUI();
                    return;
                }

                Dispatcher.Invoke(() => {
                    NoStreamBorder.Visibility = Visibility.Collapsed;
                    StreamImageContainer.Visibility = Visibility.Visible;
                });

                byte[] buffer = new byte[65536];
                using MemoryStream frameMs = new();

                while (!cancellationToken.IsCancellationRequested 
                        && ws.State == WebSocketState.Open) {
                    WebSocketReceiveResult result = await ws.ReceiveAsync(
                            new ArraySegment<byte>(buffer), cancellationToken);

                    if (result.MessageType == WebSocketMessageType.Close)
                        break;

                    frameMs.Write(buffer, 0, result.Count);

                    if (result.EndOfMessage) {
                        byte[] imageBytes = frameMs.ToArray();
                        frameMs.SetLength(0);

                        // 1. Forward frame to virtual camera driver
                        _virtualCamService.SendFrame(imageBytes);

                        // 2. Render preview only when preview tab is visible and preview is not paused
                        if (_isPreviewTabVisible && !_isPreviewPaused) {
                            _ = Dispatcher.BeginInvoke(new Action(() => {
                                try {
                                    if (_isPreviewTabVisible 
                                        && !_isPreviewPaused) {
                                        using MemoryStream ms = new(imageBytes);
                                        BitmapImage bitmap = new ();
                                        bitmap.BeginInit();
                                        bitmap.CacheOption = BitmapCacheOption.OnLoad;
                                        bitmap.StreamSource = ms;
                                        bitmap.EndInit();
                                        bitmap.Freeze();

                                        TransformedBitmap flippedBitmap = new(bitmap,
                                                            new ScaleTransform(1, -1));
                                        flippedBitmap.Freeze();

                                        StreamImage.Source = flippedBitmap;
                                    }
                                }
                                catch { }
                            }), DispatcherPriority.Render);
                        }
                    }
                }
            }
            catch (Exception ex) {
                Debug.WriteLine($"[MainWindow] WebSocket stream terminated: {ex.Message}");
            }
            finally {
                if (ws != null) {
                    try {
                        if (ws.State == WebSocketState.Open)
                            await ws.CloseAsync(WebSocketCloseStatus.NormalClosure,
                                "Closing", CancellationToken.None);
                    }
                    catch { }
                    ws.Dispose();
                }

                ShowNoStreamUI();

                Dispatcher.Invoke(() => {
                    if (_activeDevice != null 
                        && _activeDevice.DeviceId == deviceId) {
                        _activeDevice.Status = StreamStatus.Available;
                        _activeDevice = null;
                    }
                });
            }
        }, cancellationToken);
    }
}