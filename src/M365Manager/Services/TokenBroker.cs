using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Web;
using System.Windows;
using System.Windows.Interop;
using M365Manager.Models;
using M365Manager.Views;
using Microsoft.Web.WebView2.Core;

namespace M365Manager.Services;

public sealed record TokenResult(string AccessToken, DateTimeOffset ExpiresOn);

public sealed class TokenException(string message) : Exception(message);

/// <summary>
/// Holt Tokens für die PowerShell-Module über die Browser-Sitzung des Profils (Authorization Code + PKCE).
/// Ist der Browser bereits angemeldet (inkl. MFA), passiert das unsichtbar – sonst erscheint einmal ein Anmeldefenster.
/// Es werden die offiziellen Client-IDs der jeweiligen Module verwendet. Refresh-Tokens liegen nur im Arbeitsspeicher.
/// </summary>
public sealed class TokenBroker
{
    private const string GraphPowerShell = "14d82eec-204b-4c2f-b7e8-296a70dab67e";
    private const string ExchangePowerShell = "fb78d390-0c51-40cd-8e17-fdbfab77341b";
    private const string TeamsPowerShell = "12128f48-ec9e-42f0-b203-ea49fb6af367";
    private const string RedirectUri = "http://localhost";

    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(60) };

    private readonly Func<AdminProfile> _profile;
    private readonly Window _owner;
    private readonly SemaphoreSlim _gate = new(1, 1);
    private readonly Dictionary<string, string> _refreshTokens = new();   // pro Client-ID
    private readonly Dictionary<string, TokenResult> _cache = new();      // pro Client-ID + Scope

    public TokenBroker(Func<AdminProfile> profile, Window owner)
    {
        _profile = profile;
        _owner = owner;
    }

    /// <summary>Vergisst alle Tokens (z. B. nach "Browser-Anmeldung zurücksetzen").</summary>
    public void Clear()
    {
        _refreshTokens.Clear();
        _cache.Clear();
    }

    private static (string ClientId, string Scope, string Label) Describe(string target, AdminProfile p, string? extraScopes)
    {
        switch (target)
        {
            case "Graph":
                var scopes = (p.GraphScopes + " " + extraScopes).Split([' ', ',', ';'], StringSplitOptions.RemoveEmptyEntries)
                    .Distinct(StringComparer.OrdinalIgnoreCase)
                    .Select(s => s.Contains("://") ? s : "https://graph.microsoft.com/" + s);
                return (GraphPowerShell, string.Join(' ', scopes), "Microsoft Graph");
            case "Exchange":
                return (ExchangePowerShell, "https://outlook.office365.com/.default", "Exchange Online");
            case "Purview":
                return (ExchangePowerShell, "https://ps.compliance.protection.outlook.com/.default", "Purview");
            case "TeamsGraph":
                return (TeamsPowerShell, "https://graph.microsoft.com/.default", "Microsoft Teams");
            case "Teams":
                return (TeamsPowerShell, "48ac35b8-9aa8-4d74-927d-1f4a14a0b239/.default", "Microsoft Teams");
            case "SharePoint":
                if (string.IsNullOrWhiteSpace(p.PnPClientId)) throw new TokenException("Für SharePoint fehlt die PnP ClientId im Profil.");
                var sp = p.EffectiveSharePointTenant ?? throw new TokenException("SharePoint-Tenantname ist unbekannt.");
                return (p.PnPClientId!, "https://" + sp + "-admin.sharepoint.com/.default", "SharePoint");
            case "SharePointSite":
            {
                // Beliebige Site des Tenants (Connect-PnPOnline -Url …) – nur *.sharepoint.com
                if (string.IsNullOrWhiteSpace(p.PnPClientId)) throw new TokenException("Für SharePoint fehlt die PnP ClientId im Profil.");
                var host = (extraScopes ?? "").Trim().ToLowerInvariant();
                if (!System.Text.RegularExpressions.Regex.IsMatch(host, @"^[a-z0-9-]+\.sharepoint\.com$"))
                    throw new TokenException("Ungültige SharePoint-Adresse: " + host);
                return (p.PnPClientId!, "https://" + host + "/.default", "SharePoint");
            }
            default:
                throw new TokenException("Unbekannter Dienst: " + target);
        }
    }

    public async Task<TokenResult> GetAsync(string target, string? extraScopes = null)
    {
        var profile = _profile();
        var (clientId, scope, label) = Describe(target, profile, extraScopes);
        var tenant = string.IsNullOrWhiteSpace(profile.Tenant) ? "organizations" : profile.Tenant;
        var key = clientId + "|" + scope;

        await _gate.WaitAsync();
        try
        {
            if (_cache.TryGetValue(key, out var cached) && cached.ExpiresOn > DateTimeOffset.UtcNow.AddMinutes(10))
                return cached;

            // 1. Still erneuern
            if (_refreshTokens.TryGetValue(clientId, out var refresh))
            {
                try
                {
                    return Store(key, clientId, await RedeemAsync(tenant, new()
                    {
                        ["client_id"] = clientId,
                        ["grant_type"] = "refresh_token",
                        ["refresh_token"] = refresh,
                        ["scope"] = scope + " offline_access",
                    }));
                }
                catch (TokenException ex)
                {
                    Log.Write("Token-Refresh " + target + ": " + ex.Message);
                    _refreshTokens.Remove(clientId);
                }
            }

            // 2. Über die Browser-Sitzung – erst unsichtbar, dann mit Fenster
            var pkce = Pkce.Create();
            var code = await AuthorizeAsync(profile, tenant, clientId, scope, pkce, interactive: false, label)
                       ?? await AuthorizeAsync(profile, tenant, clientId, scope, pkce, interactive: true, label)
                       ?? throw new TokenException("Anmeldung abgebrochen.");

            return Store(key, clientId, await RedeemAsync(tenant, new()
            {
                ["client_id"] = clientId,
                ["grant_type"] = "authorization_code",
                ["code"] = code,
                ["redirect_uri"] = RedirectUri,
                ["code_verifier"] = pkce.Verifier,
                ["scope"] = scope + " offline_access",
            }));
        }
        finally
        {
            _gate.Release();
        }
    }

    private TokenResult Store(string key, string clientId, (TokenResult Token, string? Refresh) r)
    {
        if (r.Refresh is not null) _refreshTokens[clientId] = r.Refresh;
        _cache[key] = r.Token;
        return r.Token;
    }

    private static async Task<(TokenResult, string?)> RedeemAsync(string tenant, Dictionary<string, string> form)
    {
        using var response = await Http.PostAsync("https://login.microsoftonline.com/" + Uri.EscapeDataString(tenant) + "/oauth2/v2.0/token",
            new FormUrlEncodedContent(form));
        var json = await response.Content.ReadAsStringAsync();
        using var doc = JsonDocument.Parse(json);
        var root = doc.RootElement;

        if (!response.IsSuccessStatusCode || !root.TryGetProperty("access_token", out var at))
        {
            var description = root.TryGetProperty("error_description", out var d) ? d.GetString() : root.TryGetProperty("error", out var e) ? e.GetString() : json;
            throw new TokenException((description ?? "Unbekannter Fehler").Split('\n')[0].Trim());
        }

        var expires = root.TryGetProperty("expires_in", out var ei) ? ei.GetInt32() : 3600;
        var refresh = root.TryGetProperty("refresh_token", out var rt) ? rt.GetString() : null;
        return (new TokenResult(at.GetString()!, DateTimeOffset.UtcNow.AddSeconds(expires - 30)), refresh);
    }

    private async Task<string?> AuthorizeAsync(AdminProfile profile, string tenant, string clientId, string scope, Pkce pkce, bool interactive, string label)
    {
        var state = Pkce.RandomString(16);
        var url = "https://login.microsoftonline.com/" + Uri.EscapeDataString(tenant) + "/oauth2/v2.0/authorize" +
                  "?client_id=" + clientId +
                  "&response_type=code" +
                  "&redirect_uri=" + Uri.EscapeDataString(RedirectUri) +
                  "&response_mode=query" +
                  "&scope=" + Uri.EscapeDataString(scope + " offline_access openid profile") +
                  "&code_challenge=" + pkce.Challenge + "&code_challenge_method=S256" +
                  "&state=" + state +
                  (string.IsNullOrWhiteSpace(profile.Upn) ? "" : "&login_hint=" + Uri.EscapeDataString(profile.Upn)) +
                  (interactive ? "" : "&prompt=none");

        var env = await WebViewEnvironments.GetProfileAsync(profile.Id);
        var result = new TaskCompletionSource<string?>(TaskCreationOptions.RunContinuationsAsynchronously);

        void OnNavigation(object? sender, CoreWebView2NavigationStartingEventArgs e)
        {
            if (!e.Uri.StartsWith(RedirectUri, StringComparison.OrdinalIgnoreCase)) return;
            e.Cancel = true;
            var query = HttpUtility.ParseQueryString(new Uri(e.Uri).Query);
            if (query["state"] != state) { result.TrySetResult(null); return; }
            if (query["error"] is { } error)
            {
                Log.Write("Authorize " + label + (interactive ? "" : " (still)") + ": " + error + " " + query["error_description"]?.Split('\n')[0]);
                // Bei einer stillen Anfrage bedeutet ein Fehler nur "Interaktion nötig".
                if (interactive) result.TrySetException(new TokenException(query["error_description"]?.Split('\n')[0] ?? error));
                else result.TrySetResult(null);
                return;
            }
            result.TrySetResult(query["code"]);
        }

        if (!interactive)
        {
            var hwnd = new WindowInteropHelper(_owner).Handle;
            var controller = await env.CreateCoreWebView2ControllerAsync(hwnd);
            try
            {
                controller.IsVisible = false;
                controller.CoreWebView2.NavigationStarting += OnNavigation;
                controller.CoreWebView2.Navigate(url);
                var finished = await Task.WhenAny(result.Task, Task.Delay(TimeSpan.FromSeconds(25)));
                return finished == result.Task ? await result.Task : null;
            }
            finally
            {
                controller.Close();
            }
        }

        var window = new AuthWindow(label, profile) { Owner = _owner };
        window.Closed += (_, _) => result.TrySetResult(null);
        window.Loaded += async (_, _) =>
        {
            await window.Browser.EnsureCoreWebView2Async(env);
            window.Browser.CoreWebView2.NavigationStarting += OnNavigation;
            window.Browser.CoreWebView2.Navigate(url);
        };
        window.Show();
        window.Activate();
        try
        {
            return await result.Task;
        }
        finally
        {
            if (window.IsLoaded) window.Close();
        }
    }

    private sealed record Pkce(string Verifier, string Challenge)
    {
        public static Pkce Create()
        {
            var verifier = RandomString(32);
            var challenge = Base64Url(SHA256.HashData(Encoding.ASCII.GetBytes(verifier)));
            return new Pkce(verifier, challenge);
        }

        public static string RandomString(int bytes) => Base64Url(RandomNumberGenerator.GetBytes(bytes));

        private static string Base64Url(byte[] data) => Convert.ToBase64String(data).TrimEnd('=').Replace('+', '-').Replace('/', '_');
    }
}