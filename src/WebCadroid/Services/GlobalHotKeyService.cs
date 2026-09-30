using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Input;
using System.Windows.Interop;
using WebCadroid.ViewModels;

namespace WebCadroid.Services;

public class GlobalHotKeyService : IGlobalHotKeyService {
    private const int WM_HOTKEY = 0x0312;
    private const int HOTKEY_ID = 9000;

    [DllImport("user32.dll")]
    private static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);

    [DllImport("user32.dll")]
    private static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    private readonly Window _window;
    private HwndSource? _source;
    private Action? _action;

    public bool IsRegistered { get; private set; }

    public GlobalHotKeyService(Window window) =>
        _window = window ?? throw new ArgumentNullException(nameof(window));

    public bool Register(HotKeyModel hotKey, Action action) {
        Unregister();

        if (hotKey == null || hotKey.Key == Key.None) return false;

        _action = action;

        IntPtr handle = new WindowInteropHelper(_window).Handle;
        if (handle == IntPtr.Zero) {
            _window.SourceInitialized += (s, e) => DoRegister(hotKey);
            return true;
        }

        return DoRegister(hotKey);
    }

    private bool DoRegister(HotKeyModel hotKey) {
        IntPtr handle = new WindowInteropHelper(_window).Handle;
        _source = HwndSource.FromHwnd(handle);
        _source?.AddHook(HwndHook);

        uint vk = (uint)KeyInterop.VirtualKeyFromKey(hotKey.Key);
        uint modifiers = ConvertModifiers(hotKey.Modifiers);

        IsRegistered = RegisterHotKey(handle, HOTKEY_ID, modifiers, vk);
        return IsRegistered;
    }

    public void Unregister() {
        if (!IsRegistered) return;

        IntPtr handle = new WindowInteropHelper(_window).Handle;
        UnregisterHotKey(handle, HOTKEY_ID);
        _source?.RemoveHook(HwndHook);
        _source = null;
        IsRegistered = false;
    }

    private IntPtr HwndHook(IntPtr hwnd, int msg, 
                IntPtr wParam, IntPtr lParam, ref bool handled) {
        if (msg == WM_HOTKEY && wParam.ToInt32() == HOTKEY_ID) {
            _action?.Invoke();
            handled = true;
        }
        return IntPtr.Zero;
    }

    private uint ConvertModifiers(ModifierKeys wpfModifiers) {
        uint modifiers = 0;
        if (wpfModifiers.HasFlag(ModifierKeys.Alt)) modifiers |= 0x0001;
        if (wpfModifiers.HasFlag(ModifierKeys.Control)) modifiers |= 0x0002;
        if (wpfModifiers.HasFlag(ModifierKeys.Shift)) modifiers |= 0x0004;
        if (wpfModifiers.HasFlag(ModifierKeys.Windows)) modifiers |= 0x0008;
        return modifiers;
    }

    public void Dispose() => Unregister();
}