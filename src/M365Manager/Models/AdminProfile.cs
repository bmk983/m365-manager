using System.Text.Json.Serialization;
using System.Windows.Media;

namespace M365Manager.Models;

public sealed class AdminProfile
{
    public const string DefaultGraphScopes =
        "User.ReadWrite.All Group.ReadWrite.All Directory.ReadWrite.All Organization.Read.All " +
        "RoleManagement.Read.Directory Application.Read.All Policy.Read.All AuditLog.Read.All Reports.Read.All " +
        "DeviceManagementManagedDevices.ReadWrite.All DeviceManagementConfiguration.Read.All " +
        "SecurityIncident.Read.All SecurityAlert.Read.All ThreatHunting.Read.All";

    public static readonly string[] Palette =
        ["#0F6CBD", "#5B5FC7", "#8764B8", "#C239B3", "#D13438", "#CA5010", "#C19C00", "#13A10E", "#038387", "#69797E"];

    public string Id { get; set; } = Guid.NewGuid().ToString("N");
    public string Name { get; set; } = "";
    public string Upn { get; set; } = "";
    public string? TenantDomain { get; set; }
    public string? SharePointTenant { get; set; }
    public string? PnPClientId { get; set; }
    public string Color { get; set; } = Palette[0];
    public string GraphScopes { get; set; } = DefaultGraphScopes;
    public DateTime? LastUsed { get; set; }

    /// <summary>Tenant für Anmeldungen: explizit gesetzt oder die Domain des UPN.</summary>
    [JsonIgnore]
    public string Tenant =>
        !string.IsNullOrWhiteSpace(TenantDomain) ? TenantDomain.Trim()
        : Upn.Contains('@') ? Upn[(Upn.IndexOf('@') + 1)..] : "";

    /// <summary>SharePoint-Tenantname (contoso), gesetzt oder aus *.onmicrosoft.com abgeleitet.</summary>
    [JsonIgnore]
    public string? EffectiveSharePointTenant
    {
        get
        {
            if (!string.IsNullOrWhiteSpace(SharePointTenant)) return SharePointTenant.Trim();
            const string suffix = ".onmicrosoft.com";
            return Tenant.EndsWith(suffix, StringComparison.OrdinalIgnoreCase) ? Tenant[..^suffix.Length] : null;
        }
    }

    [JsonIgnore]
    public string Initials
    {
        get
        {
            var parts = Name.Split([' ', '-', '_', '.'], StringSplitOptions.RemoveEmptyEntries);
            var s = parts.Length switch
            {
                0 => "?",
                1 => parts[0][..Math.Min(2, parts[0].Length)],
                _ => string.Concat(parts[0][0], parts[1][0])
            };
            return s.ToUpperInvariant();
        }
    }

    [JsonIgnore]
    public Brush ColorBrush
    {
        get
        {
            try { return new SolidColorBrush((System.Windows.Media.Color)ColorConverter.ConvertFromString(Color)); }
            catch { return new SolidColorBrush(Colors.SteelBlue); }
        }
    }

    [JsonIgnore]
    public string Subtitle => string.IsNullOrWhiteSpace(TenantDomain) || Upn.EndsWith("@" + TenantDomain.Trim(), StringComparison.OrdinalIgnoreCase) ? Upn : Upn + "  ·  " + TenantDomain.Trim();

    [JsonIgnore]
    public string LastUsedText => LastUsed is { } d ? "Zuletzt geöffnet " + d.ToString("dd.MM.yyyy HH:mm") : "Noch nie geöffnet";
}
