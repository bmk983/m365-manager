using System.Windows;
using M365Manager.Models;
using Microsoft.Web.WebView2.Wpf;
using Wpf.Ui.Controls;

namespace M365Manager.Views;

/// <summary>Kleines Anmeldefenster für Token-Anfragen, nutzt den Browser-Speicher des Profils.</summary>
public sealed class AuthWindow : FluentWindow
{
    public WebView2 Browser { get; } = new() { DefaultBackgroundColor = System.Drawing.Color.White };

    public AuthWindow(string service, AdminProfile profile)
    {
        Title = "Anmeldung · " + service + " · " + profile.Name;
        Width = 520;
        Height = 700;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        ExtendsContentIntoTitleBar = true;
        WindowBackdropType = WindowBackdropType.Mica;
        ShowInTaskbar = true;

        var grid = new System.Windows.Controls.Grid();
        grid.RowDefinitions.Add(new System.Windows.Controls.RowDefinition { Height = GridLength.Auto });
        grid.RowDefinitions.Add(new System.Windows.Controls.RowDefinition());
        grid.Children.Add(new TitleBar { Title = Title });
        System.Windows.Controls.Grid.SetRow(Browser, 1);
        grid.Children.Add(Browser);
        Content = grid;
    }

    protected override void OnClosed(EventArgs e)
    {
        Browser.Dispose();
        base.OnClosed(e);
    }
}