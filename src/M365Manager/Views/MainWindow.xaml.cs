using System.Collections.ObjectModel;
using System.Diagnostics;
using System.IO;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using M365Manager.Models;
using M365Manager.Services;
using M365Manager.Terminal;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.Wpf;
using Wpf.Ui.Appearance;
using Wpf.Ui.Controls;
using Button = System.Windows.Controls.Button;
using MenuItem = System.Windows.Controls.MenuItem;
using MessageBox = Wpf.Ui.Controls.MessageBox;
using MessageBoxResult = Wpf.Ui.Controls.MessageBoxResult;
using TextBlock = System.Windows.Controls.TextBlock;

namespace M365Manager.Views;

public partial class MainWindow : FluentWindow
{
    private AdminProfile _profile;
    private readonly ObservableCollection<BrowserTab> _tabs = [];
    private readonly ObservableCollection<TerminalTab> _terminalTabs = [];
    private readonly ObservableCollection<ServiceChip> _chips = [];
    private readonly Dictionary<string, Button> _portalButtons = [];
    private BrowserTab? _activeTab;
    private TerminalTab? _activeTerminal;
    private bool _terminalVisible = true;
    private bool _terminalRight;
    private GridLength _terminalHeight = new(340);
    private GridLength _terminalWidth = new(640);
    private RowDefinition? _terminalRow;
    private ColumnDefinition? _terminalColumn;
    private int _terminalCounter;
    private bool _closed;
    private readonly TokenBroker _tokens;

    public string ProfileId => _profile.Id;

    public MainWindow(AdminProfile profile)
    {
        _profile = profile;
        _tokens = new TokenBroker(() => _profile, this);
        InitializeComponent();
        SystemThemeWatcher.Watch(this);

        BrowserTabs.ItemsSource = _tabs;
        TerminalTabs.ItemsSource = _terminalTabs;
        ServiceChips.ItemsSource = _chips;
        foreach (var name in TerminalView.ServiceNames)
            _chips.Add(new ServiceChip(name, name));

        Splitter.Style = (Style)FindResource("PaneSplitter");
        BuildPortalList();
        ApplyProfile();
        ApplyLayout();

        ProfileStore.Changed += OnProfilesChanged;
        ApplicationThemeManager.Changed += OnThemeChanged;
        PreviewKeyDown += OnPreviewKeyDown;

        Loaded += async (_, _) =>
        {
            AddTerminal();
            await OpenPortalAsync(Portal.All[0], forceNewTab: false);
        };
    }

    // ================================================================== Profil

    private void ApplyProfile()
    {
        Title = _profile.Name + " · M365 Manager";
        AppTitleBar.Title = Title;
        AvatarEllipse.Fill = _profile.ColorBrush;
        AvatarText.Text = _profile.Initials;
        ProfileNameText.Text = _profile.Name;
        ProfileUpnText.Text = _profile.Upn;
        ProfileButton.ToolTip = _profile.Subtitle;
    }

    private void OnProfilesChanged() => Dispatcher.BeginInvoke(() =>
    {
        if (_closed) return;
        if (ProfileStore.Get(_profile.Id) is { } fresh)
        {
            _profile = fresh;
            ApplyProfile();
        }
    });

    /// <summary>Werte, die die PowerShell-Sitzung ermittelt hat (SharePoint-Tenant, PnP-App), im Profil merken.</summary>
    private void OnProfileValueReported(string key, string value)
    {
        var p = ProfileStore.Get(_profile.Id) ?? _profile;
        switch (key)
        {
            case "SharePointTenant" when Regex.IsMatch(value, "^[a-zA-Z0-9-]+$"):
                p.SharePointTenant = value.ToLowerInvariant();
                break;
            case "PnPClientId" when Guid.TryParse(value, out _):
                p.PnPClientId = value;
                break;
            default:
                return;
        }
        ProfileStore.Save(p);
    }

    private void ProfileButton_Click(object sender, RoutedEventArgs e)
    {
        var menu = ProfileButton.ContextMenu!;
        menu.PlacementTarget = ProfileButton;
        menu.Placement = System.Windows.Controls.Primitives.PlacementMode.Bottom;
        menu.IsOpen = true;
    }

    private void EditProfile_Click(object sender, RoutedEventArgs e) => App.ShowLauncher(_profile);

    private void SwitchProfile_Click(object sender, RoutedEventArgs e) => App.ShowLauncher();

    private void OpenDataFolder_Click(object sender, RoutedEventArgs e) =>
        Process.Start(new ProcessStartInfo("explorer.exe", "\"" + AppPaths.DataRoot + "\"") { UseShellExecute = true });

    /// <summary>Legt eine Verknüpfung an, die direkt dieses Profil öffnet (M365Manager.exe --profile &lt;Id&gt;).</summary>
    private async void CreateShortcut_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            var desktop = Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory);
            var safeName = string.Concat(_profile.Name.Split(Path.GetInvalidFileNameChars()));
            var path = Path.Combine(desktop, "M365 - " + safeName + ".lnk");

            dynamic shell = Activator.CreateInstance(Type.GetTypeFromProgID("WScript.Shell")!)!;
            dynamic link = shell.CreateShortcut(path);
            link.TargetPath = Environment.ProcessPath;
            link.Arguments = "--profile " + _profile.Id;
            link.WorkingDirectory = AppContext.BaseDirectory;
            link.Description = "M365 Manager – " + _profile.Name;
            link.IconLocation = Environment.ProcessPath + ",0";
            link.Save();

            await new MessageBox
            {
                Title = "Verknüpfung erstellt",
                Content = "Auf dem Desktop liegt jetzt „M365 - " + safeName + "“. Ein Doppelklick öffnet direkt dieses Profil.",
                CloseButtonText = "OK",
            }.ShowDialogAsync();
        }
        catch (Exception ex)
        {
            Log.Write("Verknüpfung: " + ex);
            await new MessageBox { Title = "Fehler", Content = ex.Message, CloseButtonText = "OK" }.ShowDialogAsync();
        }
    }

    private async void ResetBrowser_Click(object sender, RoutedEventArgs e)
    {
        var result = await new MessageBox
        {
            Title = "Browser-Anmeldung zurücksetzen?",
            Content = "Alle Cookies, Anmeldungen und zwischengespeicherten Daten des integrierten Browsers für „" + _profile.Name +
                      "“ werden gelöscht. Danach meldest du dich neu an.\n\nPowerShell-Sitzungen sind nicht betroffen.",
            PrimaryButtonText = "Zurücksetzen",
            PrimaryButtonAppearance = ControlAppearance.Danger,
            CloseButtonText = "Abbrechen",
        }.ShowDialogAsync();
        if (result != MessageBoxResult.Primary) return;

        var core = _tabs.Select(t => t.View.CoreWebView2).FirstOrDefault(c => c is not null);
        if (core is null)
        {
            var tab = await CreateTabAsync(null, null);
            core = tab.View.CoreWebView2;
        }
        if (core is not null) await core.Profile.ClearBrowsingDataAsync();
        _tokens.Clear();

        foreach (var tab in _tabs.ToList()) CloseTab(tab);
        await OpenPortalAsync(Portal.All[0], forceNewTab: true);
    }

    // ================================================================== Portale

    private void BuildPortalList()
    {
        foreach (var portal in Portal.All)
        {
            var content = new StackPanel { Orientation = Orientation.Horizontal };
            content.Children.Add(new SymbolIcon { Symbol = portal.Icon, FontSize = 18 });
            content.Children.Add(new TextBlock { Text = portal.Name, Margin = new Thickness(12, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center });

            var button = new Button
            {
                Style = (Style)FindResource("NavButton"),
                Content = content,
                ToolTip = portal.Name + " öffnen  ·  Strg+Klick: in neuem Tab",
            };
            button.Click += async (_, _) => await OpenPortalAsync(portal, Keyboard.Modifiers.HasFlag(ModifierKeys.Control));
            _portalButtons[portal.Key] = button;
            PortalPanel.Children.Add(button);
        }
    }

    private async Task OpenPortalAsync(Portal portal, bool forceNewTab)
    {
        if (!forceNewTab && _tabs.FirstOrDefault(t => t.PortalKey == portal.Key) is { } existing)
        {
            SelectTab(existing);
            return;
        }
        var tab = await CreateTabAsync(portal.Url(_profile), portal.Key);
        tab.Title = portal.Name;
    }

    private void UpdatePortalHighlight()
    {
        foreach (var (key, button) in _portalButtons)
            button.Tag = _activeTab?.PortalKey == key ? "active" : null;
    }

    // ================================================================== Browser-Tabs

    private async Task<BrowserTab> CreateTabAsync(string? url, string? portalKey)
    {
        var view = new WebView2
        {
            Visibility = Visibility.Collapsed,
            DefaultBackgroundColor = System.Drawing.Color.Transparent,
        };
        var tab = new BrowserTab(view) { PortalKey = portalKey, Title = "Lädt …", Url = url ?? "" };
        _tabs.Add(tab);
        BrowserHost.Children.Add(view);
        SelectTab(tab);

        try
        {
            var env = await WebViewEnvironments.GetProfileAsync(_profile.Id);
            await view.EnsureCoreWebView2Async(env);
        }
        catch (Exception ex)
        {
            Log.Write("Browser-Tab: " + ex);
            tab.Title = "Fehler";
            return tab;
        }
        if (!_tabs.Contains(tab)) return tab;

        var core = view.CoreWebView2;
        core.Settings.IsPasswordAutosaveEnabled = false;
        await core.AddScriptToExecuteOnDocumentCreatedAsync(LoginHintScript());

        core.DocumentTitleChanged += (_, _) =>
        {
            if (!string.IsNullOrWhiteSpace(core.DocumentTitle)) tab.Title = core.DocumentTitle;
        };
        core.SourceChanged += (_, _) =>
        {
            tab.Url = core.Source;
            if (tab == _activeTab) UpdateNavState();
        };
        core.HistoryChanged += (_, _) => { if (tab == _activeTab) UpdateNavState(); };
        core.NavigationStarting += (_, _) =>
        {
            tab.IsLoading = true;
            if (tab == _activeTab) UpdateNavState();
        };
        core.NavigationCompleted += (_, _) =>
        {
            tab.IsLoading = false;
            if (tab == _activeTab) UpdateNavState();
        };
        core.FaviconChanged += async (_, _) => tab.Icon = await LoadFaviconAsync(core);
        core.NewWindowRequested += OnNewWindowRequested;
        core.WindowCloseRequested += (_, _) => CloseTab(tab);

        if (url is not null) core.Navigate(url);
        return tab;
    }

    /// <summary>
    /// Popups und "In neuem Fenster öffnen" landen als Tab in der App. Die Verbindung zum Opener bleibt erhalten,
    /// damit Popup-Anmeldungen (MSAL) funktionieren.
    /// </summary>
    private async void OnNewWindowRequested(object? sender, CoreWebView2NewWindowRequestedEventArgs e)
    {
        var deferral = e.GetDeferral();
        try
        {
            var tab = await CreateTabAsync(null, null);
            if (tab.View.CoreWebView2 is { } core) e.NewWindow = core;
            else e.Handled = true;
        }
        catch (Exception ex)
        {
            Log.Write("Neues Fenster: " + ex.Message);
            e.Handled = true;
        }
        finally
        {
            deferral.Complete();
        }
    }

    /// <summary>Füllt auf der Microsoft-Anmeldeseite den UPN des Profils vor. Kennwort und MFA bleiben beim Nutzer.</summary>
    private string LoginHintScript() =>
        """
        (() => {
          if (!/^login\.(microsoftonline\.com|microsoft\.com|windows\.net|microsoftonline\.us)$/i.test(location.hostname)) return;
          const upn = __UPN__;
          if (!upn) return;
          const fill = () => {
            const input = document.querySelector('input[name="loginfmt"]');
            if (!input || input.dataset.m365m || input.value || input.offsetParent === null) return;
            input.dataset.m365m = '1';
            const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
            setter.call(input, upn);
            input.dispatchEvent(new Event('input', { bubbles: true }));
            input.dispatchEvent(new Event('change', { bubbles: true }));
          };
          new MutationObserver(fill).observe(document, { childList: true, subtree: true });
        })();
        """.Replace("__UPN__", JsonSerializer.Serialize(_profile.Upn));

    private static async Task<ImageSource?> LoadFaviconAsync(CoreWebView2 core)
    {
        try
        {
            await using var stream = await core.GetFaviconAsync(CoreWebView2FaviconImageFormat.Png);
            if (stream is null) return null;
            var ms = new MemoryStream();
            await stream.CopyToAsync(ms);
            if (ms.Length == 0) return null;
            ms.Position = 0;
            var bmp = new BitmapImage();
            bmp.BeginInit();
            bmp.CacheOption = BitmapCacheOption.OnLoad;
            bmp.StreamSource = ms;
            bmp.EndInit();
            bmp.Freeze();
            return bmp;
        }
        catch
        {
            return null;
        }
    }

    private void SelectTab(BrowserTab tab)
    {
        foreach (var t in _tabs)
        {
            t.IsSelected = t == tab;
            t.View.Visibility = t == tab ? Visibility.Visible : Visibility.Collapsed;
        }
        _activeTab = tab;
        UpdateNavState();
        UpdatePortalHighlight();
        UpdateEmptyState();
    }

    private void CloseTab(BrowserTab tab)
    {
        var index = _tabs.IndexOf(tab);
        if (index < 0) return;
        _tabs.RemoveAt(index);
        BrowserHost.Children.Remove(tab.View);
        tab.View.Dispose();

        if (_activeTab == tab)
        {
            _activeTab = null;
            if (_tabs.Count > 0) SelectTab(_tabs[Math.Min(index, _tabs.Count - 1)]);
        }
        UpdateNavState();
        UpdatePortalHighlight();
        UpdateEmptyState();
    }

    private void UpdateEmptyState() =>
        BrowserEmpty.Visibility = _tabs.Count == 0 ? Visibility.Visible : Visibility.Collapsed;

    private void UpdateNavState()
    {
        var core = _activeTab?.View.CoreWebView2;
        BackButton.IsEnabled = core?.CanGoBack == true;
        ForwardButton.IsEnabled = core?.CanGoForward == true;
        ReloadButton.IsEnabled = core is not null;

        var loading = _activeTab?.IsLoading == true;
        LoadingBar.Visibility = loading ? Visibility.Visible : Visibility.Hidden;
        ReloadIcon.Symbol = loading ? SymbolRegular.Dismiss20 : SymbolRegular.ArrowClockwise20;

        if (!UrlBox.IsKeyboardFocusWithin)
            UrlBox.Text = _activeTab?.Url ?? "";
    }

    private void Tab_MouseDown(object sender, MouseButtonEventArgs e)
    {
        if ((sender as FrameworkElement)?.DataContext is BrowserTab tab) SelectTab(tab);
    }

    private void Tab_MouseUp(object sender, MouseButtonEventArgs e)
    {
        if (e.ChangedButton == MouseButton.Middle && (sender as FrameworkElement)?.DataContext is BrowserTab tab)
            CloseTab(tab);
    }

    private void TabClose_Click(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.DataContext is BrowserTab tab) CloseTab(tab);
    }

    private void TabScroller_PreviewMouseWheel(object sender, MouseWheelEventArgs e)
    {
        var sv = (ScrollViewer)sender;
        sv.ScrollToHorizontalOffset(sv.HorizontalOffset - e.Delta);
        e.Handled = true;
    }

    private async void NewTab_Click(object sender, RoutedEventArgs e) => await CreateTabAsync(Portal.All[0].Url(_profile), null);

    private void Back_Click(object sender, RoutedEventArgs e) => _activeTab?.View.CoreWebView2?.GoBack();

    private void Forward_Click(object sender, RoutedEventArgs e) => _activeTab?.View.CoreWebView2?.GoForward();

    private void Reload_Click(object sender, RoutedEventArgs e)
    {
        var core = _activeTab?.View.CoreWebView2;
        if (core is null) return;
        if (_activeTab!.IsLoading) core.Stop(); else core.Reload();
    }

    private void CopyUrl_Click(object sender, RoutedEventArgs e)
    {
        if (!string.IsNullOrEmpty(_activeTab?.Url)) Clipboard.SetText(_activeTab.Url);
    }

    private void UrlBox_GotFocus(object sender, KeyboardFocusChangedEventArgs e) => Dispatcher.BeginInvoke(UrlBox.SelectAll);

    private async void UrlBox_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Escape)
        {
            UrlBox.Text = _activeTab?.Url ?? "";
            _activeTab?.View.Focus();
            e.Handled = true;
            return;
        }
        if (e.Key != Key.Enter) return;
        e.Handled = true;

        var url = NormalizeUrl(UrlBox.Text);
        if (url is null) return;
        if (_activeTab?.View.CoreWebView2 is { } core)
        {
            core.Navigate(url);
            _activeTab.View.Focus();
        }
        else
        {
            await CreateTabAsync(url, null);
        }
    }

    private static string? NormalizeUrl(string input)
    {
        var text = input.Trim();
        if (text.Length == 0) return null;
        if (Uri.TryCreate(text, UriKind.Absolute, out var uri) && (uri.Scheme == Uri.UriSchemeHttps || uri.Scheme == Uri.UriSchemeHttp))
            return uri.ToString();
        if (!text.Contains(' ') && text.Contains('.'))
            return "https://" + text;
        return "https://www.bing.com/search?q=" + Uri.EscapeDataString(text);
    }

    // ================================================================== Terminal

    private void AddTerminal()
    {
        var view = new TerminalView(() => _profile, ++_terminalCounter, App.IsDark) { Visibility = Visibility.Collapsed };
        view.StatesChanged += v =>
        {
            if (_activeTerminal?.View == v) RefreshChips();
        };
        view.ProfileValueReported += OnProfileValueReported;
        view.TokenProvider = (service, extraScopes) => _tokens.GetAsync(service, extraScopes);
        TerminalHost.Children.Add(view);

        var tab = new TerminalTab(view);
        _terminalTabs.Add(tab);
        SelectTerminal(tab);
    }

    private void SelectTerminal(TerminalTab tab)
    {
        foreach (var t in _terminalTabs)
        {
            t.IsSelected = t == tab;
            t.View.Visibility = t == tab ? Visibility.Visible : Visibility.Collapsed;
        }
        _activeTerminal = tab;
        RefreshChips();
        tab.View.FocusTerminal();
    }

    private void CloseTerminal(TerminalTab tab)
    {
        if (_terminalTabs.Count == 1)
        {
            tab.View.Restart();
            return;
        }
        var index = _terminalTabs.IndexOf(tab);
        _terminalTabs.Remove(tab);
        TerminalHost.Children.Remove(tab.View);
        tab.View.Dispose();
        if (_activeTerminal == tab) SelectTerminal(_terminalTabs[Math.Min(index, _terminalTabs.Count - 1)]);
    }

    private void RefreshChips()
    {
        if (_activeTerminal is null) return;
        foreach (var chip in _chips)
        {
            var (state, detail) = _activeTerminal.View.States.TryGetValue(chip.Key, out var s) ? s : ("disconnected", null);
            chip.Update(state, detail);
        }
    }

    private void Chip_Click(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.DataContext is not ServiceChip chip || _activeTerminal is null) return;
        var terminal = _activeTerminal.View;

        if (chip.State is "connected" or "connecting")
        {
            var menu = new ContextMenu { PlacementTarget = (UIElement)sender, Placement = System.Windows.Controls.Primitives.PlacementMode.Bottom };
            var reconnect = new MenuItem { Header = "Neu verbinden", Icon = new SymbolIcon { Symbol = SymbolRegular.ArrowSync20 } };
            reconnect.Click += (_, _) => terminal.SendCommand("Connect-M365 " + chip.Key + " -Force");
            var disconnect = new MenuItem { Header = "Trennen", Icon = new SymbolIcon { Symbol = SymbolRegular.PlugDisconnected20 } };
            disconnect.Click += (_, _) => terminal.SendCommand("Disconnect-M365 " + chip.Key);
            menu.Items.Add(reconnect);
            menu.Items.Add(disconnect);
            menu.IsOpen = true;
            return;
        }

        if (!_terminalVisible) SetTerminalVisible(true);
        terminal.SendCommand("Connect-M365 " + chip.Key);
    }

    private void TerminalTab_MouseDown(object sender, MouseButtonEventArgs e)
    {
        if ((sender as FrameworkElement)?.DataContext is TerminalTab tab) SelectTerminal(tab);
    }

    private void TerminalClose_Click(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.DataContext is TerminalTab tab) CloseTerminal(tab);
    }

    private void NewTerminal_Click(object sender, RoutedEventArgs e) => AddTerminal();

    private void RestartTerminal_Click(object sender, RoutedEventArgs e) => _activeTerminal?.View.Restart();

    private void OnThemeChanged(ApplicationTheme theme, Color accent)
    {
        foreach (var t in _terminalTabs) t.View.SetTheme(theme == ApplicationTheme.Dark);
    }

    // ================================================================== Layout

    private void ToggleTerminal_Click(object sender, RoutedEventArgs e) => SetTerminalVisible(!_terminalVisible);

    private void ToggleLayout_Click(object sender, RoutedEventArgs e)
    {
        _terminalRight = !_terminalRight;
        ApplyLayout();
    }

    private void SetTerminalVisible(bool visible)
    {
        _terminalVisible = visible;
        ApplyLayout();
        if (visible) _activeTerminal?.View.FocusTerminal();
        else _activeTab?.View.Focus();
    }

    private void ApplyLayout()
    {
        if (_terminalRow is not null) _terminalHeight = _terminalRow.Height;
        if (_terminalColumn is not null) _terminalWidth = _terminalColumn.Width;
        _terminalRow = null;
        _terminalColumn = null;

        WorkArea.RowDefinitions.Clear();
        WorkArea.ColumnDefinitions.Clear();
        foreach (UIElement el in new UIElement[] { BrowserPane, Splitter, TerminalPane })
        {
            Grid.SetRow(el, 0);
            Grid.SetColumn(el, 0);
        }

        ToggleTerminalText.Text = _terminalVisible ? "Terminal ausblenden" : "Terminal einblenden";
        Splitter.Visibility = TerminalPane.Visibility = _terminalVisible ? Visibility.Visible : Visibility.Collapsed;
        if (!_terminalVisible) return;

        if (_terminalRight)
        {
            WorkArea.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star), MinWidth = 360 });
            WorkArea.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(7) });
            _terminalColumn = new ColumnDefinition { Width = _terminalWidth, MinWidth = 300 };
            WorkArea.ColumnDefinitions.Add(_terminalColumn);
            Grid.SetColumn(Splitter, 1);
            Grid.SetColumn(TerminalPane, 2);
            Splitter.ResizeDirection = GridResizeDirection.Columns;
            Splitter.Cursor = Cursors.SizeWE;
            TerminalHeader.BorderThickness = new Thickness(0);
            LayoutIcon.Symbol = SymbolRegular.PanelBottom20;
        }
        else
        {
            WorkArea.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star), MinHeight = 200 });
            WorkArea.RowDefinitions.Add(new RowDefinition { Height = new GridLength(7) });
            _terminalRow = new RowDefinition { Height = _terminalHeight, MinHeight = 140 };
            WorkArea.RowDefinitions.Add(_terminalRow);
            Grid.SetRow(Splitter, 1);
            Grid.SetRow(TerminalPane, 2);
            Splitter.ResizeDirection = GridResizeDirection.Rows;
            Splitter.Cursor = Cursors.SizeNS;
            TerminalHeader.BorderThickness = new Thickness(0);
            LayoutIcon.Symbol = SymbolRegular.PanelRight20;
        }
    }

    // ================================================================== Tastatur

    private async void OnPreviewKeyDown(object sender, KeyEventArgs e)
    {
        var key = e.Key == Key.System ? e.SystemKey : e.Key;
        var mods = Keyboard.Modifiers;

        // Strg+Ö (DE) bzw. Strg+` (US) – gleiche Taste.
        if (mods == ModifierKeys.Control && key == Key.Oem3)
        {
            e.Handled = true;
            SetTerminalVisible(!_terminalVisible || !TerminalPane.IsKeyboardFocusWithin);
            return;
        }

        // Im Terminal gehören alle anderen Tasten der Shell (Strg+W, Strg+L …).
        if (TerminalPane.IsKeyboardFocusWithin) return;

        if (mods == ModifierKeys.Control && key == Key.T)
        {
            e.Handled = true;
            await CreateTabAsync(Portal.All[0].Url(_profile), null);
        }
        else if (mods == ModifierKeys.Control && key == Key.W)
        {
            e.Handled = true;
            if (_activeTab is not null) CloseTab(_activeTab);
        }
        else if (mods == ModifierKeys.Control && key == Key.L)
        {
            e.Handled = true;
            UrlBox.Focus();
            UrlBox.SelectAll();
        }
        else if (key == Key.Tab && (mods == ModifierKeys.Control || mods == (ModifierKeys.Control | ModifierKeys.Shift)) && _tabs.Count > 1)
        {
            e.Handled = true;
            var step = mods.HasFlag(ModifierKeys.Shift) ? -1 : 1;
            var index = (_tabs.IndexOf(_activeTab!) + step + _tabs.Count) % _tabs.Count;
            SelectTab(_tabs[index]);
        }
        else if (key == Key.F5 && !UrlBox.IsKeyboardFocusWithin)
        {
            e.Handled = true;
            _activeTab?.View.CoreWebView2?.Reload();
        }
    }

    // ================================================================== Schließen

    protected override void OnClosed(EventArgs e)
    {
        _closed = true;
        ProfileStore.Changed -= OnProfilesChanged;
        ApplicationThemeManager.Changed -= OnThemeChanged;

        foreach (var t in _terminalTabs) t.View.Dispose();
        foreach (var t in _tabs) t.View.Dispose();

        base.OnClosed(e);
        App.OnProfileWindowClosed(this);
    }
}