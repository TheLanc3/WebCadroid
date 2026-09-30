using WebCadroid.ViewModels;

namespace WebCadroid.Services;

public interface IGlobalHotKeyService : IDisposable {
    bool Register(HotKeyModel hotKey, Action action);
    void Unregister();
    bool IsRegistered { get; }
}