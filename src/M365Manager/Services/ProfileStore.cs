using System.IO;
using System.Text.Json;
using M365Manager.Models;

namespace M365Manager.Services;

public static class ProfileStore
{
    private static readonly JsonSerializerOptions Json = new() { WriteIndented = true };
    private static readonly object Gate = new();
    private static List<AdminProfile>? _cache;

    public static event Action? Changed;

    public static IReadOnlyList<AdminProfile> All()
    {
        lock (Gate)
        {
            _cache ??= Load();
            return _cache
                .OrderByDescending(p => p.LastUsed ?? DateTime.MinValue)
                .ThenBy(p => p.Name, StringComparer.CurrentCultureIgnoreCase)
                .ToList();
        }
    }

    public static AdminProfile? Get(string id)
    {
        lock (Gate)
        {
            _cache ??= Load();
            return _cache.FirstOrDefault(p => p.Id == id);
        }
    }

    public static void Save(AdminProfile profile)
    {
        lock (Gate)
        {
            _cache ??= Load();
            var i = _cache.FindIndex(p => p.Id == profile.Id);
            if (i >= 0) _cache[i] = profile; else _cache.Add(profile);
            Persist();
        }
        Changed?.Invoke();
    }

    public static void Delete(string id)
    {
        lock (Gate)
        {
            _cache ??= Load();
            _cache.RemoveAll(p => p.Id == id);
            Persist();
        }
        try
        {
            var dir = AppPaths.ProfileDir(id);
            if (Directory.Exists(dir)) Directory.Delete(dir, recursive: true);
        }
        catch (Exception ex)
        {
            Log.Write("Profilordner konnte nicht gelöscht werden: " + ex.Message);
        }
        Changed?.Invoke();
    }

    private static List<AdminProfile> Load()
    {
        try
        {
            if (File.Exists(AppPaths.ProfilesFile))
                return JsonSerializer.Deserialize<List<AdminProfile>>(File.ReadAllText(AppPaths.ProfilesFile)) ?? [];
        }
        catch (Exception ex)
        {
            Log.Write("profiles.json unlesbar: " + ex.Message);
            try { File.Copy(AppPaths.ProfilesFile, AppPaths.ProfilesFile + ".broken", overwrite: true); } catch { }
        }
        return [];
    }

    private static void Persist()
    {
        var tmp = AppPaths.ProfilesFile + ".tmp";
        File.WriteAllText(tmp, JsonSerializer.Serialize(_cache, Json));
        File.Move(tmp, AppPaths.ProfilesFile, overwrite: true);
    }
}
