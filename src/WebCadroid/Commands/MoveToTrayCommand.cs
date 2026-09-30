namespace WebCadroid.Commands;

public class MoveToTrayCommand : BaseCommand
{
    private readonly NotifyIcon _notifyIcon;

    public MoveToTrayCommand(NotifyIcon notifyIcon) =>
        _notifyIcon = notifyIcon;

    public override void Execute(object? parameter = null) =>
        _notifyIcon.ShowBalloonTip(3000, 
                    "WebCadroid was moved to tray", 
                    "App still is working", 
                    ToolTipIcon.Info);
}
