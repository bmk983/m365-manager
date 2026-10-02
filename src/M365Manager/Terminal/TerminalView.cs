using System.IO;
using System.Text;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Threading;
using M365Manager.Models;
using M365Manager.Services;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.Wpf;

namespace M365Manager.Terminal;

/// <summary>
/// Ein PowerShell-Terminal: xterm.js (in WebView2) als Oberfläche, pwsh in einer ConPTY als Prozess.
/// </summary>
public sealed class TerminalView : Grid, IDisposable
{
    public static readonly string[] ServiceNames = ["Graph", "Exchange", "Purview", "Teams", "SharePoint"];

    private readonly WebView2 _web;
    private readonly Func<AdminProfile> _profile;
    private readonly StringBuilder _pending = new();
    private PtySession? _pty;
    private PipeListener? _pipe;
    private PtySession? _ownerSetFor;
    private int _ownerAttempts;
    private bool _flushScheduled, _initialized, _ready, _starting, _awaitingRestart, _dark = true, _disposed;
    private int _cols = 120, _rows = 30;

    public Dictionary<string, (string State, string? Detail)> States { get; } = new();
    public int Number { get; }
    public string Title => "PowerShell " + Number;

    public event Action<TerminalView>? StatesChanged;
    public event Action<string, string>? ProfileValueReported;

    public TerminalView(Func<AdminProfile> profile, int number, bool dark)
    {
        _profile = profile;
        _dark = dark;
        Number = number;
        ResetStates();
        _web = new WebView2 { DefaultBackgroundColor = BackgroundColor(dark) };
        Children.Add(_web);
        Loaded += async (_, _) => await InitializeAsync();
    }

    private static System.Drawing.Color BackgroundColor(bool dark) =>
        dark ? System.Drawing.Color.FromArgb(0x1c, 0x1c, 0x1f) : System.Drawing.Color.FromArgb(0xfb, 0xfb, 0xfc);

    private async Task InitializeAsync()
    {
        if (_initialized) return;
        _initialized = true;
        try
        {
            var env = await WebViewEnvironments.GetUiAsync();
            await _web.EnsureCoreWebView2Async(env);
        }
        catch (Exception ex)
        {
            Children.Clear();
            Children.Add(new TextBlock { Text = "Terminal konnte nicht gestartet werden: " + ex.Message, Margin = new(16), TextWrapping = System.Windows.TextWrapping.Wrap });
            Log.Write("Terminal WebView2: " + ex);
            return;
        }

        var core = _web.CoreWebView2;
        var s = core.Settings;
        s.AreDefaultContextMenusEnabled = false;
        s.AreBrowserAcceleratorKeysEnabled = false;
        s.IsStatusBarEnabled = false;
        s.IsZoomControlEnabled = false;
        s.AreDevToolsEnabled = false;
        s.IsPasswordAutosaveEnabled = false;
        s.IsGeneralAutofillEnabled = false;

        core.SetVirtualHostNameToFolderMapping("terminal.m365m", AppPaths.TerminalAssetsDir, CoreWebView2HostResourceAccessKind.Deny);
        core.PermissionRequested += (_, e) =>
        {
            if (e.PermissionKind == CoreWebView2PermissionKind.ClipboardRead)
                e.State = CoreWebView2PermissionState.Allow;
        };
        core.NavigationStarting += (_, e) =>
        {
            if (!e.Uri.StartsWith("https://terminal.m365m/", StringComparison.OrdinalIgnoreCase)) e.Cancel = true;
        };
        core.NewWindowRequested += (_, e) => e.Handled = true;
        core.WebMessageReceived += OnWebMessage;
        core.Navigate("https://terminal.m365m/index.html");
    }

    // ------------------------------------------------------------------ Nachrichten aus xterm.js

    private void OnWebMessage(object? sender, CoreWebView2WebMessageReceivedEventArgs e)
    {
        using var doc = JsonDocument.Parse(e.WebMessageAsJson);
        var root = doc.RootElement;
        switch (root.GetProperty("t").GetString())
        {
            case "ready":
                _cols = root.GetProperty("cols").GetInt32();
                _rows = root.GetProperty("rows").GetInt32();
                Post(new { t = "theme", name = _dark ? "dark" : "light" });
                if (!_ready || (_pty is null && !_starting && !_awaitingRestart))
                {
                    _ready = true;
                    _ = StartShellAsync();
                }
                break;

            case "i":
                var data = root.GetProperty("d").GetString() ?? "";
                if (_awaitingRestart)
                {
                    if (data.Contains('\r')) Restart();
                    return;
                }
                _pty?.Write(data);
                break;

            case "r":
                _cols = root.GetProperty("cols").GetInt32();
                _rows = root.GetProperty("rows").GetInt32();
                _pty?.Resize(_cols, _rows);
                break;
        }
    }

    // ------------------------------------------------------------------ Shell

    private async Task StartShellAsync()
    {
        if (_starting || _disposed) return;
        _starting = true;
        try
        {
            if (!SetupService.IsReady)
            {
                WriteLocal("\x1b[90m  PowerShell-Umgebung wird eingerichtet … den Fortschritt siehst du im Startfenster.\x1b[0m\r\n");
                await SetupService.EnsureReadyAsync();
            }

            var pwsh = SetupService.PwshPath;
            if (pwsh is null)
            {
                WriteLocal("\x1b[31m  PowerShell 7 ist nicht verfügbar. Bitte Internetverbindung prüfen.\x1b[0m\r\n\x1b[90m  Enter = erneut versuchen\x1b[0m\r\n");
                _awaitingRestart = true;
                return;
            }

            var profile = _profile();
            _pipe = new PipeListener(line => Dispatcher.BeginInvoke(() => OnHostMessage(line)));

            var bootstrap = Path.Combine(AppPaths.ScriptsDir, "bootstrap.ps1").Replace("'", "''");
            var commandLine = "\"" + pwsh + "\" -NoLogo -NoProfile -NoExit -ExecutionPolicy RemoteSigned -Command \". '" + bootstrap + "'\"";

            var env = new Dictionary<string, string?>
            {
                ["M365M_PROFILE"] = profile.Name,
                ["M365M_COLOR"] = profile.Color,
                ["M365M_UPN"] = profile.Upn,
                ["M365M_TENANT"] = profile.Tenant,
                ["M365M_SPTENANT"] = profile.EffectiveSharePointTenant,
                ["M365M_PNPCLIENTID"] = profile.PnPClientId,
                ["M365M_GRAPHSCOPES"] = profile.GraphScopes,
                ["M365M_PIPE"] = _pipe.Name,
                ["M365M_DATA"] = AppPaths.DataRoot,
                ["M365M_MODULES"] = AppPaths.ModulesDir,
                ["POWERSHELL_TELEMETRY_OPTOUT"] = "1",
                ["POWERSHELL_UPDATECHECK"] = "Off",
                ["COLORTERM"] = "truecolor",
                ["TERM"] = "xterm-256color",
                ["NO_COLOR"] = null, // geerbtes NO_COLOR würde alle Farben im Terminal abschalten
            };

            var pty = PtySession.Start(commandLine, Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), env, _cols, _rows);
            _pty = pty;
            pty.Output += text => OnPtyOutput(pty, text);
            pty.Exited += code => Dispatcher.BeginInvoke(() => OnExited(pty, code));            pty.Run();

        }
        catch (Exception ex)
        {
            Log.Write("Terminal-Start: " + ex);
            WriteLocal("\x1b[31m  Start fehlgeschlagen: " + ex.Message + "\x1b[0m\r\n\x1b[90m  Enter = erneut versuchen\x1b[0m\r\n");
            _awaitingRestart = true;
        }
        finally
        {
            _starting = false;
        }
    }

    private void OnPtyOutput(PtySession source, string text)
    {
        if (!ReferenceEquals(source, _pty)) return;
        lock (_pending)
        {
            _pending.Append(text);
            if (_flushScheduled) return;
            _flushScheduled = true;
        }
        Dispatcher.BeginInvoke(Flush, DispatcherPriority.Background);
    }

    private void Flush()
    {
        string text;
        lock (_pending)
        {
            text = _pending.ToString();
            _pending.Clear();
            _flushScheduled = false;
        }
        if (text.Length > 0) Post(new { t = "o", d = text });
        EnsureConsoleOwner();
    }

    /// <summary>Sobald pwsh läuft: App-Fenster als Besitzer der Pseudokonsole setzen (für Anmeldedialoge).</summary>
    private void EnsureConsoleOwner()
    {
        var pty = _pty;
        if (pty is null || ReferenceEquals(_ownerSetFor, pty) || _ownerAttempts > 10) return;
        var window = Window.GetWindow(this);
        if (window is null) return;
        _ownerAttempts++;
        if (pty.SetConsoleOwner(new WindowInteropHelper(window).Handle))
        {
            _ownerSetFor = pty;
            _ownerAttempts = 0;
        }
        else if (_ownerAttempts > 10)
        {
            Log.Write("Konsolen-Besitzer konnte nicht gesetzt werden (Win32 " + System.Runtime.InteropServices.Marshal.GetLastWin32Error() + ").");
        }
    }

    private void OnExited(PtySession source, int code)
    {
        if (!ReferenceEquals(source, _pty)) return;
        _pty = null;
        source.Dispose();
        _pipe?.Dispose();
        _pipe = null;
        ResetStates();
        StatesChanged?.Invoke(this);
        Flush();
        WriteLocal("\r\n\x1b[90m[PowerShell beendet (Code " + code + ") · Enter startet eine neue Sitzung]\x1b[0m\r\n");
        _awaitingRestart = true;
    }

    private void OnHostMessage(string line)
    {
        var parts = line.Split('|', 4);
        if (parts.Length < 3) return;
        switch (parts[0])
        {
            case "svc":
                States[parts[1]] = (parts[2], parts.Length > 3 ? parts[3] : null);
                StatesChanged?.Invoke(this);
                break;
            case "set":
                ProfileValueReported?.Invoke(parts[1], parts[2]);
                break;
        }
    }

    // ------------------------------------------------------------------ öffentliche API

    public bool IsRunning => _pty is not null;

    public void Restart()
    {
        var old = _pty;
        _pty = null;
        _ownerAttempts = 0;
        old?.Dispose();
        _pipe?.Dispose();
        _pipe = null;
        ResetStates();
        StatesChanged?.Invoke(this);
        lock (_pending) _pending.Clear();
        _awaitingRestart = false;
        Post(new { t = "reset" });
        _ = StartShellAsync();
    }

    /// <summary>Tippt einen Befehl in die Sitzung und führt ihn aus.</summary>
    public void SendCommand(string command)
    {
        if (_pty is null) return;
        _pty.Write(command + "\r");
        FocusTerminal();
    }

    public void FocusTerminal()
    {
        _web.Focus();
        Post(new { t = "focus" });
    }

    public void SetTheme(bool dark)
    {
        _dark = dark;
        _web.DefaultBackgroundColor = BackgroundColor(dark);
        Post(new { t = "theme", name = dark ? "dark" : "light" });
    }

    private void ResetStates()
    {
        foreach (var s in ServiceNames) States[s] = ("disconnected", null);
    }

    private void WriteLocal(string text) => Post(new { t = "o", d = text });

    private void Post(object message)
    {
        if (_disposed || _web.CoreWebView2 is null) return;
        _web.CoreWebView2.PostWebMessageAsJson(JsonSerializer.Serialize(message));
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _pty?.Dispose();
        _pty = null;
        _pipe?.Dispose();
        _web.Dispose();
    }
}