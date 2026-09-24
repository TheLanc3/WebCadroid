using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net.WebSockets;
using System.Threading;
using System.Threading.Tasks;
using WebCadroid.Types;
using WebCadroid.Types.Enums;

namespace WebCadroid.Services;

public class AdbService 
{
    private readonly string _adbPath;
    private readonly ConcurrentDictionary<string, string> _deviceNameCache = new();

    public AdbService()
    {
        string baseDir = AppDomain.CurrentDomain.BaseDirectory;
        string exePath = Path.Combine(baseDir, "Utils", "adb.exe");
        if (File.Exists(exePath))
        {
            _adbPath = exePath;
        }
        else
        {
            string fallbackPath = Path.Combine(baseDir, "Utils", "adb");
            _adbPath = File.Exists(fallbackPath) ? fallbackPath : "adb";
        }
    }

    public async Task<List<DeviceModel>> GetConnectedDevicesAsync()
    {
        List<DeviceModel> devices = new();

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
                
                bool isStreaming = await CheckIfDeviceIsStreamingAsync(deviceId);

                devices.Add(new DeviceModel
                {
                    DeviceId = deviceId,
                    DeviceName = deviceName,
                    Status = isStreaming ? StreamStatus.Available : StreamStatus.NotOpened 
                });
            }
        }

        return devices;
    }

    public async Task<bool> CheckIfDeviceIsStreamingAsync(string deviceId, int port = 8080)
    {
        try
        {
            await SetupForwardPortAsync(deviceId, port, port);

            using var ws = new ClientWebSocket();
            using var cts = new CancellationTokenSource(TimeSpan.FromMilliseconds(500));
            
            await ws.ConnectAsync(new Uri($"ws://127.0.0.1:{port}"), cts.Token);
            bool isConnected = ws.State == WebSocketState.Open;

            if (isConnected)
            {
                await ws.CloseAsync(WebSocketCloseStatus.NormalClosure, "Ping", CancellationToken.None);
            }
            return isConnected;
        }
        catch
        {
            return false;
        }
    }

    public async Task SetupForwardPortAsync(string deviceId, int localPort, int devicePort)
    {
        await ExecuteAdbCommandAsync($"-s {deviceId} forward tcp:{localPort} tcp:{devicePort}");
    }

    private async Task<string> GetDeviceNameAsync(string deviceId)
    {
        if (_deviceNameCache.TryGetValue(deviceId, out var cachedName))
        {
            return cachedName;
        }

        string model = await ExecuteAdbCommandAsync($"-s {deviceId} shell getprop ro.product.model");
        model = model.Trim();

        if (string.IsNullOrEmpty(model))
            return "Unknown Device";

        string brand = await ExecuteAdbCommandAsync($"-s {deviceId} shell getprop ro.product.brand");
        brand = brand.Trim();

        string fullName = model;
        if (!string.IsNullOrEmpty(brand))
        {
            brand = char.ToUpper(brand[0]) + brand.Substring(1);
            fullName = $"{brand} {model}";
        }

        _deviceNameCache[deviceId] = fullName;
        return fullName;
    }

    private async Task<string> ExecuteAdbCommandAsync(string arguments)
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

            using var process = Process.Start(psi);
            if (process == null) return string.Empty;

            string output = await process.StandardOutput.ReadToEndAsync();
            await process.WaitForExitAsync();
            return output;
        }
        catch
        {
            return string.Empty;
        }
    }
}