using System.IO;

namespace M365Manager.Services;

/// <summary>
/// Alle Daten liegen portabel neben der EXE (Ordner "M365Manager-Data").
/// Ist dieser Ordner nicht beschreibbar oder liegt die EXE auf einem Netzlaufwerk,
/// wird auf %LOCALAPPDATA%\M365Manager ausgewichen.
/// </summary>
public static class AppPaths
{
    public static string DataRoot { get; private set; } = "";
    public static string AppDir => Path.Combine(DataRoot, "app");
    public static string TerminalAssetsDir => Path.Combine(AppDir, "terminal");
    public static string ScriptsDir => Path.Combine(AppDir, "ps");
    public static string EditorAssetsDir => Path.Combine(AppDir, "editor");
    /// <summary>Gemeinsamer Ordner für eigene Skripte aller Profile.</summary>
    public static string UserScriptsDir => Path.Combine(DataRoot, "scripts");
    /// <summary>Temporäre Dateien für F5/F8 aus dem Editor.</summary>
    public static string RunDir => Path.Combine(UserScriptsDir, ".run");
    public static string UiWebViewDir => Path.Combine(AppDir, "webview");
    public static string PwshDir => Path.Combine(DataRoot, "pwsh");
    public static string ModulesDir => Path.Combine(DataRoot, "modules");
    public static string ProfilesFile => Path.Combine(DataRoot, "profiles.json");
    public static string LogFile => Path.Combine(DataRoot, "m365manager.log");
    public static bool IsPortable { get; private set; }

    public static string ProfileDir(string profileId) => Path.Combine(DataRoot, "profiles", profileId);

    public static void Initialize()
    {
        var exeDir = AppContext.BaseDirectory;
        var portable = Path.Combine(exeDir, "M365Manager-Data");
        if (!exeDir.StartsWith(@"\\") && IsWritable(portable))
        {
            DataRoot = portable;
            IsPortable = true;
        }
        else
        {
            DataRoot = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "M365Manager");
            Directory.CreateDirectory(DataRoot);
        }
        Directory.CreateDirectory(AppDir);
    }

    private static bool IsWritable(string dir)
    {
        try
        {
            Directory.CreateDirectory(dir);
            var probe = Path.Combine(dir, ".write-test");
            File.WriteAllText(probe, "ok");
            File.Delete(probe);
            return true;
        }
        catch
        {
            return false;
        }
    }
}
