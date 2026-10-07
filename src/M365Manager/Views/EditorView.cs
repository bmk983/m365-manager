using System.IO;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Controls;
using M365Manager.Services;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.Wpf;

namespace M365Manager.Views;

/// <summary>Skript-Editor (Monaco in WebView2) mit Datei-Zugriff, IntelliSense und Ausführen im Terminal.</summary>
public sealed class EditorView : Grid, IDisposable
{
    private const string FileFilter = "PowerShell-Skript (*.ps1)|*.ps1|PowerShell-Modul (*.psm1)|*.psm1|Manifest (*.psd1)|*.psd1|Alle Dateien (*.*)|*.*";

    private readonly WebView2 _web;
    private readonly string _profileId;
    private bool _dark, _initialized, _disposed;

    /// <summary>Ausführen: Modus ("all"/"selection"), Code, Pfad (nur bei gespeicherter, unveränderter Datei), Name.</summary>
    public Action<string, string, string?, string>? RunRequested { get; set; }
    public Action? StopRequested { get; set; }
    public int DirtyCount { get; private set; }

    public EditorView(string profileId, bool dark)
    {
        _profileId = profileId;
        _dark = dark;
        _web = new WebView2 { DefaultBackgroundColor = dark ? System.Drawing.Color.FromArgb(0x1c, 0x1c, 0x1f) : System.Drawing.Color.FromArgb(0xfb, 0xfb, 0xfc) };
        Children.Add(_web);
        Loaded += async (_, _) => await InitializeAsync();
    }

    private async Task InitializeAsync()
    {
        if (_initialized) return;
        _initialized = true;
        try
        {
            await _web.EnsureCoreWebView2Async(await WebViewEnvironments.GetUiAsync());
        }
        catch (Exception ex)
        {
            Children.Clear();
            Children.Add(new TextBlock { Text = "Editor konnte nicht gestartet werden: " + ex.Message, Margin = new Thickness(16), TextWrapping = TextWrapping.Wrap });
            Log.Write("Editor WebView2: " + ex);
            return;
        }

        var core = _web.CoreWebView2;
        var s = core.Settings;
        s.AreBrowserAcceleratorKeysEnabled = false;   // F5 = Ausführen statt Neu laden usw.
        s.AreDefaultContextMenusEnabled = false;      // Monaco hat ein eigenes Kontextmenü
        s.AreDevToolsEnabled = false;
        s.IsStatusBarEnabled = false;
        s.IsZoomControlEnabled = false;
        s.IsPasswordAutosaveEnabled = false;
        s.IsGeneralAutofillEnabled = false;

        core.SetVirtualHostNameToFolderMapping("editor.m365m", AppPaths.EditorAssetsDir, CoreWebView2HostResourceAccessKind.Deny);
        core.PermissionRequested += (_, e) =>
        {
            if (e.PermissionKind == CoreWebView2PermissionKind.ClipboardRead) e.State = CoreWebView2PermissionState.Allow;
        };
        core.NavigationStarting += (_, e) =>
        {
            if (!e.Uri.StartsWith("https://editor.m365m/", StringComparison.OrdinalIgnoreCase)) e.Cancel = true;
        };
        core.NewWindowRequested += (_, e) => e.Handled = true;
        core.ProcessFailed += (_, e) =>
        {
            Log.Write("Editor-Anzeige: " + e.ProcessFailedKind);
            // Offene Skripte stellt der Editor aus seiner Sitzung wieder her.
            if (e.ProcessFailedKind is CoreWebView2ProcessFailedKind.RenderProcessExited or CoreWebView2ProcessFailedKind.RenderProcessUnresponsive)
                Dispatcher.BeginInvoke(() => { try { core.Reload(); } catch { } });
        };
        core.WebMessageReceived += async (_, e) =>
        {
            try { await HandleMessageAsync(e.WebMessageAsJson); }
            catch (Exception ex) { Log.Write("Editor-Nachricht: " + ex.Message); }
        };
        core.Navigate("https://editor.m365m/index.html");
    }

    // ------------------------------------------------------------------ Nachrichten aus dem Editor

    private async Task HandleMessageAsync(string json)
    {
        using var doc = JsonDocument.Parse(json);
        var m = doc.RootElement;
        var id = m.TryGetProperty("id", out var idEl) && idEl.ValueKind == JsonValueKind.Number ? idEl.GetInt32() : 0;
        string? Str(string name) => m.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;

        switch (Str("t"))
        {
            case "ready":
                Post(new { t = "init", profileId = _profileId, theme = _dark ? "dark" : "light" });
                CompletionService.WarmUp();
                break;

            case "dirty":
                DirtyCount = m.GetProperty("count").GetInt32();
                break;

            case "run":
                RunRequested?.Invoke(Str("mode") ?? "all", Str("code") ?? "", Str("path"), Str("name") ?? "Skript");
                break;

            case "stop":
                StopRequested?.Invoke();
                break;

            case "open":
                await Task.Yield();   // Dialog erst nach dem WebView2-Ereignis öffnen (sonst Reentrancy)
                OpenFiles();
                break;

            case "read":
                Reply(id, ReadFile(Str("path") ?? ""));
                break;

            case "save":
            {
                var path = Str("path");
                var name = Str("name") ?? "Skript.ps1";
                var content = Str("content") ?? "";
                if (path is null) await Task.Yield();   // Speichern-Dialog erst nach dem WebView2-Ereignis
                Reply(id, SaveFile(path, name, content));
                break;
            }

            case "complete":
            {
                var (raw, status) = await CompletionService.CompleteAsync(Str("code") ?? "", m.GetProperty("offset").GetInt32());
                var node = raw is null ? new JsonObject { ["items"] = new JsonArray() } : JsonNode.Parse(raw)!.AsObject();
                if (status != CompletionService.Status.Ok) node["status"] = status == CompletionService.Status.Loading ? "loading" : "unavailable";
                node["t"] = "res";
                node["id"] = id;
                PostRaw(node.ToJsonString());
                break;
            }
        }
    }

    private void OpenFiles()
    {
        Directory.CreateDirectory(AppPaths.UserScriptsDir);
        var dialog = new Microsoft.Win32.OpenFileDialog
        {
            Filter = FileFilter,
            Multiselect = true,
            InitialDirectory = AppPaths.UserScriptsDir,
            Title = "Skript öffnen",
        };
        if (dialog.ShowDialog(Window.GetWindow(this)) != true) return;
        foreach (var path in dialog.FileNames)
        {
            var r = ReadFile(path);
            if (r.TryGetValue("ok", out var ok) && ok is true)
                Post(new { t = "opened", path, name = Path.GetFileName(path), content = (string)r["content"]! });
            else
                Post(new { t = "hint", text = "Öffnen fehlgeschlagen: " + r.GetValueOrDefault("error") });
        }
    }

    private static Dictionary<string, object?> ReadFile(string path)
    {
        try
        {
            using var reader = new StreamReader(path, new UTF8Encoding(false), detectEncodingFromByteOrderMarks: true);
            return new() { ["ok"] = true, ["content"] = reader.ReadToEnd() };
        }
        catch (Exception ex)
        {
            return new() { ["ok"] = false, ["error"] = ex.Message };
        }
    }

    private Dictionary<string, object?> SaveFile(string? path, string name, string content)
    {
        try
        {
            if (string.IsNullOrEmpty(path))
            {
                Directory.CreateDirectory(AppPaths.UserScriptsDir);
                var dialog = new Microsoft.Win32.SaveFileDialog
                {
                    Filter = FileFilter,
                    FileName = name,
                    DefaultExt = ".ps1",
                    InitialDirectory = AppPaths.UserScriptsDir,
                    Title = "Skript speichern",
                };
                if (dialog.ShowDialog(Window.GetWindow(this)) != true) return new() { ["ok"] = false };
                path = dialog.FileName;
            }

            // UTF-8 mit BOM, damit auch Windows PowerShell 5.1 Umlaute richtig liest –
            // bestehende Dateien ohne BOM behalten ihre Kodierung.
            var bom = !File.Exists(path) || HasBom(path);
            File.WriteAllText(path, content, new UTF8Encoding(bom));
            return new() { ["ok"] = true, ["path"] = path, ["name"] = Path.GetFileName(path) };
        }
        catch (Exception ex)
        {
            return new() { ["ok"] = false, ["error"] = ex.Message };
        }
    }

    private static bool HasBom(string path)
    {
        using var fs = File.OpenRead(path);
        Span<byte> b = stackalloc byte[3];
        return fs.Read(b) == 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF;
    }

    // ------------------------------------------------------------------ öffentliche API

    public void SetTheme(bool dark)
    {
        _dark = dark;
        Post(new { t = "theme", name = dark ? "dark" : "light" });
    }

    public void ShowHint(string text) => Post(new { t = "hint", text });

    public void FocusEditor()
    {
        _web.Focus();
        Post(new { t = "focus" });
    }

    private void Reply(int id, Dictionary<string, object?> data)
    {
        data["t"] = "res";
        data["id"] = id;
        PostRaw(JsonSerializer.Serialize(data));
    }

    private void Post(object message) => PostRaw(JsonSerializer.Serialize(message));

    private void PostRaw(string json)
    {
        if (_disposed || _web.CoreWebView2 is null) return;
        _web.CoreWebView2.PostWebMessageAsJson(json);
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _web.Dispose();
    }
}