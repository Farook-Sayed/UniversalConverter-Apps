using Avalonia.Controls;
using Avalonia.Interactivity;
using Avalonia.Platform.Storage;
using UniversalConverter.App.ViewModels;

namespace UniversalConverter.App.Views;

public partial class SettingsWindow : Window
{
    public SettingsWindow() => InitializeComponent();

    public SettingsWindow(MainViewModel main, int tab = 0)
    {
        InitializeComponent();
        var model = new SettingsViewModel(main);
        // Removing deletes files, so the window asks first.
        model.Confirm = (title, message) => ConfirmWindow.AskAsync(this, title, message, "Remove and delete files", "Keep it");
        DataContext = model;
        this.FindControl<TabControl>("Tabs")!.SelectedIndex = tab;
    }

    public void SelectTab(int index) => this.FindControl<TabControl>("Tabs")!.SelectedIndex = index;

    private async void OnChooseFolder(object? sender, RoutedEventArgs e)
    {
        var folders = await StorageProvider.OpenFolderPickerAsync(new FolderPickerOpenOptions { Title = "Choose where to save results" });
        if (folders.Count > 0 && folders[0].TryGetLocalPath() is { } path && DataContext is SettingsViewModel model) model.OutputFolder = path;
    }

    private void OnRecheck(object? sender, RoutedEventArgs e) => (DataContext as SettingsViewModel)?.RefreshTools();
    private void OnClose(object? sender, RoutedEventArgs e) => Close();
}
