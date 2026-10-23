using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;

namespace M365Manager.Views;

/// <summary>
/// Tabs einer horizontalen ItemsControl per Ziehen umsortieren (wie im Browser).
/// Die Maus wird an der Leiste selbst gefangen, damit das Verschieben der Einträge den Zug nicht abbricht.
/// </summary>
internal sealed class TabDragReorder
{
    private readonly ItemsControl _host;
    private readonly Action<int, int> _move;
    private object? _item;
    private Point _start;
    private bool _dragging;

    private TabDragReorder(ItemsControl host, Action<int, int> move)
    {
        _host = host;
        _move = move;
        host.PreviewMouseLeftButtonDown += OnDown;
        host.PreviewMouseMove += OnMove;
        host.PreviewMouseLeftButtonUp += (_, e) => { if (_dragging) e.Handled = true; End(); };
        host.LostMouseCapture += (_, _) => End();
    }

    public static void Attach(ItemsControl host, Action<int, int> move) => _ = new TabDragReorder(host, move);

    private void OnDown(object sender, MouseButtonEventArgs e)
    {
        _item = null;
        // Klicks auf den Schließen-Knopf nicht als Zug werten.
        for (var d = e.OriginalSource as DependencyObject; d is not null && d != _host; d = VisualTreeHelper.GetParent(d))
            if (d is ButtonBase) return;

        if (e.OriginalSource is not DependencyObject source || ItemsControl.ContainerFromElement(_host, source) is not { } container) return;
        _item = _host.ItemContainerGenerator.ItemFromContainer(container);
        _start = e.GetPosition(_host);
    }

    private void OnMove(object sender, MouseEventArgs e)
    {
        if (_item is null || e.LeftButton != MouseButtonState.Pressed) return;
        var pos = e.GetPosition(_host);

        if (!_dragging)
        {
            if (Math.Abs(pos.X - _start.X) < SystemParameters.MinimumHorizontalDragDistance) return;
            _dragging = true;
            _host.CaptureMouse();
            Mouse.OverrideCursor = Cursors.SizeWE;
        }

        var from = _host.Items.IndexOf(_item);
        if (from < 0) { End(); return; }

        // Zielposition = Anzahl der anderen Tabs, deren Mitte links vom Mauszeiger liegt.
        var target = 0;
        for (var i = 0; i < _host.Items.Count; i++)
        {
            if (i == from || _host.ItemContainerGenerator.ContainerFromIndex(i) is not FrameworkElement c) continue;
            if (pos.X > c.TranslatePoint(new Point(c.ActualWidth / 2, 0), _host).X) target++;
        }

        if (target != from)
        {
            _move(from, target);
            (_host.ItemContainerGenerator.ContainerFromIndex(target) as FrameworkElement)?.BringIntoView();
        }
    }

    private void End()
    {
        _item = null;
        if (!_dragging) return;
        _dragging = false;
        Mouse.OverrideCursor = null;
        if (_host.IsMouseCaptured) _host.ReleaseMouseCapture();
    }
}
