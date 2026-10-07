using System.Collections.Concurrent;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.Json;

namespace M365Manager.Services;

/// <summary>
/// IntelliSense für den Skript-Editor: eine unsichtbare PowerShell im Hintergrund beantwortet
/// Vorschlagsanfragen über TabExpansion2 (dieselben Vorschläge wie Tab im Terminal).
/// Antworten werden von einem eigenen Lese-Thread zugeordnet – eine langsame Anfrage (Modul wird geladen)
/// blockiert oder beendet den Helfer daher nicht.
/// </summary>
public static class CompletionService
{
    public enum Status { Ok, Loading, Unavailable }

    private static readonly SemaphoreSlim StartGate = new(1, 1);
    private static readonly SemaphoreSlim WriteGate = new(1, 1);
    private static readonly ConcurrentDictionary<int, TaskCompletionSource<string>> Pending = new();
    private static Process? _process;
    private static int _counter;
    private static int _latestTicket;

    /// <summary>Startet den Helfer vorab (z. B. beim Öffnen des Editors), damit die ersten Vorschläge schnell kommen.</summary>
    public static void WarmUp() => _ = Task.Run(EnsureStartedAsync);

    /// <summary>"Befehle laden": alle Module und Baupläne im Helfer laden. Rohe JSON-Antwort mit Ergebnis oder null.</summary>
    public static async Task<string?> LoadAllAsync()
    {
        var process = await EnsureStartedAsync();
        if (process is null) return null;
        var id = Interlocked.Increment(ref _counter);
        var tcs = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
        Pending[id] = tcs;
        try
        {
            await WriteGate.WaitAsync();
            try
            {
                await process.StandardInput.WriteLineAsync(JsonSerializer.Serialize(new { id, cmd = "loadall" }));
                await process.StandardInput.FlushAsync();
            }
            finally { WriteGate.Release(); }
            var done = await Task.WhenAny(tcs.Task, Task.Delay(TimeSpan.FromMinutes(3)));
            return done == tcs.Task ? await tcs.Task : null;
        }
        finally { Pending.TryRemove(id, out _); }
    }

    /// <summary>Liefert die rohe JSON-Antwort (id, i, n, more, items) oder null samt Status.</summary>
    public static async Task<(string? Json, Status Status)> CompleteAsync(string code, int offset)
    {
        // Bei schnellem Tippen nur die neueste Anfrage bearbeiten – ältere sind überholt.
        var ticket = Interlocked.Increment(ref _latestTicket);
        var process = await EnsureStartedAsync();
        if (process is null) return (null, Status.Unavailable);
        if (ticket != Volatile.Read(ref _latestTicket)) return (null, Status.Ok);

        var id = Interlocked.Increment(ref _counter);
        var tcs = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
        Pending[id] = tcs;
        try
        {
            var request = JsonSerializer.Serialize(new { id, s = Convert.ToBase64String(Encoding.UTF8.GetBytes(code)), c = offset });
            await WriteGate.WaitAsync();
            try
            {
                await process.StandardInput.WriteLineAsync(request);
                await process.StandardInput.FlushAsync();
            }
            finally
            {
                WriteGate.Release();
            }

            // Erste Anfragen laden ggf. ein Modul (Graph: einige Sekunden). Antwortet der Helfer nicht rechtzeitig,
            // läuft er trotzdem weiter – die nächste Anfrage profitiert dann vom geladenen Modul.
            var done = await Task.WhenAny(tcs.Task, Task.Delay(TimeSpan.FromSeconds(20)));
            return done == tcs.Task ? (await tcs.Task, Status.Ok) : (null, Status.Loading);
        }
        catch (Exception ex)
        {
            Log.Write("IntelliSense: " + ex.Message);
            Stop();
            return (null, Status.Unavailable);
        }
        finally
        {
            Pending.TryRemove(id, out _);
        }
    }

    private static async Task<Process?> EnsureStartedAsync()
    {
        if (_process is { HasExited: false }) return _process;

        await StartGate.WaitAsync();
        try
        {
            if (_process is { HasExited: false }) return _process;
            Stop();

            var pwsh = SetupService.PwshPath;
            var script = Path.Combine(AppPaths.ScriptsDir, "completion-host.ps1");
            if (pwsh is null || !File.Exists(script)) return null;

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
            foreach (var a in new[] { "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", script })
                psi.ArgumentList.Add(a);
            psi.Environment["M365M_MODULES"] = AppPaths.ModulesDir;
            psi.Environment["M365M_DATA"] = AppPaths.DataRoot;
            psi.Environment["POWERSHELL_TELEMETRY_OPTOUT"] = "1";
            psi.Environment["POWERSHELL_UPDATECHECK"] = "Off";
            psi.Environment.Remove("NO_COLOR");

            var process = Process.Start(psi);
            if (process is null) return null;
            process.ErrorDataReceived += (_, e) => { if (!string.IsNullOrWhiteSpace(e.Data)) Log.Write("IntelliSense: " + e.Data); };
            process.BeginErrorReadLine();
            try { process.PriorityClass = ProcessPriorityClass.BelowNormal; } catch { }

            // Auf "ready" warten
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(60));
            var ready = false;
            try
            {
                string? line;
                while ((line = await process.StandardOutput.ReadLineAsync(cts.Token)) is not null)
                    if (line.Contains("\"ready\"")) { ready = true; break; }
            }
            catch (OperationCanceledException) { }

            if (!ready)
            {
                Log.Write("IntelliSense-Helfer ist nicht gestartet.");
                try { process.Kill(); } catch { }
                process.Dispose();
                return null;
            }

            _process = process;
            _ = Task.Run(() => ReadLoopAsync(process));
            Log.Write("IntelliSense-Helfer gestartet.");
            return process;
        }
        finally
        {
            StartGate.Release();
        }
    }

    private static async Task ReadLoopAsync(Process process)
    {
        try
        {
            string? line;
            while ((line = await process.StandardOutput.ReadLineAsync()) is not null)
            {
                if (!line.StartsWith('{')) continue;   // sonstige Ausgaben ignorieren
                try
                {
                    using var doc = JsonDocument.Parse(line);
                    if (doc.RootElement.TryGetProperty("id", out var idEl) && idEl.ValueKind == JsonValueKind.Number
                        && Pending.TryGetValue(idEl.GetInt32(), out var tcs))
                        tcs.TrySetResult(line);
                }
                catch (JsonException) { }
            }
        }
        catch (Exception ex)
        {
            Log.Write("IntelliSense-Lesen: " + ex.Message);
        }
        if (ReferenceEquals(_process, process)) Log.Write("IntelliSense-Helfer beendet – wird bei Bedarf neu gestartet.");
    }

    public static void Stop()
    {
        var p = _process;
        _process = null;
        if (p is null) return;
        try { if (!p.HasExited) p.Kill(); } catch { }
        p.Dispose();
    }
}