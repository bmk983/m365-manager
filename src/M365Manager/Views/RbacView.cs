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

/// <summary>
/// Exchange-RBAC-Bereich (HTML-Oberfläche in WebView2). Liest über die RBAC-PowerShell des Profils und führt
/// Änderungen erst nach Vorschau und Bestätigung aus – genau den angezeigten Befehl.
/// </summary>
public sealed class RbacView : Grid, IDisposable
{
    private readonly WebView2 _web;
    private readonly RbacHost _host;
    private bool _dark, _initialized, _disposed;

    /// <summary>Befehl in den Skript-Editor übernehmen (Name, Code).</summary>
    public Action<string, string>? OpenInEditor { get; set; }

    /// <summary>Adresse im Entra-Portal in einem Browser-Tab des Profils öffnen.</summary>
    public Action<string>? OpenPortal { get; set; }

    public RbacView(RbacHost host, bool dark)
    {
        _host = host;
        _dark = dark;
        _host.Notice += text => Post(new { t = "notice", text });
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
            Children.Add(new TextBlock { Text = "RBAC-Ansicht konnte nicht gestartet werden: " + ex.Message, Margin = new Thickness(16), TextWrapping = TextWrapping.Wrap });
            Log.Write("RBAC WebView2: " + ex);
            return;
        }

        var core = _web.CoreWebView2;
        var s = core.Settings;
        s.AreDefaultContextMenusEnabled = true;
        s.AreDevToolsEnabled = false;
        s.IsStatusBarEnabled = false;
        s.IsZoomControlEnabled = true;
        s.IsPasswordAutosaveEnabled = false;
        s.IsGeneralAutofillEnabled = false;

        core.SetVirtualHostNameToFolderMapping("rbac.m365m", AppPaths.RbacAssetsDir, CoreWebView2HostResourceAccessKind.Deny);
        core.NavigationStarting += (_, e) =>
        {
            if (!e.Uri.StartsWith("https://rbac.m365m/", StringComparison.OrdinalIgnoreCase)) e.Cancel = true;
        };
        core.NewWindowRequested += (_, e) => e.Handled = true;
        core.ProcessFailed += (_, e) =>
        {
            Log.Write("RBAC-Anzeige: " + e.ProcessFailedKind);
            if (e.ProcessFailedKind is CoreWebView2ProcessFailedKind.RenderProcessExited or CoreWebView2ProcessFailedKind.RenderProcessUnresponsive)
                Dispatcher.BeginInvoke(() => { try { core.Reload(); } catch { } });
        };
        core.WebMessageReceived += async (_, e) =>
        {
            try { await HandleMessageAsync(e.WebMessageAsJson); }
            catch (Exception ex) { Log.Write("RBAC-Nachricht: " + ex.Message); }
        };
        core.Navigate("https://rbac.m365m/index.html");
    }

    private async Task HandleMessageAsync(string json)
    {
        var m = JsonNode.Parse(json)!.AsObject();
        var id = m["id"]?.GetValue<int>() ?? 0;
        string? Str(string name) => m[name]?.GetValue<string>();

        switch (Str("t"))
        {
            case "ready":
                Post(new { t = "init", theme = _dark ? "dark" : "light" });
                break;

            case "call":
                try
                {
                    var data = await _host.CallAsync(Str("op") ?? "", m["args"]);
                    Reply(id, true, data, null);
                }
                catch (Exception ex)
                {
                    Reply(id, false, null, ex.Message);
                }
                break;

            case "run":
                try
                {
                    var output = await _host.RunAsync(Str("script") ?? "");
                    Reply(id, true, JsonValue.Create(output), null);
                }
                catch (Exception ex)
                {
                    Reply(id, false, null, ex.Message);
                }
                break;

            case "reset":
                _host.Reset();
                break;

            case "copy":
                try { Clipboard.SetText(Str("text") ?? ""); } catch (Exception ex) { Log.Write("RBAC kopieren: " + ex.Message); }
                break;

            case "toeditor":
                OpenInEditor?.Invoke(Str("name") ?? "RBAC", Str("code") ?? "");
                break;

            case "portal":
                // Nur Entra-Portal-Adressen – Änderungen in Entra macht der Nutzer dort mit seiner Portal-Anmeldung
                if (Str("url") is { } url && url.StartsWith("https://entra.microsoft.com/", StringComparison.OrdinalIgnoreCase))
                    OpenPortal?.Invoke(url);
                break;

            case "export":
                await Task.Yield();   // Dialog erst nach dem WebView2-Ereignis
                SaveCsv(Str("name") ?? "RBAC", Str("csv") ?? "");
                break;
        }
    }

    private void SaveCsv(string name, string csv)
    {
        var dialog = new Microsoft.Win32.SaveFileDialog
        {
            Filter = "CSV (Excel) (*.csv)|*.csv",
            FileName = string.Concat(name.Split(Path.GetInvalidFileNameChars())) + " " + DateTime.Now.ToString("yyyy-MM-dd") + ".csv",
            DefaultExt = ".csv",
            Title = "Als CSV speichern",
        };
        if (dialog.ShowDialog(Window.GetWindow(this)) != true) return;
        try { File.WriteAllText(dialog.FileName, csv, new UTF8Encoding(true)); }
        catch (Exception ex) { Log.Write("RBAC CSV: " + ex.Message); }
    }

    public void SetTheme(bool dark)
    {
        _dark = dark;
        Post(new { t = "theme", name = dark ? "dark" : "light" });
    }

    private void Reply(int id, bool ok, JsonNode? data, string? error)
    {
        var node = new JsonObject { ["t"] = "res", ["id"] = id, ["ok"] = ok, ["data"] = data?.DeepClone(), ["error"] = error };
        PostRaw(node.ToJsonString());
    }

    private void Post(object message) => PostRaw(JsonSerializer.Serialize(message));

    private void PostRaw(string json)
    {
        if (_disposed) return;
        Dispatcher.BeginInvoke(() =>
        {
            if (!_disposed && _web.CoreWebView2 is not null) _web.CoreWebView2.PostWebMessageAsJson(json);
        });
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _web.Dispose();
    }
}
