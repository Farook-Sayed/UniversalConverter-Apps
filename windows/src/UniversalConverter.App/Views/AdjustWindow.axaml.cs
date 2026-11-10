using Avalonia.Controls;
using Avalonia.Interactivity;
using Avalonia.Media.Imaging;
using ImageMagick;
using UniversalConverter.App.ViewModels;
using UniversalConverter.Core;

namespace UniversalConverter.App.Views;

public partial class AdjustWindow : Window
{
    private readonly ItemViewModel _item;
    private double _aspect = 1.5;
    private bool _syncing;

    public AdjustWindow() => InitializeComponent();

    public AdjustWindow(ItemViewModel item)
    {
        InitializeComponent();
        _item = item;
        DataContext = item.Edits;
        Title = $"Adjust {item.Name}";
        var lossy = item.IsLossyImageTarget;
        this.FindControl<TextBlock>("CompressionHelp")!.Text = lossy
            ? "Low keeps the most detail, and High makes the smallest file. Custom aims for the size you type."
            : $"{item.SelectedRoute?.Id.ToUpperInvariant()} keeps every detail, so Custom makes the picture smaller in pixels until it fits.";

        var editor = this.FindControl<CropEditor>("Editor")!;
        var shape = this.FindControl<ComboBox>("ShapeBox")!;
        shape.SelectedIndex = item.Edits.CropIndex;
        ShowBox();
        // The editor's box is the truth while the user drags. Choosing a shape replaces it.
        editor.BoxDrawn += box => { _syncing = true; item.Edits.DrawBox(box); shape.SelectedIndex = 0; _syncing = false; };
        shape.SelectionChanged += (_, _) =>
        {
            if (_syncing || shape.SelectedIndex < 0) return;
            _syncing = true;
            item.Edits.ChooseShape(shape.SelectedIndex);
            ShowBox();
            _syncing = false;
        };
        item.Edits.Changed += () => { if (!_syncing) { _syncing = true; shape.SelectedIndex = item.Edits.CropIndex; ShowBox(); _syncing = false; } };
        Opened += async (_, _) => await LoadPreviewAsync();
    }

    /// <summary>The box shows the chosen shape until the user draws one.</summary>
    private void ShowBox()
    {
        var edits = _item.Edits;
        var box = edits.CropRect ?? edits.Crop.FractionRect(_aspect) ?? new FractionRect(0, 0, 1, 1);
        this.FindControl<CropEditor>("Editor")!.Box = box;
    }

    private async Task LoadPreviewAsync()
    {
        var path = _item.File.Path;
        var bitmap = await Task.Run(() =>
        {
            try
            {
                using var image = ImageProcessing.Preview(path, 900);
                _aspect = (double)image.Width / Math.Max(image.Height, 1);
                using var stream = new MemoryStream(image.ToByteArray(MagickFormat.Png));
                return new Bitmap(stream);
            }
            catch { return null; }
        });
        if (bitmap is null) return;
        var editor = this.FindControl<CropEditor>("Editor")!;
        editor.Image = bitmap;
        ShowBox();
    }

    private void OnResetCrop(object? sender, RoutedEventArgs e)
    {
        _item.Edits.ResetCrop();
        this.FindControl<ComboBox>("ShapeBox")!.SelectedIndex = 0;
        ShowBox();
    }

    private void OnDone(object? sender, RoutedEventArgs e) => Close();
}
