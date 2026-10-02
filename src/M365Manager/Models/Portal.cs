using Wpf.Ui.Controls;

namespace M365Manager.Models;

public sealed record Portal(string Key, string Name, SymbolRegular Icon, Func<AdminProfile, string> Url)
{
    public static readonly Portal[] All =
    [
        new("admin", "Microsoft 365 Admin", SymbolRegular.Apps24, _ => "https://admin.microsoft.com"),
        new("entra", "Entra ID", SymbolRegular.ShieldKeyhole24, p => WithTenant("https://entra.microsoft.com", p)),
        new("intune", "Intune", SymbolRegular.Laptop24, p => WithTenant("https://intune.microsoft.com", p)),
        new("exchange", "Exchange", SymbolRegular.Mail24, _ => "https://admin.exchange.microsoft.com"),
        new("teams", "Teams", SymbolRegular.PeopleTeam24, _ => "https://admin.teams.microsoft.com"),
        new("sharepoint", "SharePoint", SymbolRegular.Folder24, p => p.EffectiveSharePointTenant is { } t
            ? "https://" + t + "-admin.sharepoint.com"
            : "https://admin.microsoft.com/sharepoint"),
        new("purview", "Purview", SymbolRegular.ShieldLock24, _ => "https://purview.microsoft.com"),
        new("defender", "Defender", SymbolRegular.Shield24, _ => "https://security.microsoft.com"),
        new("azure", "Azure", SymbolRegular.Cloud24, p => WithTenant("https://portal.azure.com", p)),
        new("power", "Power Platform", SymbolRegular.Flash24, _ => "https://admin.powerplatform.microsoft.com"),
        new("graph", "Graph Explorer", SymbolRegular.Code24, _ => "https://developer.microsoft.com/graph/graph-explorer"),
    ];

    /// <summary>Azure-basierte Portale springen per "#@tenant" direkt ins richtige Verzeichnis.</summary>
    private static string WithTenant(string url, AdminProfile p) =>
        string.IsNullOrWhiteSpace(p.Tenant) ? url : url + "/#@" + p.Tenant;
}