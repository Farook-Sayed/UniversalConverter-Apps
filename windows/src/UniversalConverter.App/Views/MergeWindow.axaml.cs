using Avalonia.Controls;
using Avalonia.Interactivity;
using UniversalConverter.App.ViewModels;

namespace UniversalConverter.App.Views;

public partial class MergeWindow : Window
{
    /// <summary>Set when the user asks to open the tools window from here.</summary>
    public bool OpenToolsRequested { get; private set; }

    public MergeWindow() => InitializeComponent();

    public MergeWindow(MergeViewModel model)
    {
        InitializeComponent();
        DataContext = model;
        // A merge in progress is stopped when the window is closed, so nothing keeps running unseen.
        Closing += (_, _) => { if (model.IsRunning) model.CancelCommand.Execute(null); };
    }

    private MergeViewModel? Model => DataContext as MergeViewModel;
    private static MergeFileRow? RowOf(object? sender) => (sender as Control)?.DataContext as MergeFileRow;

    private void OnUp(object? sender, RoutedEventArgs e) { if (RowOf(sender) is { } row) Model?.MoveUp(row); }
    private void OnDown(object? sender, RoutedEventArgs e) { if (RowOf(sender) is { } row) Model?.MoveDown(row); }
    private void OnRemove(object? sender, RoutedEventArgs e) { if (RowOf(sender) is { } row) Model?.Remove(row); }
    private void OnReveal(object? sender, RoutedEventArgs e) { if (Model?.ResultPath is { } path) Shell.Reveal(path); }
    private void OnClose(object? sender, RoutedEventArgs e) => Close();
    private void OnOpenTools(object? sender, RoutedEventArgs e) { OpenToolsRequested = true; Close(); }
}
