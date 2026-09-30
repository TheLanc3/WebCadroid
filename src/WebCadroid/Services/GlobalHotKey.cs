using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;

public class GlobalHotKey : IDisposable {
    private const int WM_HOTKEY = 0x0312;

    [DllImport("user32.dll")]
    private static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);

    [DllImport("user32.dll")]
    private static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    private readonly Window _window;
    private HwndSource? _source;
    private readonly int _id;
    private Action _action;

    public bool IsRegistered { get; private set; }

    public GlobalHotKey(Window window, int id, uint modifierKeys, uint key, Action action) {
        _window = window;
        _id = id;
        _action = action;

        IntPtr handle = new WindowInteropHelper(_window).Handle;
        if (handle == IntPtr.Zero)
            _window.SourceInitialized += (s, e) => Register(modifierKeys, key);
        else
            Register(modifierKeys, key);
    }

    public bool Register(uint modifierKeys, uint key) {
        IntPtr handle = new WindowInteropHelper(_window).Handle;
        _source = HwndSource.FromHwnd(handle);
        _source?.AddHook(HwndHook);

        IsRegistered = RegisterHotKey(handle, _id, modifierKeys, key);
        return IsRegistered;
    }

    public void Unregister() {
        if (!IsRegistered) return;

        IntPtr handle = new WindowInteropHelper(_window).Handle;
        UnregisterHotKey(handle, _id);
        _source?.RemoveHook(HwndHook);
        IsRegistered = false;
    }

    private IntPtr HwndHook(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled) {
        if (msg == WM_HOTKEY && wParam.ToInt32() == _id) {
            _action?.Invoke();
            handled = true;
        }
        return IntPtr.Zero;
    }

    public void Dispose() => Unregister();
}