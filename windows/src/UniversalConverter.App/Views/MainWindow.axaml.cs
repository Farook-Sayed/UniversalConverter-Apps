using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Interactivity;
using Avalonia.Platform.Storage;
using UniversalConverter.App.ViewModels;

namespace UniversalConverter.App.Views;

public partial class MainWindow : Window
{
    public MainWindow()
    {
        InitializeComponent();
        AddHandler(DragDrop.DragOverEvent, (_, e) => e.DragEffects = e.DataTransfer.Contains(DataFormat.File) ? DragDropEffects.Copy : DragDropEffects.None);
        AddHandler(DragDrop.DropEvent, OnDrop);
        Closing += OnClosing;
    }

    private bool _confirmedClose;

    /// <summary>Closing while files are being converted would lose that work, so the user is asked first.</summary>
    private async void OnClosing(object? sender, WindowClosingEventArgs e)
    {
        if (_confirmedClose || Model is not { AnyBusy: true } model)
        {
            Model?.CancelAll();
            return;
        }
        e.Cancel = true;
        if (await ConfirmWindow.AskAsync(this, "Stop converting?",
                "Files are still being converted. If you quit now, those conversions are stopped and nothing is saved for them.",
                "Stop and quit", "Keep converting"))
        {
            _confirmedClose = true;
            model.CancelAll();
            Close();
        }
    }

    private MainViewModel? Model => DataContext as MainViewModel;
    private static ItemViewModel? ItemOf(object? sender) => (sender as Control)?.DataContext as ItemViewModel;

    private async void OnDrop(object? sender, DragEventArgs e)
    {
        var paths = e.DataTransfer.TryGetFiles()?.Select(f => f.TryGetLocalPath()).Where(p => p is not null).Select(p => p!).ToList();
        if (paths is { Count: > 0 } && Model is { } model) await model.AddFilesAsync(paths);
    }

    private async void OnAddFiles(object? sender, RoutedEventArgs e)
    {
        var files = await StorageProvider.OpenFilePickerAsync(new FilePickerOpenOptions { Title = "Choose files to convert", AllowMultiple = true });
        if (Model is { } model && files.Count > 0)
            await model.AddFilesAsync(files.Select(f => f.TryGetLocalPath()).Where(p => p is not null).Select(p => p!));
    }

    private async void OnChooseFolder(object? sender, RoutedEventArgs e)
    {
        var folders = await StorageProvider.OpenFolderPickerAsync(new FolderPickerOpenOptions { Title = "Choose where to save results", AllowMultiple = false });
        if (folders.Count > 0 && folders[0].TryGetLocalPath() is { } path && Model is { } model) model.OutputFolder = path;
    }

    private void OnOpenFolder(object? sender, RoutedEventArgs e) { if (Model is { } m) Shell.OpenFolder(m.OutputFolder); }
    private void OnConvert(object? sender, RoutedEventArgs e) { if (ItemOf(sender) is { } item) Model?.Start(item); }
    private void OnCancel(object? sender, RoutedEventArgs e) => ItemOf(sender)?.Cancel();
    private void OnRemove(object? sender, RoutedEventArgs e) { if (ItemOf(sender) is { } item) Model?.Remove(item); }
    private void OnReveal(object? sender, RoutedEventArgs e) { if (ItemOf(sender)?.OutputPath is { } path) Shell.Reveal(path); }

    private async void OnAdjust(object? sender, RoutedEventArgs e)
    {
        if (ItemOf(sender) is { } item) await new AdjustWindow(item).ShowDialog(this);
    }

    private async void OnMerge(object? sender, RoutedEventArgs e)
    {
        if (Model?.MakeMergeSession() is not { } session) return;
        var window = new MergeWindow(session);
        await window.ShowDialog(this);
        if (window.OpenToolsRequested) await ShowSettings(2);
    }

    private async void OnOpenSettings(object? sender, RoutedEventArgs e) => await ShowSettings(0);
    private async void OnOpenTools(object? sender, RoutedEventArgs e) => await ShowSettings(2);

    private async Task ShowSettings(int tab)
    {
        if (Model is not { } model) return;
        var window = new SettingsWindow(model, tab);
        await window.ShowDialog(this);
        model.RefreshAll();
    }
}
