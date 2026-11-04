using System.Collections.Concurrent;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Windows.Threading;
using M365Manager.Models;
using M365Manager.Terminal;

namespace M365Manager.Services;

/// <summary>
/// Unsichtbare PowerShell für den Exchange-RBAC-Bereich eines Profils (rbac-host.ps1).
/// Sie meldet sich wie das Terminal über die Browser-Anmeldung an (eigener Kanal, nur dieser Prozess darf ihn nutzen)
/// und beantwortet Anfragen nacheinander. Antworten kommen als "&lt;RS&gt;M365RBAC {json}" auf stdout.
/// </summary>
public sealed class RbacHost : IDisposable
{
    private const string Marker = "\u001eM365RBAC ";

    private readonly Func<AdminProfile> _profile;
    private readonly Func<string, string?, bool, bool, Action<string>, Task<TokenResult>> _tokens;
    private readonly Dispatcher _dispatcher;
    private readonly SemaphoreSlim _startGate = new(1, 1);
    private readonly SemaphoreSlim _writeGate = new(1, 1);
    private readonly ConcurrentDictionary<int, TaskCompletionSource<JsonNode?>> _pending = new();
    private Process? _process;
    private PipeListener? _pipe;
    private int _counter;
    private bool _disposed;

    /// <summary>Hinweise während einer Anfrage (z. B. "Anmeldefenster ist geöffnet").</summary>
    public event Action<string>? Notice;

    public RbacHost(Func<AdminProfile> profile, Func<string, string?, bool, bool, Action<string>, Task<TokenResult>> tokens, Dispatcher dispatcher)
    {
        _profile = profile;
        _tokens = tokens;
        _dispatcher = dispatcher;
    }

    /// <summary>Lese-Anfrage (op + Argumente als JSON). Ergebnis: "data" der Antwort; Fehler als Exception.</summary>
    public Task<JsonNode?> CallAsync(string op, JsonNode? args, TimeSpan? timeout = null) =>
        SendAsync(new JsonObject { ["op"] = op, ["args"] = args?.DeepClone() }, timeout ?? TimeSpan.FromMinutes(5));

    /// <summary>Führt genau den angezeigten Befehl aus und liefert seine Ausgabe.</summary>
    public async Task<string> RunAsync(string script)
    {
        Log.Write("RBAC ausführen: " + script.Replace("\r", " ").Replace("\n", " ⏎ "));
        var data = await SendAsync(new JsonObject { ["op"] = "run", ["script"] = script }, TimeSpan.FromMinutes(15));
        return data?["output"]?.GetValue<string>() ?? "";
    }

    private async Task<JsonNode?> SendAsync(JsonObject request, TimeSpan timeout)
    {
        var process = await EnsureStartedAsync() ?? throw new InvalidOperationException("Die RBAC-PowerShell konnte nicht gestartet werden (siehe Protokoll).");
        var id = Interlocked.Increment(ref _counter);
        request["id"] = id;
        var tcs = new TaskCompletionSource<JsonNode?>(TaskCreationOptions.RunContinuationsAsynchronously);
        _pending[id] = tcs;
        try
        {
            await _writeGate.WaitAsync();
            try
            {
                await process.StandardInput.WriteLineAsync(request.ToJsonString());
                await process.StandardInput.FlushAsync();
            }
            finally { _writeGate.Release(); }

            var done = await Task.WhenAny(tcs.Task, Task.Delay(timeout));
            if (done != tcs.Task) throw new TimeoutException("Keine Antwort von Exchange innerhalb von " + (int)timeout.TotalMinutes + " Minuten.");
            return await tcs.Task;
        }
        finally
        {
            _pending.TryRemove(id, out _);
        }
    }

    private async Task<Process?> EnsureStartedAsync()
    {
        if (_process is { HasExited: false }) return _process;
        await _startGate.WaitAsync();
        try
        {
            if (_disposed) return null;
            if (_process is { HasExited: false }) return _process;
            StopProcess();

            if (!SetupService.IsReady) await SetupService.EnsureReadyAsync();
            var pwsh = SetupService.PwshPath;
            var script = Path.Combine(AppPaths.ScriptsDir, "rbac-host.ps1");
            if (pwsh is null || !File.Exists(script)) return null;

            Process? started = null;
            _pipe = new PipeListener(_ => { }, HandleRequestAsync, () => started?.Id);

            var utf8 = new UTF8Encoding(false);
            var psi = new ProcessStartInfo(pwsh)
            {
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardInput = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                StandardInputEncoding = utf8,
                StandardOutputEncoding = utf8,
                StandardErrorEncoding = utf8,
                WorkingDirectory = AppPaths.DataRoot,
            };
            foreach (var a in new[] { "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "RemoteSigned", "-File", script }) psi.ArgumentList.Add(a);

            var profile = _profile();
            psi.Environment["M365M_PROFILE"] = profile.Name;
            psi.Environment["M365M_UPN"] = profile.Upn;
            psi.Environment["M365M_TENANT"] = profile.Tenant;
            psi.Environment["M365M_SPTENANT"] = profile.EffectiveSharePointTenant;
            psi.Environment["M365M_PNPCLIENTID"] = profile.PnPClientId;
            psi.Environment["M365M_GRAPHSCOPES"] = profile.GraphScopes;
            psi.Environment["M365M_PIPE"] = _pipe.Name;
            psi.Environment["M365M_DATA"] = AppPaths.DataRoot;
            psi.Environment["M365M_MODULES"] = AppPaths.ModulesDir;
            psi.Environment["POWERSHELL_TELEMETRY_OPTOUT"] = "1";
            psi.Environment["POWERSHELL_UPDATECHECK"] = "Off";
            psi.Environment["NO_COLOR"] = "1";

            started = Process.Start(psi);
            if (started is null) return null;
            _process = started;
            Log.Write("RBAC-PowerShell gestartet (PID " + started.Id + ").");

            var proc = started;
            _ = Task.Run(() => ReadLoop(proc));
            _ = Task.Run(async () =>
            {
                string? line;
                while ((line = await proc.StandardError.ReadLineAsync()) is not null)
                    if (!string.IsNullOrWhiteSpace(line)) Log.Write("RBAC-PowerShell: " + line);
            });
            return started;
        }
        catch (Exception ex)
        {
            Log.Write("RBAC-PowerShell Start: " + ex);
            return null;
        }
        finally
        {
            _startGate.Release();
        }
    }

    private async Task ReadLoop(Process proc)
    {
        try
        {
            string? line;
            while ((line = await proc.StandardOutput.ReadLineAsync()) is not null)
            {
                if (!line.StartsWith(Marker, StringComparison.Ordinal)) continue;   // Modul-Ausgaben, Banner …
                JsonNode? reply;
                try { reply = JsonNode.Parse(line[Marker.Length..]); }
                catch (JsonException ex) { Log.Write("RBAC-Antwort unlesbar: " + ex.Message); continue; }
                var id = reply?["id"]?.GetValue<int>() ?? 0;
                if (!_pending.TryGetValue(id, out var tcs)) continue;
                if (reply?["ok"]?.GetValue<bool>() == true) tcs.TrySetResult(reply["data"]);
                else tcs.TrySetException(new InvalidOperationException(reply?["error"]?.GetValue<string>() ?? "Unbekannter Fehler."));
            }
        }
        catch (Exception ex)
        {
            Log.Write("RBAC-PowerShell Lesen: " + ex.Message);
        }
        // Prozess beendet: offene Anfragen nicht hängen lassen
        foreach (var tcs in _pending.Values) tcs.TrySetException(new InvalidOperationException("Die RBAC-PowerShell wurde beendet. Bitte erneut versuchen."));
    }

    /// <summary>Token-Anfragen der RBAC-PowerShell – identisch zum Terminal (Browser-Anmeldung des Profils).</summary>
    private async Task<string> HandleRequestAsync(string kind, string[] args, Action<string> notify)
    {
        if (kind != "token" || args.Length == 0) throw new InvalidOperationException("Unbekannte Anfrage.");
        var extra = args.Length > 1 && args[1].Length > 0 ? args[1] : null;
        // Schutz: Der RBAC-Bereich nutzt Graph nur mit den Profil-Berechtigungen. Zusätzliche Scopes würden eine
        // Zustimmung (Consent) in Entra auslösen – das darf von hier aus nie passieren.
        if (args[0] == "Graph" && !string.IsNullOrWhiteSpace(extra))
        {
            Log.Write("RBAC: Anfrage nach zusätzlichen Graph-Berechtigungen abgelehnt (" + extra + ")");
            throw new InvalidOperationException("Der RBAC-Bereich fordert keine zusätzlichen Graph-Berechtigungen an.");
        }
        if (args[0] is not ("Graph" or "Exchange"))
            throw new InvalidOperationException("Der RBAC-Bereich verbindet sich nur mit Exchange Online und (lesend) mit Graph.");
        var flags = args.Length > 2 ? args[2].Split(',') : [];
        void Forward(string text)
        {
            notify(text);
            if (!string.IsNullOrEmpty(text)) _dispatcher.BeginInvoke(() => Notice?.Invoke(text));
        }
        var token = await _dispatcher.InvokeAsync(() => _tokens(args[0], extra, flags.Contains("fresh"), flags.Contains("reauth"), Forward)).Task.Unwrap();
        return token.AccessToken + "|" + token.ExpiresOn.ToUnixTimeSeconds();
    }

    /// <summary>Neu verbinden (z. B. nach PIM-Aktivierung): Prozess beenden, beim nächsten Aufruf startet er neu.</summary>
    public void Reset()
    {
        StopProcess();
        foreach (var tcs in _pending.Values) tcs.TrySetException(new InvalidOperationException("Verbindung wurde neu aufgebaut."));
    }

    private void StopProcess()
    {
        try { if (_process is { HasExited: false }) _process.Kill(entireProcessTree: true); } catch { }
        _process?.Dispose();
        _process = null;
        _pipe?.Dispose();
        _pipe = null;
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        StopProcess();
    }
}
