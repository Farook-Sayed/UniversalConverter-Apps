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
    public bool CanInstall => !IsInstalled && !IsWorking;
    public bool CanRemove => IsInstalled && !IsWorking;
    public string StatusText => IsWorking ? Status : IsInstalled ? "Installed" : "Not installed";

    public void Update()
    {
        IsInstalled = Feature.IsInstalled(_owner.Tools);
        OnPropertyChanged(nameof(CanInstall)); OnPropertyChanged(nameof(StatusText));
    }

    partial void OnIsWorkingChanged(bool value) { OnPropertyChanged(nameof(CanInstall)); OnPropertyChanged(nameof(CanRemove)); OnPropertyChanged(nameof(StatusText)); _owner.RowsChanged(); }
    partial void OnStatusChanged(string value) => OnPropertyChanged(nameof(StatusText));
    partial void OnIsInstalledChanged(bool value) { OnPropertyChanged(nameof(CanInstall)); OnPropertyChanged(nameof(CanRemove)); OnPropertyChanged(nameof(StatusText)); _owner.RowsChanged(); }

    [RelayCommand]
    private Task Install() => _owner.InstallAsync(this);

    [RelayCommand]
    private Task Remove() => _owner.RemoveAsync(this);
}

public partial class ModelRowViewModel : ObservableObject
{
    private readonly SettingsViewModel _owner;
    public CodeModel Model { get; }

    [ObservableProperty] private bool _isInstalled;
    [ObservableProperty] private bool _isSelected;
    [ObservableProperty] private bool _isWorking;
    public bool IsRemoving { get; set; }

    public ModelRowViewModel(SettingsViewModel owner, CodeModel model) { _owner = owner; Model = model; Update(); }

    public string Title => Model.Title;
    public string Detail => $"{Model.Detail} {Model.Download}. Works well with {Model.MemoryGb} GB of memory or more.";
    public bool FitsThisPc => Model.FitsThisPc;
    public bool DoesNotFit => !Model.FitsThisPc;
    public bool CanDownload => !IsInstalled && !IsWorking;
    public bool CanUse => IsInstalled && !IsSelected;
    public bool CanRemove => IsInstalled && !IsWorking;
    public string StatusText => IsWorking ? (IsRemoving ? "Removing…" : "Downloading…")
        : IsSelected && IsInstalled ? "In use"
        : IsSelected ? "Chosen, but not downloaded yet"
        : IsInstalled ? "Downloaded" : "Not downloaded";

    public void Update()
    {
        IsInstalled = Model.IsInstalled;
        IsSelected = CodeModels.Selected == Model.Name;
        Refresh();
    }

    private void Refresh()
    {
        OnPropertyChanged(nameof(CanDownload)); OnPropertyChanged(nameof(CanUse)); OnPropertyChanged(nameof(CanRemove)); OnPropertyChanged(nameof(StatusText));
    }

    partial void OnIsInstalledChanged(bool value) => Refresh();
    partial void OnIsSelectedChanged(bool value) => Refresh();
    partial void OnIsWorkingChanged(bool value) => Refresh();

    [RelayCommand] private Task Download() => _owner.DownloadModelAsync(this);
    [RelayCommand] private void Use() => _owner.UseModel(this);
    [RelayCommand] private Task Remove() => _owner.RemoveModelAsync(this);
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
    [ObservableProperty] private string _message = "";

    /// <summary>For tests: replaces the real installer, so rows can be run without installing anything.</summary>
    public Func<ToolFeature, Action<string>, CancellationToken, Task>? InstallOverride { get; set; }

    /// <summary>The tools that are not installed and not being installed right now.</summary>
    public bool CanInstallAll => ToolRows.Count(r => r.CanInstall) > 1;
    public bool AnyInstalling => ToolRows.Any(r => r.IsWorking) || ModelRows.Any(r => r.IsWorking);

    internal void RowsChanged() { OnPropertyChanged(nameof(CanInstallAll)); OnPropertyChanged(nameof(AnyInstalling)); }

    /// <summary>Results of installs that finish near each other are all kept, one per line.</summary>
    private void AddMessage(string text)
    {
        // Two installs can finish at the same moment. Without the lock, each reads the old text and one result is lost.
        lock (_messageLock) Message = string.IsNullOrEmpty(Message) ? text : Message + "\n" + text;
    }

    private readonly object _messageLock = new();

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


    public void RefreshTools()
    {
        foreach (var row in ToolRows) row.Update();
        foreach (var row in ModelRows) row.Update();
        _main.RefreshAll();
    }

    /// <summary>Installs one tool. Any number can run at once: their downloads overlap, and the Windows installers take turns.</summary>
    public async Task InstallAsync(ToolRowViewModel row)
    {
        if (row.IsWorking || row.IsInstalled) return;
        row.IsWorking = true;
        row.Status = "Starting…";
        void Step(string text) => Dispatcher.UIThread.Post(() => { if (row.IsWorking) row.Status = text; });
        try
        {
            if (InstallOverride is { } fake) await fake(row.Feature, Step, CancellationToken.None);
            else await ToolInstaller.InstallAsync(row.Feature, Tools, CodeModels.Selected, Step);
            AddMessage($"{row.Title} is installed.");
        }
        catch (Exception ex)
        {
            AddMessage(ex is ConversionException ? ex.Message : $"{row.Title} could not be installed. {ex.Message}");
        }
        finally
        {
            row.IsWorking = false;
            RefreshTools();
        }
    }

    /// <summary>Asks the user a yes or no question. The window sets this; a test sets a fake. Without it, nothing is removed.</summary>
    public Func<string, string, Task<bool>>? Confirm { get; set; }

    /// <summary>For tests: replace the plan and the removal, so nothing is uninstalled.</summary>
    public Func<ToolFeature, Task<RemovalPlan>>? PlanOverride { get; set; }
    public Func<ToolFeature, RemovalPlan, Action<string>, Task>? UninstallOverride { get; set; }
    public Func<string, Task>? RemoveModelOverride { get; set; }

    /// <summary>Removes one tool group after showing what goes and asking. A tool that winget did not install is not touched.</summary>
    public async Task RemoveAsync(ToolRowViewModel row)
    {
        if (row.IsWorking || !row.IsInstalled) return;
        row.IsWorking = true;
        row.Status = "Checking…";
        try
        {
            var plan = PlanOverride is { } fake ? await fake(row.Feature) : await ToolRemoval.PlanAsync(row.Feature, Tools);
            if (plan.IsEmpty)
            {
                AddMessage($"{row.Title} was not installed by winget, so Universal Converter cannot remove it. Remove it the way you installed it.");
                return;
            }
            if (Confirm is null || !await Confirm($"Remove {row.Title}?", plan.Confirmation)) return;
            row.Status = "Removing…";
            void Step(string text) => Dispatcher.UIThread.Post(() => { if (row.IsWorking) row.Status = text; });
            if (UninstallOverride is { } uninstall) await uninstall(row.Feature, plan, Step);
            else await ToolRemoval.UninstallAsync(row.Feature, Tools, plan, Step);
            AddMessage($"{row.Title} was removed.");
        }
        catch (Exception ex)
        {
            AddMessage(ex is ConversionException ? ex.Message : $"{row.Title} could not be removed. {ex.Message}");
        }
        finally
        {
            row.IsWorking = false;
            RefreshTools();
        }
    }

    /// <summary>Deletes one downloaded code model after asking.</summary>
    public async Task RemoveModelAsync(ModelRowViewModel row)
    {
        if (row.IsWorking || !row.IsInstalled) return;
        if (Confirm is null || !await Confirm($"Remove {row.Title}?", $"This deletes the downloaded model ({row.Model.Download}). You can download it again from here.")) return;
        row.IsRemoving = true;
        row.IsWorking = true;
        try
        {
            if (RemoveModelOverride is { } fake) await fake(row.Model.Name);
            else await ToolRemoval.RemoveModelAsync(row.Model.Name, Tools);
            AddMessage($"{row.Title} was removed.");
        }
        catch (Exception ex)
        {
            AddMessage(ex is ConversionException ? ex.Message : $"{row.Title} could not be removed. {ex.Message}");
        }
        finally
        {
            row.IsRemoving = false;
            row.IsWorking = false;
            RefreshTools();
        }
    }

    /// <summary>Starts every missing tool together.</summary>
    [RelayCommand]
    private Task InstallAll() => Task.WhenAll(ToolRows.Where(r => r.CanInstall).ToList().Select(InstallAsync));

    public async Task DownloadModelAsync(ModelRowViewModel row)
    {
        if (row.IsWorking) return;
        row.IsWorking = true;
        try
        {
            await ToolInstaller.PullModelAsync(row.Model.Name, Tools);
            AddMessage($"{row.Title} is downloaded.");
        }
        catch (Exception ex)
        {
            AddMessage(ex is ConversionException ? ex.Message : $"The download of {row.Title} did not finish. {ex.Message}");
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
