using System.Windows.Input;

namespace WebCadroid.ViewModels;
public class HotKeyModel {
    public Key Key { get; set; }
    public ModifierKeys Modifiers { get; set; }

    public HotKeyModel(Key key, ModifierKeys modifiers) {
        Key = key;
        Modifiers = modifiers;
    }

    public override string ToString() =>
        Modifiers == ModifierKeys.None ? Key.ToString() :
                     $"{Modifiers} + {Key}";
}