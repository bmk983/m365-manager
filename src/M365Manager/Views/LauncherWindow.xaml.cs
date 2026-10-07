using System.ComponentModel;
using System.Diagnostics;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using M365Manager.Models;
using M365Manager.Services;
using Wpf.Ui.Appearance;
using Wpf.Ui.Controls;
using MessageBox = Wpf.Ui.Controls.MessageBox;
using MessageBoxResult = Wpf.Ui.Controls.MessageBoxResult;

namespace M365Manager.Views;

public partial class LauncherWindow : FluentWindow
{
    private AdminProfile? _editing;
    private bool _isNew;
    private string _selectedColor = AdminProfile.Palette[0];

    public LauncherWindow()
    {
        InitializeComponent();
        SystemThemeWatcher.Watch(this);

        SetupService.LogLine += line => Dispatcher.BeginInvoke(() => AppendLog(line));
        SetupService.StateChanged += () => Dispatcher.BeginInvoke(RefreshEnvironment);
        ProfileStore.Changed += () => Dispatcher.BeginInvoke(RefreshProfiles);

        foreach (var line in SetupService.LogHistory) AppendLog(line);
        RefreshProfiles();
        RefreshEnvironment();

        Loaded += (_, _) =>
        {
            if (!SetupService.IsReady)
            {
                LogExpander.IsExpanded = true;
                _ = SetupService.EnsureReadyAsync();
            }
            if (ProfileStore.All().Count == 0) StartEdit(null);
            _ = CheckForUpdateAsync();
        };
    }

    // ------------------------------------------------------------------ Update-Hinweis

    private const string InstallCommand = "irm https://raw.githubusercontent.com/bmk983/m365-manager/main/install.ps1 | iex";
    private string? _releaseUrl;

    /// <summary>Fragt GitHub nach der neuesten Version. Rein informativ – es wird nichts automatisch geladen oder ersetzt.</summary>
    private async Task CheckForUpdateAsync()
    {
        var current = typeof(App).Assembly.GetName().Version ?? new Version(0, 0);
        VersionText.Text = "Version " + current.ToString(3) + " · portabel – nichts wird installiert.";
        try
        {
            using var http = new System.Net.Http.HttpClient { Timeout = TimeSpan.FromSeconds(8) };
            http.DefaultRequestHeaders.UserAgent.ParseAdd("M365Manager/" + current.ToString(3));
            using var doc = System.Text.Json.JsonDocument.Parse(
                await http.GetStringAsync("https://api.github.com/repos/bmk983/m365-manager/releases/latest"));
            var tag = doc.RootElement.GetProperty("tag_name").GetString()?.TrimStart('v');
            if (!Version.TryParse(tag, out var latest)) return;
            if (new Version(latest.Major, latest.Minor, Math.Max(latest.Build, 0)) <= new Version(current.Major, current.Minor, Math.Max(current.Build, 0))) return;

            _releaseUrl = doc.RootElement.GetProperty("html_url").GetString();
            UpdateText.Text = "Version " + latest.ToString(3) + " ist verfügbar (du hast " + current.ToString(3) + ").";
            UpdateBar.Visibility = Visibility.Visible;
        }
        catch (Exception ex)
        {
            Log.Write("Update-Prüfung: " + ex.Message);   // offline o. Ä. – kein Problem
        }
    }

    private void CopyUpdateCommand_Click(object sender, RoutedEventArgs e) => Clipboard.SetText(InstallCommand);

    private void OpenRelease_Click(object sender, RoutedEventArgs e)
    {
        if (_releaseUrl is not null) Process.Start(new ProcessStartInfo(_releaseUrl) { UseShellExecute = true });
    }

    // ------------------------------------------------------------------ Profile

    private void RefreshProfiles()
    {
        var all = ProfileStore.All();
        ProfileList.ItemsSource = all;
        EmptyState.Visibility = all.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        ProfileCountText.Text = all.Count switch { 0 => "", 1 => "1 PROFIL", _ => all.Count + " PROFILE" };
    }

    private static AdminProfile? ProfileOf(object sender) => (sender as FrameworkElement)?.DataContext as AdminProfile;

    private void Card_Click(object sender, MouseButtonEventArgs e)
    {
        // Klicks auf die Buttons der Karte nicht als "Öffnen" werten.
        if (e.OriginalSource is DependencyObject d && FindParent<System.Windows.Controls.Button>(d) is not null) return;
        if (ProfileOf(sender) is { } p) App.OpenProfile(p);
    }

    private void Open_Click(object sender, RoutedEventArgs e)
    {
        if (ProfileOf(sender) is { } p) App.OpenProfile(p);
    }

    private void Edit_Click(object sender, RoutedEventArgs e)
    {
        if (ProfileOf(sender) is { } p) StartEdit(p);
    }

    private async void Delete_Click(object sender, RoutedEventArgs e)
    {
        if (ProfileOf(sender) is not { } p) return;
        if (App.ProfileWindows.Any(w => w.ProfileId == p.Id))
        {
            await new MessageBox
            {
                Title = "Profil ist geöffnet",
                Content = "Bitte schließe zuerst das Fenster von „" + p.Name + "“.",
                CloseButtonText = "OK",
            }.ShowDialogAsync();
            return;
        }

        var result = await new MessageBox
        {
            Title = "Profil löschen?",
            Content = "„" + p.Name + "“ wird entfernt – inklusive der gespeicherten Browser-Anmeldung dieses Profils.\n\nIm Tenant selbst wird nichts gelöscht.",
            PrimaryButtonText = "Löschen",
            PrimaryButtonAppearance = ControlAppearance.Danger,
            CloseButtonText = "Abbrechen",
        }.ShowDialogAsync();

        if (result == MessageBoxResult.Primary)
        {
            ProfileStore.Delete(p.Id);
            if (_editing?.Id == p.Id) CloseEditor();
        }
    }

    private void NewProfile_Click(object sender, RoutedEventArgs e) => StartEdit(null);

    // ------------------------------------------------------------------ Editor

    public void StartEdit(AdminProfile? profile)
    {
        _isNew = profile is null;
        _editing = profile ?? new AdminProfile();
        EditorTitle.Text = _isNew ? "Neues Profil" : "Profil bearbeiten";
        NameBox.Text = _editing.Name;
        UpnBox.Text = _editing.Upn;
        TenantBox.Text = _editing.TenantDomain ?? "";
        SharePointBox.Text = _editing.SharePointTenant ?? "";
        PnPBox.Text = _editing.PnPClientId ?? "";
        ScopesBox.Text = _editing.GraphScopes;
        _selectedColor = _isNew ? NextColor() : _editing.Color;
        BuildColorPanel();
        EditorError.Visibility = Visibility.Collapsed;

        EnvCard.Visibility = Visibility.Collapsed;
        EditorCard.Visibility = Visibility.Visible;
        NameBox.Focus();
    }

    private static string NextColor()
    {
        var used = ProfileStore.All().Select(p => p.Color).ToHashSet(StringComparer.OrdinalIgnoreCase);
        return AdminProfile.Palette.FirstOrDefault(c => !used.Contains(c)) ?? AdminProfile.Palette[0];
    }

    private void BuildColorPanel()
    {
        ColorPanel.Children.Clear();
        foreach (var color in AdminProfile.Palette)
        {
            var selected = string.Equals(color, _selectedColor, StringComparison.OrdinalIgnoreCase);
            var swatch = new Border
            {
                Width = 24,
                Height = 24,
                CornerRadius = new CornerRadius(12),
                Margin = new Thickness(0, 0, 7, 4),
                Cursor = Cursors.Hand,
                BorderThickness = new Thickness(selected ? 3 : 0),
                Background = (Brush)new BrushConverter().ConvertFromString(color)!,
                ToolTip = color,
            };
            swatch.SetResourceReference(Border.BorderBrushProperty, "TextFillColorPrimaryBrush");
            swatch.MouseLeftButtonUp += (_, _) => { _selectedColor = color; BuildColorPanel(); };
            ColorPanel.Children.Add(swatch);
        }
    }

    private void ResetScopes_Click(object sender, RoutedEventArgs e) => ScopesBox.Text = AdminProfile.DefaultGraphScopes;

    private void CancelEdit_Click(object sender, RoutedEventArgs e) => CloseEditor();

    private void CloseEditor()
    {
        _editing = null;
        EditorCard.Visibility = Visibility.Collapsed;
        EnvCard.Visibility = Visibility.Visible;
    }

    private void Save_Click(object sender, RoutedEventArgs e)
    {
        if (_editing is null) return;

        var name = NameBox.Text.Trim();
        var upn = UpnBox.Text.Trim();
        var tenant = TenantBox.Text.Trim();
        var sp = NormalizeSharePoint(SharePointBox.Text);
        var pnp = PnPBox.Text.Trim();

        string? error = null;
        if (name.Length == 0) error = "Bitte einen Anzeigenamen angeben.";
        else if (!Regex.IsMatch(upn, @"^[^@\s]+@[^@\s]+\.[^@\s]+$")) error = "Der UPN sieht nicht gültig aus (name@domain.tld).";
        else if (tenant.Length > 0 && !Regex.IsMatch(tenant, @"^([0-9a-fA-F-]{36}|[a-zA-Z0-9.-]+\.[a-zA-Z]{2,})$")) error = "Tenant bitte als Domain (contoso.onmicrosoft.com) oder Tenant-ID angeben.";
        else if (sp is null) error = "SharePoint-Tenantname bitte nur als Name angeben (z. B. contoso).";
        else if (pnp.Length > 0 && !Guid.TryParse(pnp, out _)) error = "Die PnP ClientId muss eine GUID sein.";

        if (error is not null)
        {
            EditorError.Text = error;
            EditorError.Visibility = Visibility.Visible;
            return;
        }

        _editing.Name = name;
        _editing.Upn = upn;
        _editing.TenantDomain = tenant.Length > 0 ? tenant : null;
        _editing.SharePointTenant = sp!.Length > 0 ? sp : null;
        _editing.PnPClientId = pnp.Length > 0 ? pnp : null;
        _editing.Color = _selectedColor;
        var scopes = Regex.Replace(ScopesBox.Text.Trim(), @"[\s,;]+", " ");
        _editing.GraphScopes = scopes.Length > 0 ? scopes : AdminProfile.DefaultGraphScopes;

        ProfileStore.Save(_editing);
        CloseEditor();
    }

    /// <summary>Akzeptiert "contoso", "contoso-admin.sharepoint.com" oder eine ganze URL. null = ungültig.</summary>
    private static string? NormalizeSharePoint(string input)
    {
        var s = input.Trim();
        if (s.Length == 0) return "";
        var m = Regex.Match(s, @"^(?:https?://)?([a-zA-Z0-9-]+?)(?:-admin|-my)?\.sharepoint\.com", RegexOptions.IgnoreCase);
        if (m.Success) return m.Groups[1].Value.ToLowerInvariant();
        return Regex.IsMatch(s, "^[a-zA-Z0-9-]+$") ? s.ToLowerInvariant() : null;
    }

    // ------------------------------------------------------------------ Umgebung

    private void RefreshEnvironment()
    {
        var busy = SetupService.IsBusy;
        var version = SetupService.PwshVersion;
        var portable = SetupService.PwshPath == SetupService.PortablePwshPath;
        var missing = SetupService.MissingModules();
        var total = SetupService.RequiredModules.Length;

        PwshText.Text = version is not null
            ? "Version " + version + (portable ? " · portabel" : " · installiert")
            : busy ? "wird geladen …" : "fehlt – wird beim Einrichten heruntergeladen";
        SetStatusIcon(PwshIcon, version is not null, busy);

        ModulesText.Text = missing.Count == 0
            ? total + " von " + total + " bereit (Graph, Exchange, Teams, PnP …)"
            : (total - missing.Count) + " von " + total + " bereit" + (busy ? " · wird installiert …" : "");
        SetStatusIcon(ModulesIcon, missing.Count == 0, busy);

        DataTitle.Text = AppPaths.IsPortable ? "Datenordner (portabel)" : "Datenordner (Benutzerprofil)";
        DataText.Text = AppPaths.DataRoot;
        DataText.ToolTip = AppPaths.DataRoot;

        SetupProgress.Visibility = busy ? Visibility.Visible : Visibility.Collapsed;
        SetupButton.IsEnabled = !busy;
        SetupButton.Content = busy ? "Wird eingerichtet …" : SetupService.IsReady ? "Nach Updates suchen" : "Einrichten";
        SetupButton.Icon = new SymbolIcon(SetupService.IsReady ? SymbolRegular.ArrowSync20 : SymbolRegular.ArrowDownload20);
    }

    private static void SetStatusIcon(SymbolIcon icon, bool ok, bool busy)
    {
        icon.Symbol = ok ? SymbolRegular.CheckmarkCircle20 : busy ? SymbolRegular.ArrowSync20 : SymbolRegular.Warning20;
        icon.SetResourceReference(ForegroundProperty,
            ok ? "SystemFillColorSuccessBrush" : busy ? "TextFillColorSecondaryBrush" : "SystemFillColorCautionBrush");
    }

    private void Setup_Click(object sender, RoutedEventArgs e)
    {
        LogExpander.IsExpanded = true;
        _ = SetupService.EnsureReadyAsync(update: SetupService.IsReady);
        RefreshEnvironment();
    }

    private void AppendLog(string line)
    {
        LogBox.AppendText(line + Environment.NewLine);
        LogBox.ScrollToEnd();
    }

    private void OpenDataFolder_Click(object sender, RoutedEventArgs e) =>
        Process.Start(new ProcessStartInfo("explorer.exe", "\"" + AppPaths.DataRoot + "\"") { UseShellExecute = true });

    // ------------------------------------------------------------------ Fenster

    protected override void OnClosing(CancelEventArgs e)
    {
        if (App.ProfileWindows.Any())
        {
            // Profilfenster laufen weiter – Startfenster nur ausblenden.
            e.Cancel = true;
            Hide();
            return;
        }
        base.OnClosing(e);
        Application.Current.Shutdown();
    }

    private static T? FindParent<T>(DependencyObject child) where T : DependencyObject
    {
        var current = child;
        while (current is not null)
        {
            if (current is T t) return t;
            current = current is Visual or System.Windows.Media.Media3D.Visual3D ? VisualTreeHelper.GetParent(current) : LogicalTreeHelper.GetParent(current);
        }
        return null;
    }
}