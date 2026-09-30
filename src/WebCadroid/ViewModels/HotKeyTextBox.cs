using TextBox = System.Windows.Controls.TextBox;
using Key = System.Windows.Input.Key;
using Keyboard = System.Windows.Input.Keyboard;
using KeyEventArgs = System.Windows.Input.KeyEventArgs;
using ModifierKeys = System.Windows.Input.ModifierKeys;

namespace WebCadroid.ViewModels;

public class HotKeyTextBox : TextBox {
    public Key SelectedKey { get; private set; }
    public ModifierKeys SelectedModifiers { get; private set; }

    public HotKeyTextBox() {
        IsReadOnly = true;
        Focusable = true;
    }

    protected override void OnPreviewKeyDown(KeyEventArgs e) {
        e.Handled = true;

        Key key = (e.Key == Key.System) ? e.SystemKey : e.Key;

        if (key == Key.LeftShift || key == Key.RightShift ||
            key == Key.LeftCtrl || key == Key.RightCtrl ||
            key == Key.LeftAlt || key == Key.RightAlt ||
            key == Key.LWin || key == Key.RWin)
            return;

        SelectedModifiers = Keyboard.Modifiers;
        SelectedKey = key;

        Text = $"{SelectedModifiers} + {SelectedKey}";
    }
}