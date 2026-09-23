using System.Diagnostics;
using WebCadroid.Types;

namespace WebCadroid.Services;

public class AdbService {
    private readonly string _adbPath = "./Utils/adb";

    public async Task<List<DeviceModel>> GetConnectedDevicesAsync()
    {
        List<DeviceModel> devices = new ();

        string output = await ExecuteAdbCommandAsync("devices");
        string[] lines = output.Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries);

        foreach (var line in lines)
        {
            if (line.StartsWith("List of devices") || string.IsNullOrWhiteSpace(line))
                continue;

            string[] parts = line.Split(new[] { '\t', ' ' }, StringSplitOptions.RemoveEmptyEntries);
            if (parts.Length >= 2 && parts[1] == "device")
            {
                string deviceId = parts[0];
                string deviceName = await GetDeviceNameAsync(deviceId);

                devices.Add(new DeviceModel
                {
                    DeviceId = deviceId,
                    DeviceName = deviceName
                });
            }
        }

        return devices;
    }

    private async Task<string> GetDeviceNameAsync(string deviceId)
    {
        string model = await ExecuteAdbCommandAsync($"-s {deviceId} shell getprop ro.product.model");
        model = model.Trim();

        if (string.IsNullOrEmpty(model))
        {
            return "Unknown Device";
        }

        string brand = await ExecuteAdbCommandAsync($"-s {deviceId} shell getprop ro.product.brand");
        brand = brand.Trim();

        if (!string.IsNullOrEmpty(brand))
        {
            brand = char.ToUpper(brand[0]) + brand.Substring(1);
            return $"{brand} {model}";
        }

        return model;
    }

    private Task<string> ExecuteAdbCommandAsync(string arguments)
    {
        return Task.Run(() =>
        {
            try
            {
                var psi = new ProcessStartInfo
                {
                    FileName = _adbPath,
                    Arguments = arguments,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    UseShellExecute = false,
                    CreateNoWindow = true
                };

                using (var process = Process.Start(psi))
                {
                    if (process == null) return string.Empty;
                    string output = process.StandardOutput.ReadToEnd();
                    process.WaitForExit();
                    return output;
                }
            }
            catch (Exception)
            {
                return string.Empty;
            }
        });
    }
}