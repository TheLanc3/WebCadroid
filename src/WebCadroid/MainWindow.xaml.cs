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
using WebCadroid.Types;

namespace WebCadroid;

/// <summary>
/// Interaction logic for MainWindow.xaml
/// </summary>
public partial class MainWindow : Window {
    public MainWindow()
    {
        InitializeComponent();

        var devices = new List<DeviceModel>
        {
            new DeviceModel { DeviceName = "Pixel 6 Pro", DeviceId = "192.168.1.45:5555" },
            new DeviceModel { DeviceName = "Samsung Galaxy S22", DeviceId = "adb-device-001" },
            new DeviceModel { DeviceName = "Xiaomi Mi 11", DeviceId = "adb-device-002" },
            new DeviceModel { DeviceName = "Pixel 6 Pro", DeviceId = "192.168.1.45:5555" },
            new DeviceModel { DeviceName = "Samsung Galaxy S22", DeviceId = "adb-device-001" },
            new DeviceModel { DeviceName = "Xiaomi Mi 11", DeviceId = "adb-device-002" },
            new DeviceModel { DeviceName = "Pixel 6 Pro", DeviceId = "192.168.1.45:5555" },
            new DeviceModel { DeviceName = "Samsung Galaxy S22", DeviceId = "adb-device-001" },
            new DeviceModel { DeviceName = "Xiaomi Mi 11", DeviceId = "adb-device-002" },
        };

        DevicesDataGrid.ItemsSource = devices;
    }

    /// <summary>
    /// Dragging window be the Top Bar
    /// </summary>
    /// <param name="sender"></param>
    /// <param name="e"></param>
    private void TitleBar_MouseDown(object sender, MouseButtonEventArgs e)
    {
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
    private void MinimizeButton_Click(object sender, RoutedEventArgs e)
    {
        this.WindowState = WindowState.Minimized;
    }

    /// <summary>
    /// Close window logic
    /// </summary>
    /// <param name="sender"></param>
    /// <param name="e"></param>
    private void CloseButton_Click(object sender, RoutedEventArgs e)
    {
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