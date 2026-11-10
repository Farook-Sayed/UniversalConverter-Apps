using System.Collections.ObjectModel;
using Avalonia.Threading;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using UniversalConverter.Core;

namespace UniversalConverter.App.ViewModels;

/// <summary>One file in the merge list, with its place in the order.</summary>
public partial class MergeFileRow(DetectedFile file) : ObservableObject
{
    public DetectedFile File { get; } = file;
    public string Name => Path.GetFileName(File.Path);
    [ObservableProperty] private int _position;
    [ObservableProperty] private bool _canMoveUp;
    [ObservableProperty] private bool _canMoveDown;
    [ObservableProperty] private bool _canRemove;
}

public enum MergePhase { Setup, Running, Finished, Failed }

/// <summary>One merge window: which files are joined, in what order, and how the merge is going. The window works on a copy of the
/// queue's files, so changing the order here never changes the queue.</summary>
public partial class MergeViewModel : ObservableObject
{
    private readonly IReadOnlyList<MergeGroup> _groups;
    private readonly string _outputFolder;
    private CancellationTokenSource? _cancel;

    public static readonly string[] PageSizeTitles = [MergePageSize.A4.Title(), MergePageSize.Letter.Title(), MergePageSize.FitPicture.Title()];

    public ObservableCollection<MergeFileRow> Files { get; } = [];
    public ObservableCollection<OutputFormat> Targets { get; } = [];
    public IReadOnlyList<string> GroupNames => _groups.Select(g => g.Name).ToList();

    [ObservableProperty] private int _groupIndex;
    [ObservableProperty] private OutputFormat? _selectedTarget;
    [ObservableProperty] private int _pageSizeIndex;
    [ObservableProperty] private string _name = "Merged";
    [ObservableProperty] private MergePhase _phase = MergePhase.Setup;
    [ObservableProperty] private string _progressMessage = "Merging…";
    [ObservableProperty] private double? _fraction;
    [ObservableProperty] private string? _resultPath;
    [ObservableProperty] private string? _errorText;
    public ObservableCollection<string> Notes { get; } = [];

    /// <summary>The running merge, so a test or the window can wait for it.</summary>
    public Task? Running { get; private set; }

    public MergeViewModel(IReadOnlyList<MergeGroup> groups, string outputFolder)
    {
        if (groups.Count == 0) throw new ArgumentException("A merge needs a group");
        _groups = groups;
        _outputFolder = outputFolder;
        Load(0);
    }

    public MergeGroup Group => _groups[Math.Clamp(GroupIndex, 0, _groups.Count - 1)];
    public bool HasSeveralGroups => _groups.Count > 1;
    public bool IsPdf => Group.Kind == MergeKind.Pdf;
    public bool IsSetup => Phase == MergePhase.Setup;
    public bool IsRunning => Phase == MergePhase.Running;
    public bool IsFinished => Phase == MergePhase.Finished;
    public bool IsFailed => Phase == MergePhase.Failed;
    public bool IsIndeterminate => Fraction is null;
    public double Percent => (Fraction ?? 0) * 100;
    public string PercentText => Fraction is double f ? f.ToString("P0") : "";
    public bool HasPercent => Fraction is not null;
    public bool HasNotes => Notes.Count > 0;
    public string Title => Group.Title;

    /// <summary>The tool the chosen merge needs, when it is not installed.</summary>
    public string? MissingTool => Group.Engine switch
    {
        Engine.Ffmpeg when !new ToolLocator().IsAvailable(Engine.Ffmpeg) => "FFmpeg",
        Engine.Pandoc when !new ToolLocator().IsAvailable(Engine.Pandoc) => "Pandoc",
        _ => null,
    };
    public bool HasMissingTool => MissingTool is not null;
    public bool CanStart => IsSetup && Files.Count >= 2 && !HasMissingTool && SelectedTarget is not null && !string.IsNullOrWhiteSpace(Name);

    partial void OnGroupIndexChanged(int value) { if (IsSetup) Load(value); }
    partial void OnPhaseChanged(MergePhase value) => Refresh();
    partial void OnNameChanged(string value) => Refresh();
    partial void OnSelectedTargetChanged(OutputFormat? value) => Refresh();
    partial void OnFractionChanged(double? value)
    {
        OnPropertyChanged(nameof(IsIndeterminate)); OnPropertyChanged(nameof(Percent));
        OnPropertyChanged(nameof(PercentText)); OnPropertyChanged(nameof(HasPercent));
    }

    private void Load(int index)
    {
        var group = _groups[Math.Clamp(index, 0, _groups.Count - 1)];
        Files.Clear();
        foreach (var file in group.Files) Files.Add(new MergeFileRow(file));
        Targets.Clear();
        foreach (var target in group.Targets) Targets.Add(target);
        SelectedTarget = MergePlanner.SuggestedTarget(group);
        Renumber();
        OnPropertyChanged(nameof(Group)); OnPropertyChanged(nameof(IsPdf)); OnPropertyChanged(nameof(Title));
        OnPropertyChanged(nameof(MissingTool)); OnPropertyChanged(nameof(HasMissingTool));
        Refresh();
    }

    private void Renumber()
    {
        for (int i = 0; i < Files.Count; i++)
        {
            var row = Files[i];
            row.Position = i + 1;
            row.CanMoveUp = IsSetup && i > 0;
            row.CanMoveDown = IsSetup && i < Files.Count - 1;
            row.CanRemove = IsSetup && Files.Count > 2;
        }
        Refresh();
    }

    private void Refresh()
    {
        foreach (var name in new[] { nameof(IsSetup), nameof(IsRunning), nameof(IsFinished), nameof(IsFailed), nameof(CanStart), nameof(HasNotes) })
            OnPropertyChanged(name);
    }

    public void MoveUp(MergeFileRow row) { int i = Files.IndexOf(row); if (i > 0 && IsSetup) { Files.Move(i, i - 1); Renumber(); } }
    public void MoveDown(MergeFileRow row) { int i = Files.IndexOf(row); if (i >= 0 && i < Files.Count - 1 && IsSetup) { Files.Move(i, i + 1); Renumber(); } }
    public void Remove(MergeFileRow row) { if (IsSetup && Files.Count > 2 && Files.Remove(row)) Renumber(); }

    [RelayCommand]
    private void Start()
    {
        if (!CanStart || SelectedTarget is null) return;
        Notes.Clear();
        ErrorText = null;
        Fraction = null;
        ProgressMessage = "Merging…";
        Phase = MergePhase.Running;
        var request = new MergeRequest(Group.Kind, Files.Select(f => f.File).ToList(), SelectedTarget, _outputFolder, Name.Trim(), (MergePageSize)Math.Clamp(PageSizeIndex, 0, 2));
        _cancel = new CancellationTokenSource();
        var token = _cancel.Token;
        var converter = new Converter(progress: update => Dispatcher.UIThread.Post(() =>
        {
            if (!IsRunning) return;
            ProgressMessage = update.Message;
            Fraction = update.Fraction;
        }));
        Running = RunAsync(converter, request, token);
    }

    private async Task RunAsync(Converter converter, MergeRequest request, CancellationToken token)
    {
        try
        {
            var result = await converter.MergeAsync(request, token);
            ResultPath = result.OutputPath;
            foreach (var note in result.Notes) Notes.Add(note);
            Phase = MergePhase.Finished;
        }
        catch (OperationCanceledException)
        {
            Phase = MergePhase.Setup;
            Renumber();
        }
        catch (Exception ex)
        {
            ErrorText = ex is ConversionException ? ex.Message : $"Something went wrong: {ex.Message}";
            Phase = MergePhase.Failed;
        }
        finally
        {
            Fraction = null;
            _cancel?.Dispose();
            _cancel = null;
            OnPropertyChanged(nameof(HasNotes));
        }
    }

    [RelayCommand]
    private void Cancel() => _cancel?.Cancel();

    /// <summary>Back to the setup, after a failure, so the user can change something and try again.</summary>
    [RelayCommand]
    private void TryAgain()
    {
        if (Phase != MergePhase.Failed) return;
        Phase = MergePhase.Setup;
        Renumber();
    }
}
