using System.IO;
using System.IO.Pipes;
using System.Text;

namespace M365Manager.Terminal;

/// <summary>
/// Rückkanal von der PowerShell-Sitzung zur App (Verbindungsstatus, gemeldete Profilwerte).
/// Named Pipe, nur für den aktuellen Benutzer zugänglich.
/// </summary>
public sealed class PipeListener : IDisposable
{
    private readonly CancellationTokenSource _cts = new();

    public string Name { get; } = "m365m-" + Guid.NewGuid().ToString("N");

    public PipeListener(Action<string> onLine)
    {
        _ = Task.Run(() => LoopAsync(onLine, _cts.Token));
    }

    private async Task LoopAsync(Action<string> onLine, CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            try
            {
                await using var server = new NamedPipeServerStream(Name, PipeDirection.In, 1, PipeTransmissionMode.Byte,
                    PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
                await server.WaitForConnectionAsync(ct);
                using var reader = new StreamReader(server, new UTF8Encoding(false));
                string? line;
                while ((line = await reader.ReadLineAsync(ct)) is not null)
                    onLine(line);
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