using System.Collections.ObjectModel;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Avalonia.Threading;
using UniversalConverter.Core;

namespace UniversalConverter.App.ViewModels;

public partial class ToolRowViewModel : ObservableObject
{
    private readonly SettingsViewModel _owner;
    public ToolFeature Feature { get; }

    [ObservableProperty] private bool _isInstalled;
    [ObservableProperty] private bool _isWorking;
    [ObservableProperty] private string _status = "";

    public ToolRowViewModel(SettingsViewModel owner, ToolFeature feature)
    {
        _owner = owner;
        Feature = feature;
        Update();
    }

    public string Title => Feature.Title;
    public string Detail => Feature.Detail;
    public string SizeText => Feature.Size;
    public bool CanInstall => !IsInstalled && !IsWorking && !_owner.IsInstalling;
    public string StatusText => IsWorking ? Status : IsInstalled ? "Installed" : "Not installed";

    public void Update()
    {
        IsInstalled = Feature.IsInstalled(_owner.Tools);
        OnPropertyChanged(nameof(CanInstall)); OnPropertyChanged(nameof(StatusText));
    }

    partial void OnIsWorkingChanged(bool value) { OnPropertyChanged(nameof(CanInstall)); OnPropertyChanged(nameof(StatusText)); }
    partial void OnStatusChanged(string value) => OnPropertyChanged(nameof(StatusText));
    partial void OnIsInstalledChanged(bool value) { OnPropertyChanged(nameof(CanInstall)); OnPropertyChanged(nameof(StatusText)); }

    [RelayCommand]
    private Task Install() => _owner.InstallAsync(this);
}

public partial class ModelRowViewModel : ObservableObject
{
    private readonly SettingsViewModel _owner;
    public CodeModel Model { get; }

    [ObservableProperty] private bool _isInstalled;
    [ObservableProperty] private bool _isSelected;
    [ObservableProperty] private bool _isWorking;

    public ModelRowViewModel(SettingsViewModel owner, CodeModel model) { _owner = owner; Model = model; Update(); }

    public string Title => Model.Title;
    public string Detail => $"{Model.Detail} {Model.Download}. Works well with {Model.MemoryGb} GB of memory or more.";
    public bool FitsThisPc => Model.FitsThisPc;
    public bool DoesNotFit => !Model.FitsThisPc;
    public bool CanDownload => !IsInstalled && !IsWorking;
    public bool CanUse => IsInstalled && !IsSelected;
    public string StatusText => IsWorking ? "Downloading…" : IsSelected ? "In use" : IsInstalled ? "Downloaded" : "Not downloaded";

    public void Update()
    {
        IsInstalled = Model.IsInstalled;
        IsSelected = CodeModels.Selected == Model.Name;
        Refresh();
    }

    private void Refresh()
    {
        OnPropertyChanged(nameof(CanDownload)); OnPropertyChanged(nameof(CanUse)); OnPropertyChanged(nameof(StatusText));
    }

    partial void OnIsInstalledChanged(bool value) => Refresh();
    partial void OnIsSelectedChanged(bool value) => Refresh();
    partial void OnIsWorkingChanged(bool value) => Refresh();

    [RelayCommand] private Task Download() => _owner.DownloadModelAsync(this);
    [RelayCommand] private void Use() => _owner.UseModel(this);
}

public partial class SettingsViewModel : ObservableObject
{
    private readonly MainViewModel _main;
    public ToolLocator Tools => _main.Tools;
    public ObservableCollection<ToolRowViewModel> ToolRows { get; } = [];
    public ObservableCollection<ModelRowViewModel> ModelRows { get; } = [];
    public static readonly string[] PageOutputTitles = ["A folder of images", "One ZIP file"];
    public static readonly string[] RepairTitles = ["Off", "One attempt"];

    [ObservableProperty] private string _outputFolder;
    [ObservableProperty] private int _pageOutputIndex;
    [ObservableProperty] private int _repairIndex;
    [ObservableProperty] private bool _isInstalling;
    [ObservableProperty] private string _message = "";

    public SettingsViewModel(MainViewModel main)
    {
        _main = main;
        _outputFolder = main.OutputFolder;
        _pageOutputIndex = AppSettings.Current.PageOutput == PageOutput.Zip ? 1 : 0;
        _repairIndex = AppSettings.Current.RepairAttempts > 0 ? 1 : 0;
        foreach (var feature in ToolFeature.All) ToolRows.Add(new ToolRowViewModel(this, feature));
        foreach (var model in CodeModels.Catalog) ModelRows.Add(new ModelRowViewModel(this, model));
    }

    public string OcrStatus => ToolLocator.OcrAvailable
        ? "Text recognition from Windows is ready. It reads the languages in Windows Settings, under Time and language."
        : "Text recognition needs Windows 10 or 11.";

    partial void OnOutputFolderChanged(string value) => _main.OutputFolder = value;

    partial void OnPageOutputIndexChanged(int value)
    {
        AppSettings.Current.PageOutput = value == 1 ? PageOutput.Zip : PageOutput.Folder;
        AppSettings.Current.Save();
    }

    partial void OnRepairIndexChanged(int value)
    {
        AppSettings.Current.RepairAttempts = value == 1 ? 1 : 0;
        AppSettings.Current.Save();
    }

    partial void OnIsInstallingChanged(bool value) { foreach (var row in ToolRows) row.Update(); }

    public void RefreshTools()
    {
        foreach (var row in ToolRows) row.Update();
        foreach (var row in ModelRows) row.Update();
        _main.RefreshAll();
    }

    public async Task InstallAsync(ToolRowViewModel row)
    {
        if (IsInstalling) return;
        IsInstalling = true;
        row.IsWorking = true;
        Message = "";
        try
        {
            await ToolInstaller.InstallAsync(row.Feature, Tools, CodeModels.Selected,
                text => Dispatcher.UIThread.Post(() => row.Status = text));
            Message = $"{row.Title} is installed.";
        }
        catch (Exception ex)
        {
            Message = ex is ConversionException ? ex.Message : $"The install did not finish. {ex.Message}";
        }
        finally
        {
            row.IsWorking = false;
            IsInstalling = false;
            RefreshTools();
        }
    }

    public async Task DownloadModelAsync(ModelRowViewModel row)
    {
        row.IsWorking = true;
        Message = "";
        try
        {
            await ToolInstaller.PullModelAsync(row.Model.Name, Tools);
            Message = $"{row.Title} is downloaded.";
        }
        catch (Exception ex)
        {
            Message = ex is ConversionException ? ex.Message : $"The download did not finish. {ex.Message}";
        }
        finally
        {
            row.IsWorking = false;
            RefreshTools();
        }
    }

    public void UseModel(ModelRowViewModel row)
    {
        AppSettings.Current.OllamaModel = row.Model.Name;
        AppSettings.Current.Save();
        RefreshTools();
    }
}
