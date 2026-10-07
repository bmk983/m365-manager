using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.Json;

namespace M365Manager.Services;

/// <summary>
/// IntelliSense für den Skript-Editor: eine unsichtbare PowerShell im Hintergrund beantwortet
/// Vorschlagsanfragen über TabExpansion2 (dieselben Vorschläge wie Tab im Terminal).
/// Wird beim ersten Bedarf gestartet und von allen Fenstern gemeinsam genutzt.
/// </summary>
public static class CompletionService
{
    private static readonly SemaphoreSlim Gate = new(1, 1);
    private static Process? _process;
    private static int _counter;
    private static int _latestTicket;

    /// <summary>Gibt die rohe JSON-Antwort des Helfers zurück (id, i, n, more, items) oder null.</summary>
    public static async Task<string?> CompleteAsync(string code, int offset)
    {
        // Bei schnellem Tippen nur die neueste Anfrage beantworten – ältere sind bereits überholt.
        var ticket = Interlocked.Increment(ref _latestTicket);
        if (!await Gate.WaitAsync(TimeSpan.FromSeconds(30))) return null;
        try
        {
            if (ticket != Volatile.Read(ref _latestTicket)) return null;
            var process = await EnsureStartedAsync();
            if (process is null) return null;

            var id = ++_counter;
            var request = JsonSerializer.Serialize(new { id, s = Convert.ToBase64String(Encoding.UTF8.GetBytes(code)), c = offset });
            await process.StandardInput.WriteLineAsync(request);
            await process.StandardInput.FlushAsync();

            // Erste Anfragen können Module laden (Graph: einige Sekunden) – großzügiges Zeitlimit.
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(25));
            while (true)
            {
                var line = await process.StandardOutput.ReadLineAsync(cts.Token);
                if (line is null) { Stop(); return null; }
                if (!line.StartsWith('{')) continue;   // Ausgaben, die keine Antwort sind, ignorieren
                try
                {
                    using var doc = JsonDocument.Parse(line);
                    if (doc.RootElement.TryGetProperty("id", out var rid) && rid.ValueKind == JsonValueKind.Number && rid.GetInt32() == id)
                        return line;
                }
                catch (JsonException) { }
            }
        }
        catch (OperationCanceledException)
        {
            Log.Write("IntelliSense: Zeitüberschreitung – Helfer wird neu gestartet.");
            Stop();
            return null;
        }
        catch (Exception ex)
        {
            Log.Write("IntelliSense: " + ex.Message);
            Stop();
            return null;
        }
        finally
        {
            Gate.Release();
        }
    }

    private static async Task<Process?> EnsureStartedAsync()
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
        psi.Environment["POWERSHELL_TELEMETRY_OPTOUT"] = "1";
        psi.Environment["POWERSHELL_UPDATECHECK"] = "Off";
        psi.Environment.Remove("NO_COLOR");

        var process = Process.Start(psi);
        if (process is null) return null;
        process.ErrorDataReceived += (_, _) => { };   // stderr leeren, damit nichts blockiert
        process.BeginErrorReadLine();
        try { process.PriorityClass = ProcessPriorityClass.BelowNormal; } catch { }

        using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(60));
        try
        {
            string? line;
            while ((line = await process.StandardOutput.ReadLineAsync(cts.Token)) is not null)
            {
                if (line.Contains("\"ready\"")) { _process = process; return process; }
            }
        }
        catch (OperationCanceledException) { }

        Log.Write("IntelliSense-Helfer ist nicht gestartet.");
        try { process.Kill(); } catch { }
        process.Dispose();
        return null;
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