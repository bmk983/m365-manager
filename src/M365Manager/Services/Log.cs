using System.IO;

namespace M365Manager.Services;

public static class Log
{
    private static readonly object Gate = new();

    public static void Write(string message)
    {
        try
        {
            lock (Gate)
            {
                // Bei 2 MB rotieren: eine ältere Datei (.old) bleibt erhalten.
                var info = new FileInfo(AppPaths.LogFile);
                if (info.Exists && info.Length > 2 * 1024 * 1024)
                    File.Move(info.FullName, info.FullName + ".old", overwrite: true);
                File.AppendAllText(AppPaths.LogFile, $"{DateTime.Now:yyyy-MM-dd HH:mm:ss} {message}{Environment.NewLine}");
            }
        }
        catch
        {
            // Logging darf nie die App stoppen.
        }
    }
}
