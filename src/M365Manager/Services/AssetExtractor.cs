using System.IO;
using System.Reflection;

namespace M365Manager.Services;

/// <summary>
/// Entpackt die eingebetteten Dateien (Terminal, Editor, PowerShell-Skripte) in den Datenordner –
/// nur wenn sich die App-Version geändert hat oder Dateien fehlen.
/// </summary>
public static class AssetExtractor
{
    public static void ExtractAll()
    {
        var asm = Assembly.GetExecutingAssembly();
        var stampFile = Path.Combine(AppPaths.AppDir, ".assets-version");
        var stamp = asm.ManifestModule.ModuleVersionId.ToString();
        var upToDate = File.Exists(stampFile) && File.ReadAllText(stampFile).Trim() == stamp;

        foreach (var name in asm.GetManifestResourceNames())
        {
            if (!name.StartsWith("assets/", StringComparison.Ordinal))
                continue;

            var relative = name["assets/".Length..].Replace('/', Path.DirectorySeparatorChar);
            var target = Path.Combine(AppPaths.AppDir, relative);
            if (upToDate && File.Exists(target)) continue;

            Directory.CreateDirectory(Path.GetDirectoryName(target)!);
            using var src = asm.GetManifestResourceStream(name)!;
            using var dst = File.Create(target);
            src.CopyTo(dst);
        }

        File.WriteAllText(stampFile, stamp);
    }
}