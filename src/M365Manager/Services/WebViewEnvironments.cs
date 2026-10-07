using System.Globalization;
using System.IO;
using Microsoft.Web.WebView2.Core;

namespace M365Manager.Services;

/// <summary>
/// Jedes Profil bekommt einen eigenen WebView2-Datenordner (Cookies, Anmeldungen, Cache) –
/// dadurch sind die Tenants sauber voneinander getrennt. Die App-Oberfläche (Terminal) hat einen eigenen.
/// </summary>
public static class WebViewEnvironments
{
    private static Task<CoreWebView2Environment>? _ui;
    private static readonly Dictionary<string, Task<CoreWebView2Environment>> Profiles = new();

    public static Task<CoreWebView2Environment> GetUiAsync() =>
        _ui ??= CoreWebView2Environment.CreateAsync(null, AppPaths.UiWebViewDir);

    public static Task<CoreWebView2Environment> GetProfileAsync(string profileId)
    {
        lock (Profiles)
        {
            if (!Profiles.TryGetValue(profileId, out var task))
            {
                var options = new CoreWebView2EnvironmentOptions
                {
                    // Nicht mit dem Windows-Konto anmelden – hier zählt nur das Admin-Konto des Profils.
                    AllowSingleSignOnUsingOSPrimaryAccount = false,
                    Language = CultureInfo.CurrentUICulture.Name,
                };
                task = CoreWebView2Environment.CreateAsync(null, Path.Combine(AppPaths.ProfileDir(profileId), "webview"), options);
                Profiles[profileId] = task;
            }
            return task;
        }
    }

    /// <summary>Vergisst eine Umgebung, deren Browser-Prozess beendet wurde – beim nächsten Zugriff wird sie neu erstellt.</summary>
    public static void Forget(string profileId, CoreWebView2Environment dead)
    {
        lock (Profiles)
        {
            if (Profiles.TryGetValue(profileId, out var task) && task.IsCompletedSuccessfully && ReferenceEquals(task.Result, dead))
                Profiles.Remove(profileId);
        }
    }
}