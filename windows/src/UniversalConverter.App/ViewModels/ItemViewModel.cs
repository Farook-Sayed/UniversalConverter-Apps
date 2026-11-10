using System.Collections.ObjectModel;
using Avalonia.Media;
using CommunityToolkit.Mvvm.ComponentModel;
using UniversalConverter.Core;

namespace UniversalConverter.App.ViewModels;

public enum ItemPhase { Ready, Converting, Finished, Failed }

public sealed record FindingRow(string Message, IBrush Brush);

/// <summary>One file in the queue: what it is, what it can become, and how its conversion is going.</summary>
public partial class ItemViewModel : ObservableObject
{
    private readonly MainViewModel _owner;
    private CancellationTokenSource? _cancel;

    public Guid Id { get; } = Guid.NewGuid();
    public DetectedFile File { get; }
    public IReadOnlyList<Route> Routes { get; }
    public ImageEditsViewModel Edits { get; } = new();
    public ObservableCollection<FindingRow> Findings { get; } = [];
    public ObservableCollection<string> Notes { get; } = [];
    public static readonly string[] PdfPresetTitles = ["Original", "Low", "Medium", "High", "Custom size"];

    [ObservableProperty] private Route? _selectedRoute;
    [ObservableProperty] private ItemPhase _phase = ItemPhase.Ready;
    [ObservableProperty] private string _progressMessage = "Converting…";
    [ObservableProperty] private double? _fraction;
    [ObservableProperty] private string? _outputPath;
    [ObservableProperty] private string? _errorText;
    [ObservableProperty] private string? _validationText;
    [ObservableProperty] private string _logText = "";
    [ObservableProperty] private int _pdfPresetIndex = 2;
    [ObservableProperty] private string _pdfCustomSize = "";
    [ObservableProperty] private bool _settingsChangedSinceConverting;

    public ItemViewModel(MainViewModel owner, DetectedFile file)
    {
        _owner = owner;
        File = file;
        Routes = FormatCatalog.TargetsFor(file);
        _selectedRoute = Routes.FirstOrDefault();
        Edits.Changed += () => { SettingsChangedSinceConverting = Phase is ItemPhase.Finished; Refresh(); };
        Refresh();
    }

    public string Name => Path.GetFileName(File.Path);
    public string Subtitle
    {
        get
        {
            var kind = FormatCatalog.DisplayName(File.FormatId) ?? (File.FormatId == "unknown" ? "Unknown format" : File.FormatId.ToUpperInvariant());
            return $"{kind} · {FileSize.Text(Preflight.SizeOf(File.Path))}";
        }
    }

    public string Glyph => File.Category switch
    {
        MediaCategory.Video => "🎞", MediaCategory.Audio => "🎵", MediaCategory.Image or MediaCategory.Vector => "🖼",
        MediaCategory.Document => "📄", MediaCategory.Spreadsheet => "📊", MediaCategory.Presentation => "📽",
        MediaCategory.Markup => "📝", MediaCategory.Code => "💻", MediaCategory.Archive => "🗜", MediaCategory.Subtitle => "💬",
        MediaCategory.Font => "🔤", MediaCategory.Postscript => "🖨", MediaCategory.Model3D => "🧊", MediaCategory.Ebook => "📚",
        _ => "📁",
    };

    public bool IsReady => Phase == ItemPhase.Ready;
    public bool IsConverting => Phase == ItemPhase.Converting;
    public bool IsFinished => Phase == ItemPhase.Finished;
    public bool IsFailed => Phase == ItemPhase.Failed;
    public bool IsBusy => IsConverting;
    public bool HasRoutes => Routes.Count > 0;
    public bool HasNoRoutes => Routes.Count == 0;
    public bool IsIndeterminate => Fraction is null;
    public double Percent => (Fraction ?? 0) * 100;
    public string PercentText => Fraction is double f ? f.ToString("P0") : "";
    public bool HasPercent => Fraction is not null;

    public bool IsPdfCompress => SelectedRoute is { Engine: Engine.Ghostscript } && File.FormatId == "pdf";
    public bool PdfCustom => PdfPresetIndex == 4;
    public bool PdfCustomInvalid => IsPdfCompress && PdfCustom && FileSize.Parse(PdfCustomSize) is null;
    public bool IsImageAdjustable => SelectedRoute is { Engine: Engine.Image } && File.Category is MediaCategory.Image or MediaCategory.Vector;
    public bool IsLossyImageTarget => SelectedRoute is { } r && ImageProcessing.LossyTargets.Contains(r.Id);
    public string AdjustSummary
    {
        get
        {
            if (Edits.IsInvalid) return "Enter the size or pixel count in Adjust…";
            var summary = Edits.Summary(IsLossyImageTarget);
            return summary.Length == 0 ? "Original size and quality" : summary;
        }
    }
    public bool AdjustNeedsAttention => Edits.IsInvalid;

    public bool HasBlockingFinding => Findings.Any(f => f.Brush == FindingBrushes.Blocking);
    public bool CanConvert => !IsBusy && SelectedRoute is not null && !HasBlockingFinding && !PdfCustomInvalid
                              && !(IsImageAdjustable && Edits.IsInvalid);
    public bool CanCancel => IsBusy;
    public string ConvertLabel => Phase switch { ItemPhase.Finished => "Convert again", ItemPhase.Failed => "Try again", _ => "Convert" };
    public bool HasNotes => Notes.Count > 0;
    public bool HasToolHint => Findings.Any(f => f.Message.Contains("from Tools"));

    partial void OnSelectedRouteChanged(Route? value) { SettingsChangedSinceConverting = Phase is ItemPhase.Finished; Refresh(); }
    partial void OnPdfPresetIndexChanged(int value) { SettingsChangedSinceConverting = Phase is ItemPhase.Finished; Refresh(); }
    partial void OnPdfCustomSizeChanged(string value) => Refresh();
    partial void OnPhaseChanged(ItemPhase value) => Refresh();
    partial void OnFractionChanged(double? value)
    {
        OnPropertyChanged(nameof(IsIndeterminate)); OnPropertyChanged(nameof(Percent));
        OnPropertyChanged(nameof(PercentText)); OnPropertyChanged(nameof(HasPercent));
    }

    /// <summary>Checks everything again: the findings for this file and route, and which buttons can be used.</summary>
    public void Refresh()
    {
        Findings.Clear();
        if (SelectedRoute is { } route)
            foreach (var finding in Preflight.FindingsFor(File, route, _owner.OutputFolder, _owner.Tools))
                Findings.Add(new FindingRow(finding.Message, FindingBrushes.For(finding.Severity)));
        else if (Routes.Count == 0)
            Findings.Add(new FindingRow("Universal Converter cannot convert this kind of file yet.", FindingBrushes.Blocking));
        foreach (var name in new[]
        {
            nameof(IsReady), nameof(IsConverting), nameof(IsFinished), nameof(IsFailed), nameof(IsBusy), nameof(IsPdfCompress),
            nameof(PdfCustom), nameof(PdfCustomInvalid), nameof(IsImageAdjustable), nameof(IsLossyImageTarget), nameof(AdjustSummary),
            nameof(AdjustNeedsAttention), nameof(HasBlockingFinding), nameof(CanConvert), nameof(CanCancel), nameof(ConvertLabel),
            nameof(HasNotes), nameof(HasToolHint),
        }) OnPropertyChanged(name);
        _owner.NotifyQueueChanged();
    }

    // MARK: Converting

    internal async Task RunAsync(SemaphoreSlim gate, Converter converter, string outputFolder)
    {
        _cancel = new CancellationTokenSource();
        var token = _cancel.Token;
        Notes.Clear();
        ErrorText = ValidationText = null;
        OutputPath = null;
        Fraction = null;
        ProgressMessage = "Waiting…";
        Phase = ItemPhase.Converting;
        SettingsChangedSinceConverting = false;
        try
        {
            await gate.WaitAsync(token);
        }
        catch (OperationCanceledException)
        {
            Phase = ItemPhase.Ready;
            return;
        }
        try
        {
            var route = SelectedRoute!;
            PdfCompression pdf = (PdfPresetIndex switch
            {
                0 => new PdfCompression.Original(), 1 => new PdfCompression.Low(), 3 => new PdfCompression.High(),
                4 => new PdfCompression.Custom(FileSize.Parse(PdfCustomSize) ?? 0), _ => (PdfCompression)new PdfCompression.Medium(),
            });
            var adjustments = IsImageAdjustable ? Edits.ToAdjustments(IsLossyImageTarget) : null;
            ProgressMessage = "Converting…";
            var result = await converter.ConvertAsync(new ConversionRequest(File, route, outputFolder, pdf, adjustments), token);
            OutputPath = result.OutputPath;
            foreach (var note in result.Notes) Notes.Add(note);
            ValidationText = result.Validation?.Summary;
            LogText = string.Join("\n", result.Log);
            Phase = ItemPhase.Finished;
        }
        catch (OperationCanceledException)
        {
            Phase = ItemPhase.Ready;
        }
        catch (Exception ex)
        {
            ErrorText = ex is ConversionException ? ex.Message : $"Something went wrong: {ex.Message}";
            Phase = ItemPhase.Failed;
        }
        finally
        {
            gate.Release();
            Fraction = null;
            _cancel?.Dispose();
            _cancel = null;
            OnPropertyChanged(nameof(HasNotes));
        }
    }

    public void SetProgress(ConversionProgress update)
    {
        ProgressMessage = update.Message;
        Fraction = update.Fraction;
    }

    public void Cancel() => _cancel?.Cancel();

    public void ShowDemo(ItemPhase phase, double? fraction = null, string message = "Converting…", string? error = null, string? path = null)
    {
        Phase = phase; Fraction = fraction; ProgressMessage = message; ErrorText = error; OutputPath = path;
    }
}

public static class FindingBrushes
{
    public static readonly IBrush Info = new SolidColorBrush(Color.Parse("#7A7A7A"));
    public static readonly IBrush Caution = new SolidColorBrush(Color.Parse("#C77700"));
    public static readonly IBrush Blocking = new SolidColorBrush(Color.Parse("#C42B1C"));

    public static IBrush For(Severity severity) => severity switch
    {
        Severity.Blocking => Blocking, Severity.Caution => Caution, _ => Info,
    };
}
