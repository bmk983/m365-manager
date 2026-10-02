using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Windows.Media;
using M365Manager.Terminal;
using Microsoft.Web.WebView2.Wpf;

namespace M365Manager.Views;

public abstract class Observable : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;

    protected void Set<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return;
        field = value;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
    }

    protected void Raise(string name) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}

public sealed class BrowserTab(WebView2 view) : Observable
{
    private string _title = "Neuer Tab";
    private string _url = "";
    private bool _isSelected;
    private bool _isLoading;
    private ImageSource? _icon;

    public WebView2 View { get; } = view;
    public string? PortalKey { get; set; }

    public string Title { get => _title; set => Set(ref _title, value); }
    public string Url { get => _url; set => Set(ref _url, value); }
    public bool IsSelected { get => _isSelected; set => Set(ref _isSelected, value); }
    public bool IsLoading { get => _isLoading; set => Set(ref _isLoading, value); }
    public ImageSource? Icon { get => _icon; set => Set(ref _icon, value); }
}

public sealed class TerminalTab(TerminalView view) : Observable
{
    private bool _isSelected;

    public TerminalView View { get; } = view;
    public string Title => View.Title;
    public bool IsSelected { get => _isSelected; set => Set(ref _isSelected, value); }
}

public sealed class ServiceChip(string key, string label) : Observable
{
    private static readonly Brush Gray = Frozen(0x8A, 0x8A, 0x94);
    private static readonly Brush Amber = Frozen(0xF5, 0xB0, 0x41);
    private static readonly Brush Green = Frozen(0x4C, 0xC2, 0x5A);
    private static readonly Brush Red = Frozen(0xE8, 0x5A, 0x64);

    private string _state = "disconnected";
    private string? _detail;

    public string Key { get; } = key;
    public string Label { get; } = label;
    public string State => _state;

    public Brush DotBrush => _state switch
    {
        "connected" => Green,
        "connecting" => Amber,
        "error" => Red,
        _ => Gray,
    };

    public string ToolTip => _state switch
    {
        "connected" => Label + ": verbunden" + (string.IsNullOrWhiteSpace(_detail) ? "" : " · " + _detail) + "\nKlick: neu verbinden oder trennen",
        "connecting" => Label + ": verbinde …",
        "error" => Label + ": Fehler – " + _detail + "\nKlick: erneut verbinden",
        _ => Label + ": nicht verbunden\nKlick: jetzt verbinden (passiert sonst automatisch beim ersten Befehl)",
    };

    public void Update(string state, string? detail)
    {
        _state = state;
        _detail = detail;
        Raise(nameof(State));
        Raise(nameof(DotBrush));
        Raise(nameof(ToolTip));
    }

    private static Brush Frozen(byte r, byte g, byte b)
    {
        var brush = new SolidColorBrush(Color.FromRgb(r, g, b));
        brush.Freeze();
        return brush;
    }
}