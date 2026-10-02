using System.IO;
using System.Reflection;

namespace M365Manager.Services;

/// <summary>Entpackt die eingebetteten Terminal- und PowerShell-Dateien in den Datenordner.</summary>
public static class AssetExtractor
{
    public static void ExtractAll()
    {
        var asm = Assembly.GetExecutingAssembly();
        foreach (var name in asm.GetManifestResourceNames())
        {
            if (!name.StartsWith("assets/", StringComparison.Ordinal))
                continue;

            var relative = name["assets/".Length..].Replace('/', Path.DirectorySeparatorChar);
            var target = Path.Combine(AppPaths.AppDir, relative);
            Directory.CreateDirectory(Path.GetDirectoryName(target)!);

            using var src = asm.GetManifestResourceStream(name)!;
            using var dst = File.Create(target);
            src.CopyTo(dst);
        }
    }
}
