using System.Collections.ObjectModel;
using Avalonia.Threading;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using UniversalConverter.Core;

namespace UniversalConverter.App.ViewModels;

public partial class MainViewModel : ObservableObject
{
    private readonly SemaphoreSlim _gate = new(2);
    private readonly FileDetector _detector = new();

    public ToolLocator Tools { get; } = new();
    public ObservableCollection<ItemViewModel> Items { get; } = [];

    [ObservableProperty] private string _outputFolder = AppSettings.Current.OutputFolder;

    public bool HasItems => Items.Count > 0;
    public bool HasNoItems => Items.Count == 0;
    public bool CanConvertAll => Items.Any(i => i.IsReady && i.CanConvert || i.IsFailed && i.CanConvert);
    public bool AnyBusy => Items.Any(i => i.IsBusy);
    public string QueueSummary
    {
        get
        {
            int done = Items.Count(i => i.IsFinished), busy = Items.Count(i => i.IsBusy), failed = Items.Count(i => i.IsFailed);
            if (Items.Count == 0) return "";
            var parts = new List<string> { Items.Count == 1 ? "1 file" : $"{Items.Count} files" };
            if (busy > 0) parts.Add($"{busy} converting");
            if (done > 0) parts.Add($"{done} done");
            if (failed > 0) parts.Add($"{failed} failed");
            return string.Join(" · ", parts);
        }
    }

    public MainViewModel()
    {
        Items.CollectionChanged += (_, _) => NotifyQueueChanged();
    }

    public void NotifyQueueChanged()
    {
        OnPropertyChanged(nameof(HasItems)); OnPropertyChanged(nameof(HasNoItems));
        OnPropertyChanged(nameof(CanConvertAll)); OnPropertyChanged(nameof(AnyBusy)); OnPropertyChanged(nameof(QueueSummary));
    }

    partial void OnOutputFolderChanged(string value)
    {
        AppSettings.Current.OutputFolder = value;
        AppSettings.Current.Save();
        RefreshAll();
    }

    /// <summary>Checks every file again, for example after a tool was installed or the output folder changed.</summary>
    public void RefreshAll()
    {
        foreach (var item in Items.ToList()) item.Refresh();
    }

    /// <summary>Adds files, and the files directly inside any folder, to the queue.</summary>
    public async Task AddFilesAsync(IEnumerable<string> paths)
    {
        var files = new List<string>();
        foreach (var path in paths)
        {
            if (Directory.Exists(path)) files.AddRange(Directory.GetFiles(path).Order());
            else if (File.Exists(path)) files.Add(path);
        }
        foreach (var path in files)
        {
            if (Items.Any(i => string.Equals(i.File.Path, path, StringComparison.OrdinalIgnoreCase))) continue;
            DetectedFile? detected;
            try { detected = await Task.Run(() => _detector.Detect(path)); }
            catch { continue; }
            Items.Add(new ItemViewModel(this, detected));
        }
    }

    [RelayCommand]
    private void ConvertAll()
    {
        foreach (var item in Items.ToList())
            if ((item.IsReady || item.IsFailed) && item.CanConvert) Start(item);
    }

    public void Start(ItemViewModel item)
    {
        if (!item.CanConvert) return;
        var settings = AppSettings.Current;
        var converter = new Converter(Tools, new OllamaClient(model: CodeModels.Selected), settings.RepairAttempts, settings.PageOutput,
            update => Dispatcher.UIThread.Post(() => item.SetProgress(update)));
        _ = item.RunAsync(_gate, converter, OutputFolder);
    }

    public void Remove(ItemViewModel item)
    {
        item.Cancel();
        Items.Remove(item);
    }

    [RelayCommand]
    private void ClearFinished()
    {
        foreach (var item in Items.Where(i => i.IsFinished).ToList()) Items.Remove(item);
    }

    public void CancelAll()
    {
        foreach (var item in Items) item.Cancel();
    }

    /// <summary>Fills the queue with the sample files for pictures of the app. Used only with --demo.</summary>
    public void LoadDemo(string? folder)
    {
        if (folder is null || !Directory.Exists(folder)) return;
        var paths = new[] { "video/sample.mp4", "images/sample.png", "documents/sample.pdf", "audio/sample.mp3", "code/hello.py", "archives/sample.zip", "video/silent.mp4" }
            .Select(p => Path.Combine(folder, p)).Where(File.Exists).ToList();
        foreach (var path in paths) Items.Add(new ItemViewModel(this, _detector.Detect(path)));
        if (Items.Count > 0) Items[0].ShowDemo(ItemPhase.Converting, 0.45);
        if (Items.Count > 2) Items[2].ShowDemo(ItemPhase.Finished, path: Path.Combine(OutputFolder, "sample.txt"));
        if (Items.Count > 6) Items[6].ShowDemo(ItemPhase.Failed, error: "silent.mp4 has no sound track, so there is no audio to save.");
    }
}
