using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text.Json;
using System.Windows;

namespace M365Manager.Services;

/// <summary>
/// Sucht auf GitHub nach einer neueren Version und tauscht die portable EXE auf Knopfdruck aus:
/// herunterladen → SHA-256 gegen die Angabe von GitHub prüfen → laufende EXE umbenennen (das erlaubt Windows) →
/// neue EXE an ihren Platz → neu starten. Die alte Datei wird beim nächsten Start entfernt.
/// </summary>
public static class UpdateService
{
    public sealed record UpdateInfo(Version Version, string ReleaseUrl, string DownloadUrl, string Sha256, long Size);

    private const string LatestApi = "https://api.github.com/repos/bmk983/m365-manager/releases/latest";
    private static Task<UpdateInfo?>? _check;
    private static DateTime _checkedAt;

    public static Version Current
    {
        get
        {
            var v = typeof(UpdateService).Assembly.GetName().Version ?? new Version(0, 0, 0);
            return new Version(v.Major, v.Minor, Math.Max(v.Build, 0));
        }
    }

    public static event Action<UpdateInfo>? Available;

    /// <summary>Höchstens alle 6 Stunden wirklich nachfragen; null = aktuell oder nicht erreichbar.</summary>
    public static Task<UpdateInfo?> CheckAsync(bool force = false)
    {
        if (force || _check is null || (_check.IsCompleted && DateTime.UtcNow - _checkedAt > TimeSpan.FromHours(6)))
        {
            _checkedAt = DateTime.UtcNow;
            _check = QueryAsync();
        }
        return _check;
    }

    private static async Task<UpdateInfo?> QueryAsync()
    {
        try
        {
            using var http = NewClient(TimeSpan.FromSeconds(10));
            using var doc = JsonDocument.Parse(await http.GetStringAsync(LatestApi));
            var root = doc.RootElement;
            if (!Version.TryParse(root.GetProperty("tag_name").GetString()?.TrimStart('v'), out var latest)) return null;
            latest = new Version(latest.Major, latest.Minor, Math.Max(latest.Build, 0));
            if (latest <= Current) return null;

            foreach (var asset in root.GetProperty("assets").EnumerateArray())
            {
                var name = asset.GetProperty("name").GetString() ?? "";
                if (!name.StartsWith("M365Manager-", StringComparison.OrdinalIgnoreCase) || !name.EndsWith("-portable.exe", StringComparison.OrdinalIgnoreCase)) continue;
                var digest = asset.TryGetProperty("digest", out var d) ? d.GetString() ?? "" : "";
                var info = new UpdateInfo(
                    latest,
                    root.GetProperty("html_url").GetString() ?? "",
                    asset.GetProperty("browser_download_url").GetString() ?? "",
                    digest.StartsWith("sha256:", StringComparison.OrdinalIgnoreCase) ? digest[7..].ToLowerInvariant() : "",
                    asset.GetProperty("size").GetInt64());
                Log.Write("Update verfügbar: " + latest + " (installiert " + Current + ")");
                Application.Current?.Dispatcher.BeginInvoke(() => Available?.Invoke(info));
                return info;
            }
        }
        catch (Exception ex)
        {
            Log.Write("Update-Prüfung: " + ex.Message);   // offline o. Ä. – kein Problem
        }
        return null;
    }

    /// <summary>Lädt die neue Version, prüft sie, tauscht die EXE und startet neu. Wirft bei Fehlern (nichts wird verändert).</summary>
    public static async Task InstallAsync(UpdateInfo info, IProgress<string> progress, string? restartArgs = null)
    {
        if (!Regex().IsMatch(info.Sha256))
            throw new InvalidOperationException("GitHub liefert für diese Version keine Prüfsumme – Update aus Sicherheitsgründen abgebrochen. Bitte den Installationsbefehl verwenden.");
        if (!info.DownloadUrl.StartsWith("https://github.com/bmk983/m365-manager/releases/download/", StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("Unerwartete Download-Adresse – Update abgebrochen.");

        var exe = Environment.ProcessPath ?? throw new InvalidOperationException("Programmpfad unbekannt.");
        var download = exe + ".download";
        var old = exe + ".old";

        try
        {
            progress.Report("Lade Version " + info.Version.ToString(3) + " …");
            using (var http = NewClient(TimeSpan.FromMinutes(10)))
            using (var response = await http.GetAsync(info.DownloadUrl, HttpCompletionOption.ResponseHeadersRead))
            {
                response.EnsureSuccessStatusCode();
                await using var src = await response.Content.ReadAsStreamAsync();
                await using var dst = File.Create(download);
                var buffer = new byte[81920];
                long done = 0;
                int read;
                var lastReport = 0L;
                while ((read = await src.ReadAsync(buffer)) > 0)
                {
                    await dst.WriteAsync(buffer.AsMemory(0, read));
                    done += read;
                    if (info.Size > 0 && done - lastReport > info.Size / 20)
                    {
                        lastReport = done;
                        progress.Report($"Lade Version {info.Version.ToString(3)} … {done * 100 / info.Size} %");
                    }
                }
            }

            progress.Report("Prüfe die Prüfsumme …");
            string hash;
            await using (var fs = File.OpenRead(download))
                hash = Convert.ToHexString(await SHA256.HashDataAsync(fs)).ToLowerInvariant();
            if (hash != info.Sha256)
                throw new InvalidOperationException("Die Prüfsumme der heruntergeladenen Datei stimmt nicht – Update abgebrochen.");

            progress.Report("Tausche die Programmdatei …");
            if (File.Exists(old)) File.Delete(old);          // Rest eines früheren Updates
            File.Move(exe, old);                              // laufende EXE darf umbenannt werden
            try
            {
                File.Move(download, exe);
            }
            catch
            {
                File.Move(old, exe);                          // zurückrollen
                throw;
            }
        }
        catch (UnauthorizedAccessException)
        {
            TryDelete(download);
            throw new InvalidOperationException("Keine Schreibrechte im Programmordner (" + Path.GetDirectoryName(exe) + "). Bitte den Installationsbefehl verwenden.");
        }
        catch
        {
            TryDelete(download);
            throw;
        }

        Log.Write("Update auf " + info.Version + " installiert – Neustart.");
        progress.Report("Starte neu …");
        Process.Start(new ProcessStartInfo(exe, "--after-update " + Environment.ProcessId + (restartArgs is null ? "" : " " + restartArgs))
        {
            UseShellExecute = false,
            WorkingDirectory = Path.GetDirectoryName(exe)!,
        });
        Application.Current.Shutdown();
    }

    /// <summary>Beim Start: auf das Ende der alten Instanz warten (gibt Profile und Browser-Daten frei) und Reste entfernen.</summary>
    public static void FinishPendingUpdate(string[] args)
    {
        var i = Array.FindIndex(args, a => a.Equals("--after-update", StringComparison.OrdinalIgnoreCase));
        if (i >= 0 && i + 1 < args.Length && int.TryParse(args[i + 1], out var pid))
        {
            try { using var p = Process.GetProcessById(pid); p.WaitForExit(30000); }
            catch (ArgumentException) { }   // schon beendet
            catch (Exception ex) { Log.Write("Update: Warten auf alte Instanz: " + ex.Message); }
        }
        if (Environment.ProcessPath is { } exe)
        {
            TryDelete(exe + ".old");
            TryDelete(exe + ".download");
        }
    }

    private static HttpClient NewClient(TimeSpan timeout)
    {
        var http = new HttpClient { Timeout = timeout };
        http.DefaultRequestHeaders.UserAgent.ParseAdd("M365Manager/" + Current.ToString(3));
        return http;
    }

    private static void TryDelete(string path)
    {
        try { if (File.Exists(path)) File.Delete(path); } catch { }
    }

    private static System.Text.RegularExpressions.Regex Regex() => new("^[0-9a-f]{64}$");
}
