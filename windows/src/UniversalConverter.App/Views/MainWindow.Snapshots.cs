using Avalonia;
using Avalonia.Controls;
using Avalonia.Media.Imaging;
using Avalonia.Threading;
using UniversalConverter.App.ViewModels;

namespace UniversalConverter.App.Views;

/// <summary>Developer tool: saves pictures of the app's own windows, so the design can be checked without a screen
/// recording. It runs only with --snapshot FOLDER, and --demo SAMPLES for a queue with files in it.</summary>
public static class Snapshots
{
    public static async Task RunAsync(Window main, MainViewModel model, string folder)
    {
        Directory.CreateDirectory(folder);
        await Task.Delay(1500);
        Save(main, Path.Combine(folder, "empty.png"));
        await Task.Delay(400);
        Save(main, Path.Combine(folder, "queue.png"));

        var picture = model.Items.FirstOrDefault(i => i.IsImageAdjustable);
        if (picture is not null)
        {
            var edits = picture.Edits;
            edits.CompressionIndex = 4; edits.CustomSize = "500 KB"; edits.SizeIndex = 4; edits.CustomPixels = "1200";
            edits.DrawBox(new Core.FractionRect(0.2, 0.15, 0.55, 0.6));
            var adjust = new AdjustWindow(picture) { Width = 460, Height = 900 };
            adjust.Show();
            await Task.Delay(1800);
            Save(adjust, Path.Combine(folder, "adjust.png"));
            adjust.Close();
        }
        if (model.MakeMergeSession() is { } session)
        {
            var merge = new MergeWindow(session);
            merge.Show();
            await Task.Delay(1000);
            Save(merge, Path.Combine(folder, "merge.png"));
            merge.Close();
        }
        for (int tab = 0; tab < 3; tab++)
        {
            var settings = new SettingsWindow(model, tab);
            settings.Show();
            await Task.Delay(900);
            Save(settings, Path.Combine(folder, $"settings-{tab}.png"));
            settings.Close();
        }
        (Application.Current?.ApplicationLifetime as Avalonia.Controls.ApplicationLifetimes.IClassicDesktopStyleApplicationLifetime)?.Shutdown();
    }

    private static void Save(Window window, string path)
    {
        Dispatcher.UIThread.Invoke(() =>
        {
            var size = new PixelSize((int)window.Bounds.Width, (int)window.Bounds.Height);
            if (size.Width <= 0 || size.Height <= 0) return;
            using var bitmap = new RenderTargetBitmap(size, new Vector(96, 96));
            bitmap.Render(window);
            bitmap.Save(path);
        });
    }
}
