using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using UniversalConverter.Core;

namespace UniversalConverter.App.Views;

/// <summary>A picture with a box over the part to keep. The box moves when dragged, and its corners resize it.</summary>
public sealed class CropEditor : Control
{
    public static readonly StyledProperty<Bitmap?> ImageProperty = AvaloniaProperty.Register<CropEditor, Bitmap?>(nameof(Image));
    public static readonly StyledProperty<FractionRect> BoxProperty =
        AvaloniaProperty.Register<CropEditor, FractionRect>(nameof(Box), new FractionRect(0, 0, 1, 1), defaultBindingMode: Avalonia.Data.BindingMode.TwoWay);

    public Bitmap? Image { get => GetValue(ImageProperty); set => SetValue(ImageProperty, value); }
    public FractionRect Box { get => GetValue(BoxProperty); set => SetValue(BoxProperty, value); }

    /// <summary>Raised when the user moves or resizes the box.</summary>
    public event Action<FractionRect>? BoxDrawn;

    private const double Smallest = 0.05;
    private const double HandleRadius = 7;
    private enum Drag { None, Move, TopLeft, TopRight, BottomLeft, BottomRight }
    private Drag _drag;
    private Point _start;
    private FractionRect _startBox;

    static CropEditor()
    {
        AffectsRender<CropEditor>(ImageProperty, BoxProperty);
        AffectsMeasure<CropEditor>(ImageProperty);
    }

    /// <summary>The part of the view where the picture is drawn, keeping its shape.</summary>
    private Rect Shown
    {
        get
        {
            if (Image is null || Bounds.Width <= 0 || Bounds.Height <= 0) return new Rect(Bounds.Size);
            double aspect = Image.Size.Width / Image.Size.Height;
            double width = Bounds.Width, height = width / aspect;
            if (height > Bounds.Height) { height = Bounds.Height; width = height * aspect; }
            return new Rect((Bounds.Width - width) / 2, (Bounds.Height - height) / 2, width, height);
        }
    }

    private Rect BoxRect(Rect shown) => new(shown.X + Box.X * shown.Width, shown.Y + Box.Y * shown.Height, Box.Width * shown.Width, Box.Height * shown.Height);

    public override void Render(DrawingContext context)
    {
        var shown = Shown;
        context.DrawRectangle(Brushes.Transparent, null, new Rect(Bounds.Size));
        if (Image is { } image) context.DrawImage(image, new Rect(image.Size), shown);
        var box = BoxRect(shown);
        // Four bands darken the picture outside the box.
        var dim = new SolidColorBrush(Colors.Black, 0.5);
        context.DrawRectangle(dim, null, new Rect(shown.X, shown.Y, shown.Width, Math.Max(0, box.Y - shown.Y)));
        context.DrawRectangle(dim, null, new Rect(shown.X, box.Bottom, shown.Width, Math.Max(0, shown.Bottom - box.Bottom)));
        context.DrawRectangle(dim, null, new Rect(shown.X, box.Y, Math.Max(0, box.X - shown.X), box.Height));
        context.DrawRectangle(dim, null, new Rect(box.Right, box.Y, Math.Max(0, shown.Right - box.Right), box.Height));
        context.DrawRectangle(null, new Pen(Brushes.White, 1.5), box);
        foreach (var corner in new[] { box.TopLeft, box.TopRight, box.BottomLeft, box.BottomRight })
            context.DrawEllipse(Brushes.White, new Pen(new SolidColorBrush(Colors.Black, 0.4), 1), corner, HandleRadius, HandleRadius);
    }

    protected override void OnPointerPressed(PointerPressedEventArgs e)
    {
        base.OnPointerPressed(e);
        var point = e.GetPosition(this);
        var shown = Shown;
        var box = BoxRect(shown);
        _drag = Drag.None;
        // A corner handle wins over the box, because the corners sit on its edge.
        if (Near(point, box.TopLeft)) _drag = Drag.TopLeft;
        else if (Near(point, box.TopRight)) _drag = Drag.TopRight;
        else if (Near(point, box.BottomLeft)) _drag = Drag.BottomLeft;
        else if (Near(point, box.BottomRight)) _drag = Drag.BottomRight;
        else if (box.Contains(point)) _drag = Drag.Move;
        if (_drag == Drag.None) return;
        _start = point;
        _startBox = Box;
        e.Pointer.Capture(this);
        e.Handled = true;
    }

    private static bool Near(Point a, Point b) => Math.Abs(a.X - b.X) <= HandleRadius + 4 && Math.Abs(a.Y - b.Y) <= HandleRadius + 4;

    protected override void OnPointerMoved(PointerEventArgs e)
    {
        base.OnPointerMoved(e);
        var point = e.GetPosition(this);
        var shown = Shown;
        if (_drag == Drag.None)
        {
            var box = BoxRect(shown);
            Cursor = Near(point, box.TopLeft) || Near(point, box.BottomRight) ? new Cursor(StandardCursorType.TopLeftCorner)
                   : Near(point, box.TopRight) || Near(point, box.BottomLeft) ? new Cursor(StandardCursorType.TopRightCorner)
                   : box.Contains(point) ? new Cursor(StandardCursorType.SizeAll) : Cursor.Default;
            return;
        }
        if (shown.Width <= 0 || shown.Height <= 0) return;
        double dx = (point.X - _start.X) / shown.Width, dy = (point.Y - _start.Y) / shown.Height;
        var o = _startBox;
        double left = o.X, right = o.Right, top = o.Y, bottom = o.Bottom;
        switch (_drag)
        {
            case Drag.Move:
                double x = Math.Clamp(o.X + dx, 0, 1 - o.Width), y = Math.Clamp(o.Y + dy, 0, 1 - o.Height);
                Update(new FractionRect(x, y, o.Width, o.Height));
                return;
            case Drag.TopLeft or Drag.BottomLeft: left = Math.Clamp(o.X + dx, 0, right - Smallest); break;
            default: right = Math.Clamp(o.Right + dx, left + Smallest, 1); break;
        }
        if (_drag is Drag.TopLeft or Drag.TopRight) top = Math.Clamp(o.Y + dy, 0, bottom - Smallest);
        else bottom = Math.Clamp(o.Bottom + dy, top + Smallest, 1);
        Update(new FractionRect(left, top, right - left, bottom - top));
    }

    private void Update(FractionRect box)
    {
        Box = box;
        BoxDrawn?.Invoke(box);
    }

    protected override void OnPointerReleased(PointerReleasedEventArgs e)
    {
        base.OnPointerReleased(e);
        _drag = Drag.None;
        e.Pointer.Capture(null);
    }
}
