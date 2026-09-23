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

namespace WebCadroid;

/// <summary>
/// Interaction logic for MainWindow.xaml
/// </summary>
public partial class MainWindow : Window {
    private readonly AdbService _adbService;
    private readonly DispatcherTimer _refreshTimer;
    private bool _isLoading = false;

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

    private async void LoadDevicesAsync() {
        if (_isLoading) return;

        try
        {
            _isLoading = true;

            var newDevices = await _adbService.GetConnectedDevicesAsync();

            var currentDevices = DevicesDataGrid.ItemsSource as List<DeviceModel>;
            
            if (currentDevices == null || !AreDeviceListsEqual(currentDevices, newDevices))
            {
                DevicesDataGrid.ItemsSource = newDevices;
            }
        }
        finally
        {
            _isLoading = false;
        }
    }

    private bool AreDeviceListsEqual(List<DeviceModel> list1, List<DeviceModel> list2)
    {
        if (list1.Count != list2.Count) return false;
        
        for (int i = 0; i < list1.Count; i++)
        {
            if (list1[i].DeviceId != list2[i].DeviceId || 
                list1[i].DeviceName != list2[i].DeviceName)
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

    private void ConnectButton_Click(object sender, RoutedEventArgs e)
    {
        var button = sender as Button;
        var selectedDevice = button?.DataContext as DeviceModel;
        if (selectedDevice != null)
        {
            MessageBox.Show($"Подключение к: {selectedDevice.DeviceName}");
        }
    }

    private void SwitchMode_Checked(object sender, RoutedEventArgs e)
    {
        var radio = sender as RadioButton;
        if (radio != null)
        {
            // Логика переключения между таблицей и предпросмотром камеры
            // string mode = radio.Content.ToString();
        }
    }
}