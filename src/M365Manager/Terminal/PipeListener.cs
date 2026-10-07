using System.IO;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace M365Manager.Terminal;

/// <summary>
/// Kanal zwischen PowerShell-Sitzung und App (Verbindungsstatus, Profilwerte, Token-Anfragen).
/// Named Pipe, nur für den aktuellen Benutzer zugänglich.
/// Zeilen mit "req|&lt;id&gt;|…" sind Anfragen und werden mit "res|&lt;id&gt;|…" beantwortet.
/// </summary>
public sealed class PipeListener : IDisposable
{
    private readonly CancellationTokenSource _cts = new();

    public string Name { get; } = "m365m-" + Guid.NewGuid().ToString("N");

    private readonly Func<int?> _expectedClient;

    /// <param name="expectedClient">Prozess-ID, die sich verbinden darf (die PowerShell dieses Terminals). Andere werden abgewiesen.</param>
    public PipeListener(Action<string> onLine, Func<string, string[], Task<string>> onRequest, Func<int?> expectedClient)
    {
        _expectedClient = expectedClient;
        _ = Task.Run(() => LoopAsync(onLine, onRequest, _cts.Token));
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetNamedPipeClientProcessId(SafePipeHandle pipe, out uint clientProcessId);

    private bool IsExpectedClient(NamedPipeServerStream server)
    {
        if (!GetNamedPipeClientProcessId(server.SafePipeHandle, out var pid)) return false;
        var expected = _expectedClient();
        if (expected == (int)pid) return true;
        Services.Log.Write("Pipe: Verbindung von fremdem Prozess " + pid + " abgewiesen (erwartet " + expected + ").");
        return false;
    }

    private async Task LoopAsync(Action<string> onLine, Func<string, string[], Task<string>> onRequest, CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            try
            {
                await using var server = new NamedPipeServerStream(Name, PipeDirection.InOut, 1, PipeTransmissionMode.Byte,
                    PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
                await server.WaitForConnectionAsync(ct);
                if (!IsExpectedClient(server))
                {
                    server.Disconnect();
                    continue;
                }
                using var reader = new StreamReader(server, new UTF8Encoding(false), false, 4096, leaveOpen: true);
                await using var writer = new StreamWriter(server, new UTF8Encoding(false), 4096, leaveOpen: true) { AutoFlush = true };
                var writeLock = new SemaphoreSlim(1, 1);

                string? line;
                while ((line = await reader.ReadLineAsync(ct)) is not null)
                {
                    if (!line.StartsWith("req|", StringComparison.Ordinal))
                    {
                        onLine(line);
                        continue;
                    }

                    var parts = line.Split('|');
                    if (parts.Length < 3) continue;
                    var id = parts[1];
                    _ = Task.Run(async () =>
                    {
                        string answer;
                        try { answer = "ok|" + await onRequest(parts[2], parts[3..]); }
                        catch (Exception ex) { answer = "err|" + ex.Message.Replace('|', '/').Replace('\n', ' ').Replace('\r', ' '); }

                        try { await writeLock.WaitAsync(ct); }
                        catch (OperationCanceledException) { return; }
                        try { await writer.WriteLineAsync("res|" + id + "|" + answer); }
                        catch (Exception ex) when (ex is IOException or ObjectDisposedException or OperationCanceledException) { }
                        finally { writeLock.Release(); }
                    }, ct);
                }
            }
            catch (OperationCanceledException)
            {
                return;
            }
            catch (Exception ex)
            {
                Services.Log.Write("Pipe: " + ex.Message);
                await Task.Delay(500, ct).ContinueWith(_ => { });
            }
        }
    }

    public void Dispose() => _cts.Cancel();
}