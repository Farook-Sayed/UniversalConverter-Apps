using System.Collections.ObjectModel;
using Avalonia.Threading;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using UniversalConverter.Core;

namespace UniversalConverter.App.ViewModels;

public partial class MainViewModel : ObservableObject
{
    /// <summary>How many conversions run at once. It follows this PC's processor cores.</summary>
    private readonly SemaphoreSlim _gate = new(ResourcePlan.ParallelConversions());
    private readonly FileDetector _detector = new();

    public ToolLocator Tools { get; } = new();
    public ObservableCollection<ItemViewModel> Items { get; } = [];

    [ObservableProperty] private string _outputFolder = AppSettings.Current.OutputFolder;

    /// <summary>What the files in the queue could be merged into. Empty until two files of the same kind are in the queue.</summary>
    public IReadOnlyList<MergeGroup> MergeGroups => MergePlanner.GroupsFor(Items.Where(i => i.IsOpenForMerge).Select(i => i.EffectiveFile));
    public bool CanMerge => MergeGroups.Count > 0;

    /// <summary>A merge window for the files in the queue, or null when nothing can be merged.</summary>
    public MergeViewModel? MakeMergeSession()
    {
        var groups = MergeGroups;
        return groups.Count == 0 ? null : new MergeViewModel(groups, OutputFolder);
    }

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

    /// <summary>Passwords typed during this session, tried on every PDF that is added. They are kept in memory only.</summary>
    private readonly List<string> _typedPasswords = [];

    /// <summary>Raised when a PDF needs a password, so the window can ask for it.</summary>
    public event Action? PasswordNeeded;

    public int LockedCount => Items.Count(i => i.NeedsPassword);

    /// <summary>Opens a PDF that was just added, off the UI thread, because a large PDF takes a while.</summary>
    private async Task OpenPdfAsync(ItemViewModel item)
    {
        var tried = _typedPasswords.ToList();
        PdfOpened opened;
        while (true)
        {
            var passwords = tried;
            opened = await Task.Run(() => PdfUnlocker.Open(item.File.Path, passwords));
            // A password typed for another file while this one was being checked may fit this one too.
            if (opened is not PdfOpened.NeedsPassword || _typedPasswords.Count <= tried.Count) break;
            tried = _typedPasswords.ToList();
        }
        if (!Items.Contains(item))
        {
            if (opened is PdfOpened.Unlocked gone) try { Directory.Delete(Path.GetDirectoryName(gone.Copy)!, true); } catch { }
            return;
        }
        item.SetOpened(opened);
        if (opened is PdfOpened.NeedsPassword) PasswordNeeded?.Invoke();
    }

    /// <summary>Tries one password on every PDF that is waiting for one. Files it does not open stay locked.</summary>
    public async Task<(int Opened, int Waiting)> UnlockPdfsAsync(string password)
    {
        var waiting = Items.Where(i => i.NeedsPassword).ToList();
        var results = await Task.Run(() => waiting.Select(i => (Item: i, Result: PdfUnlocker.Open(i.File.Path, password))).ToList());
        int opened = 0;
        foreach (var (item, result) in results)
        {
            if (result is null) continue;
            if (!Items.Contains(item)) { try { Directory.Delete(Path.GetDirectoryName(result.Copy)!, true); } catch { } continue; }
            item.SetOpened(result);
            opened++;
        }
        if (opened > 0 && !_typedPasswords.Contains(password)) _typedPasswords.Add(password);
        return (opened, waiting.Count);
    }

    /// <summary>Saves a copy of an opened PDF without its password, in the folder for results.</summary>
    public string? SaveUnlockedCopy(ItemViewModel item)
    {
        if (item.UnlockedPath is not { } copy) return null;
        Directory.CreateDirectory(OutputFolder);
        var stem = Path.GetFileNameWithoutExtension(item.File.Path) + " (unlocked)";
        var destination = OutputNaming.UniquePath(stem, "pdf", OutputFolder);
        File.Copy(copy, destination);
        return destination;
    }

    /// <summary>Removes every unlocked copy. Called when the app closes, so no decrypted file stays on disk.</summary>
    public void DiscardAllCopies()
    {
        foreach (var item in Items) item.DiscardCopy();
    }

    public MainViewModel()
    {
        Items.CollectionChanged += (_, _) => NotifyQueueChanged();
    }

    public void NotifyQueueChanged()
    {
        OnPropertyChanged(nameof(HasItems)); OnPropertyChanged(nameof(HasNoItems));
        OnPropertyChanged(nameof(CanConvertAll)); OnPropertyChanged(nameof(AnyBusy)); OnPropertyChanged(nameof(QueueSummary));
        OnPropertyChanged(nameof(CanMerge));
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
            var item = new ItemViewModel(this, detected);
            Items.Add(item);
            if (item.Lock == PdfLock.Checking) _ = OpenPdfAsync(item);
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
        item.DiscardCopy();
    }

    [RelayCommand]
    private void ClearFinished()
    {
        foreach (var item in Items.Where(i => i.IsFinished).ToList()) { Items.Remove(item); item.DiscardCopy(); }
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
