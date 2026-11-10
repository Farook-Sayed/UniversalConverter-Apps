using Avalonia;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Markup.Xaml;
using UniversalConverter.App.Views;
using UniversalConverter.App.ViewModels;

namespace UniversalConverter.App;

public partial class App : Application
{
    public override void Initialize() => AvaloniaXamlLoader.Load(this);

    public override void OnFrameworkInitializationCompleted()
    {
        if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop)
        {
            var model = new MainViewModel();
            desktop.MainWindow = new MainWindow { DataContext = model };
            var args = (desktop.Args ?? []).ToList();
            // --demo FOLDER and --snapshot FOLDER are developer options. Anything else is a file to add.
            string? Option(string name) { int i = args.IndexOf(name); if (i < 0) return null; var v = i + 1 < args.Count ? args[i + 1] : null; args.RemoveRange(i, v is null ? 1 : 2); return v; }
            var demo = Option("--demo");
            var snapshot = Option("--snapshot");
            // Files given on the command line, or sent with "Open with", are added to the queue at start-up.
            var files = args.Where(a => !a.StartsWith("--")).ToList();
            if (files.Count > 0) _ = model.AddFilesAsync(files);
            if (demo is not null) model.LoadDemo(demo);
            if (snapshot is not null) _ = Snapshots.RunAsync(desktop.MainWindow, model, snapshot);
        }
        base.OnFrameworkInitializationCompleted();
    }
}
