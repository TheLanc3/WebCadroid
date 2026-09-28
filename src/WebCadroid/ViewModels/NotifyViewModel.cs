using System.ComponentModel;
using System.Windows.Input;
using WebCadroid.Commands;

namespace WebCadroid.ViewModels;

public class NotifyViewModel : ViewModelBase
{
    public ICommand MoveToTrayCommand { get; }

    public NotifyViewModel(NotifyIcon notifyIcon) =>
        MoveToTrayCommand = new MoveToTrayCommand(notifyIcon);
}