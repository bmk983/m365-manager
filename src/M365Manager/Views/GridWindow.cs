using System.Collections;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Text;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Input;
using System.Windows.Threading;
using M365Manager.Services;
using Wpf.Ui.Controls;
using Button = Wpf.Ui.Controls.Button;
using DataGrid = Wpf.Ui.Controls.DataGrid;
using TextBlock = System.Windows.Controls.TextBlock;
using TextBox = Wpf.Ui.Controls.TextBox;

namespace M365Manager.Views;

/// <summary>
/// Tabellenfenster für Out-GridView aus dem Terminal: filtern, sortieren, kopieren, als CSV speichern oder in Excel öffnen.
/// Mit -PassThru / -OutputMode wählt man Zeilen aus, die zurück in die Pipeline gehen.
/// </summary>
public sealed class GridWindow : FluentWindow
{
    private sealed class GridRow(int index, object?[] cells)
    {
        public int Index { get; } = index;
        public object?[] Cells { get; } = cells;
    }

    private readonly string[] _columns;
    private readonly List<GridRow> _rows;
    private readonly ListCollectionView _view;
    private readonly DataGrid _grid;
    private readonly TextBox _filter;
    private readonly TextBlock _count;
    private readonly string _title;
    private readonly bool _select;
    private readonly TaskCompletionSource<string> _result = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly DispatcherTimer _filterTimer;
    private string[] _filterWords = [];

    /// <param name="mode">none | wait | single | multiple</param>
    private GridWindow(string json, string mode)
    {
        using (var doc = JsonDocument.Parse(json))
        {
            var root = doc.RootElement;
            _title = root.TryGetProperty("title", out var t) ? t.GetString() ?? "" : "";
            _columns = root.GetProperty("columns").EnumerateArray().Select(c => c.GetString() ?? "").ToArray();
            _rows = root.GetProperty("rows").EnumerateArray()
                .Select((r, i) => new GridRow(i, r.EnumerateArray().Select(Value).ToArray()))
                .ToList();
        }
        _select = mode is "single" or "multiple";

        Title = "Tabelle · " + (_title.Length > 0 ? _title : "Out-GridView");
        Width = 1100;
        Height = 680;
        MinWidth = 520;
        MinHeight = 320;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        ExtendsContentIntoTitleBar = true;
        WindowBackdropType = WindowBackdropType.Mica;
        ShowInTaskbar = true;

        _view = new ListCollectionView(_rows) { Filter = Matches };

        _filter = new TextBox
        {
            PlaceholderText = "Filtern – mehrere Wörter = alle müssen vorkommen",
            Icon = new SymbolIcon(SymbolRegular.Filter20),
            MinWidth = 280,
            Margin = new Thickness(0, 0, 10, 0),
        };
        _filterTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(200) };
        _filterTimer.Tick += (_, _) => { _filterTimer.Stop(); ApplyFilter(); };
        _filter.TextChanged += (_, _) => { _filterTimer.Stop(); _filterTimer.Start(); };

        _count = new TextBlock { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(4, 0, 12, 0), Opacity = 0.75 };

        _grid = new DataGrid
        {
            ItemsSource = _view,
            AutoGenerateColumns = false,
            IsReadOnly = true,
            CanUserAddRows = false,
            CanUserDeleteRows = false,
            CanUserReorderColumns = true,
            CanUserResizeColumns = true,
            CanUserSortColumns = true,
            SelectionMode = mode == "single" ? DataGridSelectionMode.Single : DataGridSelectionMode.Extended,
            SelectionUnit = DataGridSelectionUnit.FullRow,
            HeadersVisibility = DataGridHeadersVisibility.Column,
            GridLinesVisibility = DataGridGridLinesVisibility.Horizontal,
            EnableRowVirtualization = true,
            EnableColumnVirtualization = true,
            ClipboardCopyMode = DataGridClipboardCopyMode.IncludeHeader,
            Margin = new Thickness(12, 0, 12, 0),
        };
        VirtualizingPanel.SetVirtualizationMode(_grid, VirtualizationMode.Recycling);
        for (var i = 0; i < _columns.Length; i++)
        {
            _grid.Columns.Add(new DataGridTextColumn
            {
                Header = _columns[i].Replace("_", "__"),
                Binding = new Binding("Cells[" + i + "]"),
                SortMemberPath = "Cells[" + i + "]",
                MaxWidth = 520,
            });
        }
        _grid.Sorting += OnSorting;
        if (_select) _grid.MouseDoubleClick += (_, e) =>
        {
            if (e.OriginalSource is FrameworkElement { DataContext: GridRow }) Accept();
        };

        Content = BuildLayout(mode);
        UpdateCount();

        Loaded += (_, _) => _filter.Focus();
        PreviewKeyDown += (_, e) =>
        {
            if (e.Key == Key.Escape) Close();
            else if (e.Key == Key.F && Keyboard.Modifiers == ModifierKeys.Control) { _filter.Focus(); _filter.SelectAll(); e.Handled = true; }
            else if (e.Key == Key.Enter && _select && !_filter.IsKeyboardFocusWithin) { Accept(); e.Handled = true; }
        };
        Closed += (_, _) => _result.TrySetResult("");
    }

    /// <summary>Zeigt das Fenster. Ergebnis: Indizes der ausgewählten Zeilen (kommagetrennt), sonst leer.</summary>
    public static Task<string> ShowAsync(Window? owner, string json, string mode)
    {
        var w = new GridWindow(json, mode);
        if (owner is { IsLoaded: true }) w.Owner = owner;
        w.Show();
        w.Activate();
        // Ohne -PassThru/-Wait wartet die PowerShell nicht – sie läuft sofort weiter.
        return mode is "none" ? Task.FromResult("") : w._result.Task;
    }

    private UIElement BuildLayout(string mode)
    {
        var root = new Grid();
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition());
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

        root.Children.Add(new TitleBar { Title = Title });

        var bar = new DockPanel { Margin = new Thickness(12, 4, 12, 10), LastChildFill = false };
        DockPanel.SetDock(_filter, Dock.Left);
        DockPanel.SetDock(_count, Dock.Left);
        bar.Children.Add(_filter);
        bar.Children.Add(_count);

        var excel = ToolButton("In Excel öffnen", SymbolRegular.Table20, (_, _) => OpenInExcel(), "Sichtbare Zeilen als CSV in Excel öffnen");
        var csv = ToolButton("CSV speichern …", SymbolRegular.Save20, (_, _) => SaveCsv(), "Sichtbare Zeilen als CSV speichern");
        var copy = ToolButton("Kopieren", SymbolRegular.Copy20, (_, _) => CopyRows(), "Ausgewählte (oder alle sichtbaren) Zeilen kopieren – lässt sich direkt in Excel einfügen");
        foreach (var b in new[] { excel, csv, copy })
        {
            DockPanel.SetDock(b, Dock.Right);
            bar.Children.Add(b);
        }
        Grid.SetRow(bar, 1);
        root.Children.Add(bar);

        Grid.SetRow(_grid, 2);
        root.Children.Add(_grid);

        if (_select)
        {
            var footer = new DockPanel { Margin = new Thickness(12, 10, 12, 12), LastChildFill = false };
            var cancel = new Button { Content = "Abbrechen", Margin = new Thickness(8, 0, 0, 0), MinWidth = 100 };
            cancel.Click += (_, _) => Close();
            var ok = new Button { Content = "OK – Auswahl übernehmen", Appearance = ControlAppearance.Primary, MinWidth = 160 };
            ok.Click += (_, _) => Accept();
            DockPanel.SetDock(cancel, Dock.Right);
            DockPanel.SetDock(ok, Dock.Right);
            footer.Children.Add(cancel);
            footer.Children.Add(ok);
            var hint = new TextBlock
            {
                Text = mode == "single" ? "Eine Zeile auswählen (Doppelklick = übernehmen)." : "Zeilen auswählen – Strg/Umschalt für mehrere. Die Auswahl geht zurück ins Terminal.",
                VerticalAlignment = VerticalAlignment.Center,
                Opacity = 0.75,
            };
            DockPanel.SetDock(hint, Dock.Left);
            footer.Children.Add(hint);
            Grid.SetRow(footer, 3);
            root.Children.Add(footer);
        }
        else
        {
            _grid.Margin = new Thickness(12, 0, 12, 12);
        }
        return root;
    }

    private static Button ToolButton(string text, SymbolRegular icon, RoutedEventHandler click, string tip)
    {
        var b = new Button { Content = text, Icon = new SymbolIcon(icon), Margin = new Thickness(6, 0, 0, 0), ToolTip = tip };
        b.Click += click;
        return b;
    }

    // ------------------------------------------------------------------ Filtern und Sortieren

    private void ApplyFilter()
    {
        _filterWords = (_filter.Text ?? "").Split(' ', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        _view.Refresh();
        UpdateCount();
    }

    private bool Matches(object o)
    {
        if (_filterWords.Length == 0) return true;
        var row = (GridRow)o;
        foreach (var word in _filterWords)
        {
            var found = false;
            foreach (var cell in row.Cells)
            {
                if (cell is not null && Text(cell).Contains(word, StringComparison.CurrentCultureIgnoreCase)) { found = true; break; }
            }
            if (!found) return false;
        }
        return true;
    }

    private void UpdateCount() =>
        _count.Text = _view.Count == _rows.Count
            ? _rows.Count.ToString("N0") + (_rows.Count == 1 ? " Zeile" : " Zeilen")
            : _view.Count.ToString("N0") + " von " + _rows.Count.ToString("N0") + " Zeilen";

    /// <summary>Eigene Sortierung: Zahlen numerisch, Text alphabetisch (ohne Groß-/Kleinschreibung), leere Werte ans Ende.</summary>
    private void OnSorting(object sender, DataGridSortingEventArgs e)
    {
        e.Handled = true;
        var column = e.Column;
        var index = _grid.Columns.IndexOf(column);
        var direction = column.SortDirection == System.ComponentModel.ListSortDirection.Ascending
            ? System.ComponentModel.ListSortDirection.Descending
            : System.ComponentModel.ListSortDirection.Ascending;
        foreach (var c in _grid.Columns) if (c != column) c.SortDirection = null;
        column.SortDirection = direction;
        _view.CustomSort = new RowComparer(index, direction == System.ComponentModel.ListSortDirection.Descending);
    }

    private sealed class RowComparer(int column, bool descending) : IComparer
    {
        public int Compare(object? x, object? y)
        {
            var a = ((GridRow)x!).Cells[column];
            var b = ((GridRow)y!).Cells[column];
            var aEmpty = a is null || a is string { Length: 0 };
            var bEmpty = b is null || b is string { Length: 0 };
            if (aEmpty || bEmpty) return aEmpty == bEmpty ? 0 : aEmpty ? 1 : -1;   // leer immer unten
            int r = a is double or long && b is double or long
                ? Convert.ToDouble(a).CompareTo(Convert.ToDouble(b))
                : string.Compare(Text(a), Text(b), StringComparison.CurrentCultureIgnoreCase);
            return descending ? -r : r;
        }
    }

    // ------------------------------------------------------------------ Auswahl, Kopieren, Export

    private void Accept()
    {
        var picked = _grid.SelectedItems.Cast<GridRow>().Select(r => r.Index).OrderBy(i => i).ToList();
        if (picked.Count == 0 && _grid.CurrentItem is GridRow current) picked.Add(current.Index);
        _result.TrySetResult(string.Join(",", picked));
        Close();
    }

    private IEnumerable<GridRow> VisibleRows() => _view.Cast<GridRow>();

    /// <summary>Spalten in der Reihenfolge, in der sie gerade angezeigt werden (Spalten lassen sich verschieben).</summary>
    private int[] DisplayedColumns() =>
        _grid.Columns.OrderBy(c => c.DisplayIndex).Select(c => _grid.Columns.IndexOf(c)).ToArray();

    private void CopyRows()
    {
        var rows = _grid.SelectedItems.Count > 1 ? _grid.SelectedItems.Cast<GridRow>().OrderBy(r => _view.IndexOf(r)) : VisibleRows();
        var cols = DisplayedColumns();
        var sb = new StringBuilder();
        sb.AppendLine(string.Join("\t", cols.Select(c => Clean(_columns[c]))));
        foreach (var r in rows) sb.AppendLine(string.Join("\t", cols.Select(c => Clean(Text(r.Cells[c])))));
        try { Clipboard.SetText(sb.ToString()); }
        catch (Exception ex) { Log.Write("Tabelle kopieren: " + ex.Message); }
        static string Clean(string s) => s.Replace('\t', ' ').Replace("\r", " ").Replace("\n", " ");
    }

    private string ToCsv()
    {
        // Trennzeichen wie in Excel eingestellt (Deutsch: Semikolon) – dann öffnet Excel die Datei ohne Import-Assistent.
        var sep = CultureInfo.CurrentCulture.TextInfo.ListSeparator;
        var cols = DisplayedColumns();
        string Quote(string s) => s.Contains(sep) || s.Contains('"') || s.Contains('\n') || s.Contains('\r') ? "\"" + s.Replace("\"", "\"\"") + "\"" : s;
        var sb = new StringBuilder();
        sb.AppendLine(string.Join(sep, cols.Select(c => Quote(_columns[c]))));
        foreach (var r in VisibleRows()) sb.AppendLine(string.Join(sep, cols.Select(c => Quote(Text(r.Cells[c])))));
        return sb.ToString();
    }

    private string SafeFileName()
    {
        var name = _title.Length > 0 ? _title : "Tabelle";
        name = string.Concat(name.Split(Path.GetInvalidFileNameChars())).Trim();
        if (name.Length > 60) name = name[..60].Trim();
        return name.Length > 0 ? name : "Tabelle";
    }

    private void SaveCsv()
    {
        var dialog = new Microsoft.Win32.SaveFileDialog
        {
            Filter = "CSV (Excel) (*.csv)|*.csv",
            FileName = SafeFileName() + ".csv",
            DefaultExt = ".csv",
            Title = "Als CSV speichern",
        };
        if (dialog.ShowDialog(this) != true) return;
        try { File.WriteAllText(dialog.FileName, ToCsv(), new UTF8Encoding(true)); }
        catch (Exception ex) { ShowError("Speichern fehlgeschlagen: " + ex.Message); }
    }

    private void OpenInExcel()
    {
        try
        {
            var dir = Path.Combine(Path.GetTempPath(), "M365Manager");
            Directory.CreateDirectory(dir);
            foreach (var old in Directory.EnumerateFiles(dir, "*.csv"))
                try { if (File.GetLastWriteTime(old) < DateTime.Now.AddDays(-1)) File.Delete(old); } catch { }
            var path = Path.Combine(dir, SafeFileName() + " " + DateTime.Now.ToString("yyyy-MM-dd HHmmss") + ".csv");
            File.WriteAllText(path, ToCsv(), new UTF8Encoding(true));
            Process.Start(new ProcessStartInfo(path) { UseShellExecute = true });
        }
        catch (Exception ex)
        {
            ShowError("Excel konnte nicht geöffnet werden: " + ex.Message + "\n\nTipp: „CSV speichern …“ oder „Kopieren“ und in Excel einfügen.");
        }
    }

    private async void ShowError(string text) =>
        await new Wpf.Ui.Controls.MessageBox { Title = "Tabelle", Content = text, CloseButtonText = "OK" }.ShowDialogAsync();

    // ------------------------------------------------------------------ Werte

    private static object? Value(JsonElement e) => e.ValueKind switch
    {
        JsonValueKind.Number => e.TryGetInt64(out var l) ? l : e.GetDouble(),
        JsonValueKind.String => e.GetString(),
        JsonValueKind.True => "True",
        JsonValueKind.False => "False",
        JsonValueKind.Null or JsonValueKind.Undefined => null,
        _ => e.GetRawText(),
    };

    private static string Text(object? v) => v switch
    {
        null => "",
        string s => s,
        IFormattable f => f.ToString(null, CultureInfo.CurrentCulture),
        _ => v.ToString() ?? "",
    };
}
