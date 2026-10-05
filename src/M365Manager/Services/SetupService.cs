using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Net.Http;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace M365Manager.Services;

/// <summary>
/// Stellt portable PowerShell 7 und die M365-Module im Datenordner bereit.
/// Nichts wird installiert, keine Adminrechte nötig.
/// </summary>
public static class SetupService
{
    public static readonly string[] RequiredModules =
    [
        "Microsoft.Graph.Authentication",
        "Microsoft.Graph.Users",
        "Microsoft.Graph.Users.Actions",
        "Microsoft.Graph.Groups",
        "Microsoft.Graph.Identity.DirectoryManagement",
        "Microsoft.Graph.Identity.SignIns",
        "Microsoft.Graph.Identity.Governance",
        "Microsoft.Graph.Applications",
        "Microsoft.Graph.DeviceManagement",
        "Microsoft.Graph.Security",
        "Microsoft.Graph.Reports",
        "ExchangeOnlineManagement",
        "MicrosoftTeams",
        "PnP.PowerShell",
    ];

    private static readonly object Gate = new();
    private static readonly List<string> History = [];
    private static Task<bool>? _running;

    /// <summary>Wird aus Hintergrund-Threads ausgelöst.</summary>
    public static event Action<string>? LogLine;
    public static event Action? StateChanged;

    public static bool IsBusy => _running is { IsCompleted: false };

    public static IReadOnlyList<string> LogHistory
    {
        get { lock (History) return History.ToList(); }
    }

    public static string PortablePwshPath => Path.Combine(AppPaths.PwshDir, "pwsh.exe");

    /// <summary>Portable pwsh, ersatzweise ein installiertes PowerShell 7.</summary>
    public static string? PwshPath
    {
        get
        {
            if (File.Exists(PortablePwshPath)) return PortablePwshPath;
            var installed = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "PowerShell", "7", "pwsh.exe");
            return File.Exists(installed) ? installed : null;
        }
    }

    public static string? PwshVersion
    {
        get
        {
            var p = PwshPath;
            if (p is null) return null;
            var v = FileVersionInfo.GetVersionInfo(p).ProductVersion ?? "";
            return v.Split(' ', '+')[0];
        }
    }

    public static IReadOnlyList<string> MissingModules() =>
        RequiredModules.Where(m =>
        {
            var dir = Path.Combine(AppPaths.ModulesDir, m);
            return !Directory.Exists(dir) || !Directory.EnumerateDirectories(dir).Any();
        }).ToList();

    public static bool IsReady => PwshPath is not null && MissingModules().Count == 0;

    /// <summary>Startet das Setup oder hängt sich an ein laufendes an.</summary>
    public static Task<bool> EnsureReadyAsync(bool update = false)
    {
        lock (Gate)
        {
            if (_running is { IsCompleted: false }) return _running;
            if (!update && IsReady) return Task.FromResult(true);
            _running = Task.Run(() => RunAsync(update));
        }
        StateChanged?.Invoke();
        return _running;
    }

    private static async Task<bool> RunAsync(bool update)
    {
        try
        {
            await EnsurePwshAsync(update);
            await InstallModulesAsync(update);
            Emit(IsReady ? "✓ Umgebung ist bereit." : "⚠ Einrichtung unvollständig.");
            return IsReady;
        }
        catch (Exception ex)
        {
            Emit("✗ Fehler: " + ex.Message);
            Log.Write("Setup: " + ex);
            return false;
        }
        finally
        {
            // _running ist hier noch nicht abgeschlossen – Listener prüfen IsBusy daher verzögert.
            _ = Task.Run(async () => { await Task.Delay(50); StateChanged?.Invoke(); });
        }
    }

    private static void Emit(string line)
    {
        lock (History)
        {
            History.Add(line);
            if (History.Count > 500) History.RemoveAt(0);
        }
        Log.Write("[setup] " + line);
        LogLine?.Invoke(line);
    }

    private static HttpClient CreateHttp()
    {
        var http = new HttpClient { Timeout = TimeSpan.FromMinutes(15) };
        http.DefaultRequestHeaders.UserAgent.ParseAdd("M365Manager/1.0");
        return http;
    }

    // ---------------------------------------------------------------- PowerShell 7

    private static async Task EnsurePwshAsync(bool update)
    {
        if (File.Exists(PortablePwshPath) && !update)
            return;

        Emit("Suche aktuelle PowerShell-7-Version auf GitHub …");
        using var http = CreateHttp();
        using var release = JsonDocument.Parse(await http.GetStringAsync("https://api.github.com/repos/PowerShell/PowerShell/releases/latest"));
        var root = release.RootElement;
        var version = root.GetProperty("tag_name").GetString()!.TrimStart('v');

        if (File.Exists(PortablePwshPath) && PwshVersion == version)
        {
            Emit("✓ PowerShell " + version + " ist aktuell.");
            return;
        }

        var arch = RuntimeInformation.OSArchitecture == Architecture.Arm64 ? "arm64" : "x64";
        var assetName = "PowerShell-" + version + "-win-" + arch + ".zip";
        string? zipUrl = null, hashUrl = null;
        foreach (var asset in root.GetProperty("assets").EnumerateArray())
        {
            var name = asset.GetProperty("name").GetString();
            var url = asset.GetProperty("browser_download_url").GetString();
            if (string.Equals(name, assetName, StringComparison.OrdinalIgnoreCase)) zipUrl = url;
            if (string.Equals(name, "hashes.sha256", StringComparison.OrdinalIgnoreCase)) hashUrl = url;
        }
        if (zipUrl is null)
            throw new InvalidOperationException("Paket " + assetName + " wurde im Release nicht gefunden.");

        string? expectedHash = null;
        if (hashUrl is not null)
            expectedHash = FindHash(await http.GetStringAsync(hashUrl), assetName);
        if (expectedHash is null && root.TryGetProperty("body", out var body))
            expectedHash = FindHash(body.GetString() ?? "", assetName);
        if (expectedHash is null)
            throw new InvalidOperationException("Keine SHA256-Prüfsumme gefunden. Download aus Sicherheitsgründen abgebrochen.");

        var tmpZip = Path.Combine(AppPaths.DataRoot, assetName + ".download");
        Emit("↓ Lade " + assetName + " …");
        using (var response = await http.GetAsync(zipUrl, HttpCompletionOption.ResponseHeadersRead))
        {
            response.EnsureSuccessStatusCode();
            var total = response.Content.Headers.ContentLength ?? 0;
            await using var src = await response.Content.ReadAsStreamAsync();
            await using var dst = File.Create(tmpZip);
            var buffer = new byte[1 << 16];
            long done = 0;
            var lastStep = -1;
            int read;
            while ((read = await src.ReadAsync(buffer)) > 0)
            {
                await dst.WriteAsync(buffer.AsMemory(0, read));
                done += read;
                if (total > 0)
                {
                    var step = (int)(done * 5 / total);
                    if (step != lastStep) { lastStep = step; Emit("   " + (step * 20) + " %"); }
                }
            }
        }

        Emit("Prüfe SHA256-Prüfsumme …");
        string actual;
        await using (var fs = File.OpenRead(tmpZip))
            actual = Convert.ToHexString(await SHA256.HashDataAsync(fs));
        if (!actual.Equals(expectedHash, StringComparison.OrdinalIgnoreCase))
        {
            File.Delete(tmpZip);
            throw new InvalidOperationException("Prüfsumme stimmt nicht überein. Download verworfen.");
        }

        Emit("Entpacke PowerShell " + version + " …");
        CleanupStaleStaging();
        // Eindeutiger Name: Reste eines abgebrochenen Versuchs (z. B. vom Virenscanner gesperrt) stören nicht.
        var staging = AppPaths.PwshDir + ".new-" + Guid.NewGuid().ToString("N")[..8];
        ZipFile.ExtractToDirectory(tmpZip, staging);
        TryDelete(tmpZip);

        if (Directory.Exists(AppPaths.PwshDir))
        {
            try { await RetryIoAsync(() => DeleteDirectory(AppPaths.PwshDir)); }
            catch (Exception ex)
            {
                TryDeleteDirectory(staging);
                throw new InvalidOperationException("Die alte PowerShell wird noch verwendet. Bitte alle Profilfenster schließen und erneut aktualisieren. (" + ex.Message + ")");
            }
        }

        // Virenscanner prüfen frisch entpackte Dateien und halten sie dabei kurz offen –
        // das Umbenennen daher mehrfach versuchen und notfalls kopieren.
        try
        {
            await RetryIoAsync(() => Directory.Move(staging, AppPaths.PwshDir));
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            Emit("   Umbenennen blockiert (vermutlich Virenscan) – kopiere stattdessen …");
            await RetryIoAsync(() => CopyDirectory(staging, AppPaths.PwshDir));
            TryDeleteDirectory(staging);
        }

        if (!File.Exists(PortablePwshPath))
            throw new InvalidOperationException("pwsh.exe fehlt nach dem Entpacken. Möglicherweise hat der Virenscanner sie entfernt.");
        Emit("✓ PowerShell " + version + " bereit.");
    }

    private static async Task RetryIoAsync(Action action, int attempts = 12)
    {
        for (var i = 1; ; i++)
        {
            try
            {
                action();
                return;
            }
            catch (Exception ex) when (i < attempts && ex is IOException or UnauthorizedAccessException)
            {
                await Task.Delay(Math.Min(500 * i, 3000));
            }
        }
    }

    private static void CopyDirectory(string source, string target)
    {
        Directory.CreateDirectory(target);
        foreach (var dir in Directory.EnumerateDirectories(source, "*", SearchOption.AllDirectories))
            Directory.CreateDirectory(Path.Combine(target, Path.GetRelativePath(source, dir)));
        foreach (var file in Directory.EnumerateFiles(source, "*", SearchOption.AllDirectories))
            File.Copy(file, Path.Combine(target, Path.GetRelativePath(source, file)), overwrite: true);
    }

    private static void DeleteDirectory(string dir)
    {
        if (!Directory.Exists(dir)) return;
        foreach (var file in Directory.EnumerateFiles(dir, "*", SearchOption.AllDirectories))
            File.SetAttributes(file, FileAttributes.Normal);
        Directory.Delete(dir, true);
    }

    private static void TryDeleteDirectory(string dir)
    {
        try { DeleteDirectory(dir); } catch (Exception ex) { Log.Write("Aufräumen von " + dir + " nicht möglich: " + ex.Message); }
    }

    private static void TryDelete(string file)
    {
        try { File.Delete(file); } catch { }
    }

    /// <summary>Entfernt Reste früherer, abgebrochener Entpack-Versuche (soweit möglich).</summary>
    private static void CleanupStaleStaging()
    {
        foreach (var dir in Directory.EnumerateDirectories(AppPaths.DataRoot, "pwsh.new*"))
            TryDeleteDirectory(dir);
    }
    private static string? FindHash(string text, string assetName)
    {
        foreach (var line in text.Split('\n'))
        {
            if (!line.Contains(assetName, StringComparison.OrdinalIgnoreCase)) continue;
            var m = Regex.Match(line, "[A-Fa-f0-9]{64}");
            if (m.Success) return m.Value;
        }
        return null;
    }

    // ---------------------------------------------------------------- Module

    private static async Task InstallModulesAsync(bool update)
    {
        if (!update && MissingModules().Count == 0)
            return;

        var pwsh = PwshPath ?? throw new InvalidOperationException("PowerShell 7 ist nicht verfügbar.");
        var script = Path.Combine(AppPaths.ScriptsDir, "setup-modules.ps1");
        Directory.CreateDirectory(AppPaths.ModulesDir);

        Emit(update ? "Aktualisiere PowerShell-Module …" : "Installiere PowerShell-Module (einmalig, dauert ein paar Minuten) …");

        var psi = new ProcessStartInfo(pwsh)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
            WorkingDirectory = AppPaths.DataRoot,
        };
        foreach (var a in new[] { "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", script,
                                  "-Path", AppPaths.ModulesDir, "-Modules", string.Join(",", RequiredModules) })
            psi.ArgumentList.Add(a);
        if (update) psi.ArgumentList.Add("-Update");
        psi.Environment["POWERSHELL_TELEMETRY_OPTOUT"] = "1";
        psi.Environment["POWERSHELL_UPDATECHECK"] = "Off";

        using var proc = Process.Start(psi)!;
        var stdout = PumpAsync(proc.StandardOutput, "");
        var stderr = PumpAsync(proc.StandardError, "! ");
        await proc.WaitForExitAsync();
        await Task.WhenAll(stdout, stderr);

        if (proc.ExitCode != 0)
            throw new InvalidOperationException("Modul-Installation mit Code " + proc.ExitCode + " beendet.");
    }

    private static async Task PumpAsync(StreamReader reader, string prefix)
    {
        string? line;
        while ((line = await reader.ReadLineAsync()) is not null)
            if (!string.IsNullOrWhiteSpace(line))
                Emit(prefix + line);
    }
}