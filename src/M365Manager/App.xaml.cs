using System.Security.Cryptography;
using System.Text;
using System.Windows;
using System.Windows.Threading;
using M365Manager.Models;
using M365Manager.Services;
using M365Manager.Views;
using Microsoft.Web.WebView2.Core;
using Wpf.Ui.Appearance;
using Wpf.Ui.Controls;
using MessageBoxButton = System.Windows.MessageBoxButton;

namespace M365Manager;

public partial class App : Application
{
    private static Mutex? _instanceMutex;
    private static EventWaitHandle? _activateSignal;

    public static LauncherWindow Launcher { get; private set; } = null!;

    public static IEnumerable<MainWindow> ProfileWindows => Current.Windows.OfType<MainWindow>();

    public static bool IsDark => ApplicationThemeManager.GetAppTheme() == ApplicationTheme.Dark;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        DispatcherUnhandledException += OnUnhandledException;

        AppPaths.Initialize();
        AppDomain.CurrentDomain.UnhandledException += (_, args) => Log.Write("Absturz: " + args.ExceptionObject);
        TaskScheduler.UnobservedTaskException += (_, args) =>
        {
            Log.Write("Hintergrundfehler: " + args.Exception.GetBaseException().Message);
            args.SetObserved();
        };
        Log.Write("Start · Version " + typeof(App).Assembly.GetName().Version + " · Daten: " + AppPaths.DataRoot);

        if (!AcquireSingleInstance(e.Args))
        {
            Shutdown();
            return;
        }

        try
        {
            CoreWebView2Environment.GetAvailableBrowserVersionString();
        }
        catch (WebView2RuntimeNotFoundException)
        {
            System.Windows.MessageBox.Show(
                "Die Microsoft Edge WebView2 Runtime wurde nicht gefunden.\n\nAuf Windows 11 ist sie normalerweise vorinstalliert. " +
                "Download: https://go.microsoft.com/fwlink/p/?LinkId=2124703",
                "M365 Manager", MessageBoxButton.OK, MessageBoxImage.Error);
            Shutdown();
            return;
        }

        try { AssetExtractor.ExtractAll(); }
        catch (Exception ex) { Log.Write("Assets: " + ex.Message); }

        ApplySystemTheme();

        Launcher = new LauncherWindow();
        Launcher.Show();

        // M365Manager.exe --profile "Contoso" öffnet das Profil direkt (z. B. für Desktop-Verknüpfungen).
        if (FindProfile(ProfileArgument(e.Args)) is { } profile) OpenProfile(profile);
    }

    private static void ApplySystemTheme()
    {
        var dark = ApplicationThemeManager.GetSystemTheme() is SystemTheme.Dark or SystemTheme.Glow or SystemTheme.CapturedMotion or SystemTheme.HCBlack;
        ApplicationThemeManager.Apply(dark ? ApplicationTheme.Dark : ApplicationTheme.Light, WindowBackdropType.Mica, true);
    }

    /// <summary>Nur eine Instanz pro Datenordner. Eine zweite holt stattdessen das Startfenster nach vorne.</summary>
    private static string PendingOpenFile => System.IO.Path.Combine(AppPaths.DataRoot, ".open-request");

    private bool AcquireSingleInstance(string[] args)
    {
        var hash = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(AppPaths.DataRoot.ToLowerInvariant())))[..16];
        _instanceMutex = new Mutex(true, "M365Manager-" + hash, out var created);
        _activateSignal = new EventWaitHandle(false, EventResetMode.AutoReset, "M365Manager-activate-" + hash);

        if (!created)
        {
            var wanted = ProfileArgument(args);
            try { System.IO.File.WriteAllText(PendingOpenFile, wanted ?? ""); } catch { }
            _activateSignal.Set();
            return false;
        }

        var thread = new Thread(() =>
        {
            while (_activateSignal.WaitOne())
                Dispatcher.BeginInvoke(HandleActivationRequest);
        }) { IsBackground = true, Name = "instance-signal" };
        thread.Start();
        return true;
    }

    private static void HandleActivationRequest()
    {
        string? wanted = null;
        try
        {
            if (System.IO.File.Exists(PendingOpenFile))
            {
                wanted = System.IO.File.ReadAllText(PendingOpenFile).Trim();
                System.IO.File.Delete(PendingOpenFile);
            }
        }
        catch { }

        if (FindProfile(wanted) is { } profile) OpenProfile(profile);
        else ShowLauncher();
    }

    private static string? ProfileArgument(string[] args)
    {
        var i = Array.FindIndex(args, a => a.Equals("--profile", StringComparison.OrdinalIgnoreCase) || a.Equals("-p", StringComparison.OrdinalIgnoreCase));
        return i >= 0 && i + 1 < args.Length ? args[i + 1] : null;
    }

    private static AdminProfile? FindProfile(string? nameOrId) =>
        string.IsNullOrWhiteSpace(nameOrId) ? null :
        ProfileStore.All().FirstOrDefault(p => p.Id == nameOrId || p.Name.Equals(nameOrId, StringComparison.CurrentCultureIgnoreCase));

    public static void OpenProfile(AdminProfile profile)
    {
        var existing = ProfileWindows.FirstOrDefault(w => w.ProfileId == profile.Id);
        if (existing is not null)
        {
            if (existing.WindowState == WindowState.Minimized) existing.WindowState = WindowState.Normal;
            existing.Activate();
        }
        else
        {
            profile.LastUsed = DateTime.Now;
            ProfileStore.Save(profile);
            new MainWindow(profile).Show();
        }
        Launcher.Hide();
    }

    public static void ShowLauncher(AdminProfile? edit = null)
    {
        Launcher.Show();
        if (Launcher.WindowState == WindowState.Minimized) Launcher.WindowState = WindowState.Normal;
        Launcher.Activate();
        if (edit is not null) Launcher.StartEdit(edit);
    }

    public static void OnProfileWindowClosed(MainWindow closed)
    {
        if (!ProfileWindows.Any(w => !ReferenceEquals(w, closed)))
            ShowLauncher();
    }

    private void OnUnhandledException(object sender, DispatcherUnhandledExceptionEventArgs e)
    {
        Log.Write("Unbehandelt: " + e.Exception);
        System.Windows.MessageBox.Show(e.Exception.Message, "M365 Manager", MessageBoxButton.OK, MessageBoxImage.Warning);
        e.Handled = true;
    }
}