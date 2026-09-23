using System.IO;
using System.Net.Http;
using System.Text;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Navigation;
using System.Windows.Shapes;
using System.Windows.Threading;
using WebCadroid.Services;
using WebCadroid.Types;
using WebCadroid.Types.Enums;

namespace WebCadroid;

/// <summary>
/// Interaction logic for MainWindow.xaml
/// </summary>
public partial class MainWindow : Window {
    private readonly AdbService _adbService;
    private readonly DispatcherTimer _refreshTimer;
    private bool _isLoading = false;

    private DeviceModel? _activeDevice = null;

    private CancellationTokenSource? _streamCts;

    public MainWindow() {
        InitializeComponent();

        _adbService = new AdbService();
        _refreshTimer = new DispatcherTimer
        {
            Interval = TimeSpan.FromSeconds(2)
        };
        _refreshTimer.Tick += async (s, e) => LoadDevicesAsync();

        Loaded += (s, e) =>
        {
            LoadDevicesAsync();
            _refreshTimer.Start();
        };

        Unloaded += (s, e) => _refreshTimer.Stop();
        LoadDevicesAsync();
    }

    private async Task LoadDevicesAsync()
    {
        if (_isLoading) return;

        try
        {
            _isLoading = true;
            var fetchedDevices = await _adbService.GetConnectedDevicesAsync();
            var currentDevices = DevicesDataGrid.ItemsSource as List<DeviceModel> ?? new List<DeviceModel>();

            // Обновляем список устройств с сохранением статуса подключенного девайса
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
        finally
        {
            _isLoading = false;
        }
    }
    
    private async void ConnectButton_Click(object sender, RoutedEventArgs e)
    {
        var button = sender as Button;
        if (button?.DataContext is not DeviceModel selectedDevice) return;

        // Если устройство уже стримит — отключаем его
        if (selectedDevice.Status == StreamStatus.Streaming)
        {
            StopStream();
            selectedDevice.Status = StreamStatus.Available;
            _activeDevice = null;
            return;
        }

        // Если подключаемся к новому — останавливаем текущий активный стрим (если был)
        if (_activeDevice != null && _activeDevice != selectedDevice)
        {
            StopStream();
            _activeDevice.Status = StreamStatus.Available;
        }

        // Подключаемся к выбранному устройству
        _activeDevice = selectedDevice;
        _activeDevice.Status = StreamStatus.Streaming;

        // Запускаем видеопоток
        await StartMjpegStreamAsync(_activeDevice.DeviceId, 8080);
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

    /// <summary>
    /// Dragging window be the Top Bar
    /// </summary>
    /// <param name="sender"></param>
    /// <param name="e"></param>
    private void TitleBar_MouseDown(object sender, MouseButtonEventArgs e) {
        if (e.ChangedButton == MouseButton.Left)
        {
            this.DragMove();
        }
    }

    /// <summary>
    /// Minimize window logic
    /// </summary>
    /// <param name="sender"></param>
    /// <param name="e"></param>
    private void MinimizeButton_Click(object sender, RoutedEventArgs e) {
        this.WindowState = WindowState.Minimized;
    }

    /// <summary>
    /// Close window logic
    /// </summary>
    /// <param name="sender"></param>
    /// <param name="e"></param>
    private void CloseButton_Click(object sender, RoutedEventArgs e) {
        this.Close();
    }

    private void SwitchMode_Checked(object sender, RoutedEventArgs e)
    {
        if (DevicesDataGrid == null || PreviewContainer == null) return;

        if (DevicesTabRadio.IsChecked == true)
        {
            DevicesDataGrid.Visibility = Visibility.Visible;
            PreviewContainer.Visibility = Visibility.Collapsed;
        }
        else if (PreviewTabRadio.IsChecked == true)
        {
            DevicesDataGrid.Visibility = Visibility.Collapsed;
            PreviewContainer.Visibility = Visibility.Visible;
        }
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
            StreamImage.Visibility = Visibility.Collapsed;
            StreamImage.Source = null;
        });
    }

    private async Task StartMjpegStreamAsync(string deviceId, int port)
    {
        StopStream();
        _streamCts = new CancellationTokenSource();

        await Task.Run(async () =>
        {
            try
            {
                await _adbService.SetupForwardPortAsync(deviceId, port, port);

                using var client = new HttpClient();
                using var response = await client.GetAsync($"http://127.0.0.1:{port}/stream", 
                    HttpCompletionOption.ResponseHeadersRead, _streamCts.Token);

                if (!response.IsSuccessStatusCode)
                {
                    ShowNoStreamUI();
                    return;
                }

                Dispatcher.Invoke(() =>
                {
                    NoStreamBorder.Visibility = Visibility.Collapsed;
                    StreamImage.Visibility = Visibility.Visible;
                });

                using var stream = await response.Content.ReadAsStreamAsync(_streamCts.Token);
                
                // Читаем поток эффективными блоками
                var readBuffer = new byte[8192];
                var frameBuffer = new MemoryStream();
                bool frameStarted = false;
                byte prevByte = 0;

                while (!_streamCts.Token.IsCancellationRequested)
                {
                    int bytesRead = await stream.ReadAsync(readBuffer, 0, readBuffer.Length, _streamCts.Token);
                    if (bytesRead == 0) break;

                    for (int i = 0; i < bytesRead; i++)
                    {
                        byte currentByte = readBuffer[i];

                        if (!frameStarted)
                        {
                            // Ищем маркер начала JPEG: 0xFF, 0xD8
                            if (prevByte == 0xFF && currentByte == 0xD8)
                            {
                                frameStarted = true;
                                frameBuffer.SetLength(0);
                                frameBuffer.WriteByte(0xFF);
                                frameBuffer.WriteByte(0xD8);
                            }
                        }
                        else
                        {
                            frameBuffer.WriteByte(currentByte);

                            // Ищем маркер конца JPEG: 0xFF, 0xD9
                            if (prevByte == 0xFF && currentByte == 0xD9)
                            {
                                frameStarted = false;
                                
                                // Создаем копию байтов кадра для WPF
                                byte[] imageBytes = frameBuffer.ToArray();

                                _ = Dispatcher.BeginInvoke(new Action(() =>
                                {
                                    try
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
                                    catch { }
                                }), DispatcherPriority.Render);
                            }
                        }
                        prevByte = currentByte;
                    }
                }
            }
            catch
            {
                ShowNoStreamUI();
            }
        }, _streamCts.Token);
    }

    /// <summary>
    /// Асинхронный парсинг JPEG с помощью ReadAsync (не блокирует поток)
    /// </summary>
    private async Task<MemoryStream> ReadJpegFrameAsync(Stream stream, CancellationToken token)
    {
        var ms = new MemoryStream();
        byte[] buffer = new byte[1]; // Побайтовое асинхронное чтение
        int prevByte = -1;
        bool frameStarted = false;

        while (!token.IsCancellationRequested)
        {
            int bytesRead = await stream.ReadAsync(buffer, 0, 1, token);
            if (bytesRead == 0) break;

            int currentByte = buffer[0];

            if (!frameStarted)
            {
                // Начало JPEG: 0xFF, 0xD8
                if (prevByte == 0xFF && currentByte == 0xD8)
                {
                    frameStarted = true;
                    ms.WriteByte(0xFF);
                    ms.WriteByte(0xD8);
                }
            }
            else
            {
                ms.WriteByte((byte)currentByte);

                // Конец JPEG: 0xFF, 0xD9
                if (prevByte == 0xFF && currentByte == 0xD9)
                {
                    ms.Position = 0;
                    return ms;
                }
            }
            prevByte = currentByte;
        }

        return null!;
    }
    private void ShowNoStreamState()
    {
        Dispatcher.Invoke(() =>
        {
            NoStreamBorder.Visibility = Visibility.Visible;
            StreamImage.Visibility = Visibility.Collapsed;
            StreamImage.Source = null;
        });
    }
}