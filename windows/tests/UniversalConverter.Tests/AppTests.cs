using UniversalConverter.App.ViewModels;
using UniversalConverter.Core;
using Xunit;

namespace UniversalConverter.Tests;

public class ImageEditsTests
{
    [SkippableFact]
    public void TypedSizesThatAreWrongBlockTheConversion()
    {
        var edits = new ImageEditsViewModel { CompressionIndex = (int)CompressionPreset.Custom, CustomSize = "lots" };
        Assert.True(edits.CustomSizeInvalid);
        Assert.True(edits.IsInvalid);
        Assert.Null(edits.ToAdjustments(true));
        edits.CustomSize = "500 KB";
        Assert.False(edits.IsInvalid);
        Assert.Equal(500_000, edits.ToAdjustments(true)!.CustomBytes);
        edits.SizeIndex = (int)SizeChoice.Pixels;
        Assert.True(edits.PixelsInvalid);
        edits.CustomPixels = "0";
        Assert.True(edits.PixelsInvalid);
        edits.CustomPixels = "1200";
        Assert.Equal(1200, edits.ToAdjustments(true)!.ResizeValue);
    }

    [SkippableFact]
    public void LosslessFormatsIgnoreTheQualityPresets()
    {
        var edits = new ImageEditsViewModel { CompressionIndex = (int)CompressionPreset.High };
        Assert.Equal(CompressionPreset.Original, edits.ToAdjustments(lossy: false)!.Compression);
        Assert.Equal(CompressionPreset.High, edits.ToAdjustments(lossy: true)!.Compression);
        Assert.Equal("", edits.Summary(lossy: false));
        Assert.Equal("High compression", edits.Summary(lossy: true));
    }

    [SkippableFact]
    public void ChoosingAShapeReplacesADrawnBoxAndTheOtherWayAround()
    {
        var edits = new ImageEditsViewModel();
        edits.DrawBox(new FractionRect(0.1, 0.1, 0.5, 0.5));
        Assert.NotNull(edits.CropRect);
        Assert.Equal(ImageCrop.Off, edits.Crop);
        edits.ChooseShape((int)ImageCrop.Square);
        Assert.Null(edits.CropRect);
        Assert.Equal(ImageCrop.Square, edits.ToAdjustments(true)!.Crop);
        edits.DrawBox(new FractionRect(0, 0, 1, 1));
        Assert.Null(edits.CropRect);
        Assert.False(edits.HasCrop);
    }

    [SkippableFact]
    public void TheSummaryNamesWhatChanged()
    {
        var edits = new ImageEditsViewModel { SizeIndex = (int)SizeChoice.Half, RemoveBackground = true, EffectIndex = (int)ImageEffect.Sketch, KeepMetadata = false };
        edits.ChooseShape((int)ImageCrop.Square);
        Assert.Equal("50%, square crop, background removed, sketch, no camera details", edits.Summary(true));
    }

    [SkippableFact]
    public void ChangesAreAnnounced()
    {
        int count = 0;
        var edits = new ImageEditsViewModel();
        edits.Changed += () => count++;
        edits.RemoveBackground = true;
        edits.CropIndex = 2;
        Assert.True(count >= 2);
    }
}

public class QueueTests
{
    [SkippableFact]
    public async Task AddingTheSameFileTwiceKeepsOneRow()
    {
        var main = new MainViewModel();
        var png = Samples.Path_("images/sample.png");
        await main.AddFilesAsync([png, png]);
        await main.AddFilesAsync([png]);
        Assert.Single(main.Items);
        Assert.True(main.HasItems);
        Assert.Equal("1 file", main.QueueSummary);
    }

    [SkippableFact]
    public async Task AFolderAddsTheFilesInsideIt()
    {
        var main = new MainViewModel();
        await main.AddFilesAsync([Path.Combine(Samples.Folder ?? throw new SkipException("No samples"), "images")]);
        Assert.True(main.Items.Count >= 5);
    }

    [SkippableFact]
    public async Task APictureOffersAdjustmentsOnlyForPictureTargets()
    {
        var main = new MainViewModel();
        await main.AddFilesAsync([Samples.Path_("images/sample.png")]);
        var item = main.Items[0];
        item.SelectedRoute = item.Routes.First(r => r.Id == "jpg");
        Assert.True(item.IsImageAdjustable);
        Assert.True(item.IsLossyImageTarget);
        item.SelectedRoute = item.Routes.First(r => r.Id == "pdf" && r.Steps.Count == 1);
        Assert.Equal(Engine.Image, item.SelectedRoute!.Engine);
    }

    [SkippableFact]
    public async Task AWrongTypedSizeStopsTheConvertButton()
    {
        var main = new MainViewModel();
        await main.AddFilesAsync([Samples.Path_("images/sample.png")]);
        var item = main.Items[0];
        item.SelectedRoute = item.Routes.First(r => r.Id == "jpg");
        Assert.True(item.CanConvert);
        item.Edits.CompressionIndex = (int)CompressionPreset.Custom;
        Assert.False(item.CanConvert);
        Assert.Contains("Enter the size", item.AdjustSummary);
        item.Edits.CustomSize = "40 KB";
        Assert.True(item.CanConvert);
    }

    [SkippableFact]
    public async Task APdfCompressionSizeMustBeUnderstood()
    {
        var main = new MainViewModel();
        await main.AddFilesAsync([Samples.Path_("documents/sample.pdf")]);
        var item = main.Items[0];
        var smaller = item.Routes.FirstOrDefault(r => r.Engine == Engine.Ghostscript);
        if (smaller is null) throw new SkipException("Ghostscript is not installed");
        item.SelectedRoute = smaller;
        Assert.True(item.IsPdfCompress);
        item.PdfPresetIndex = 4;
        Assert.True(item.PdfCustomInvalid);
        Assert.False(item.CanConvert);
        item.PdfCustomSize = "2 MB";
        Assert.True(item.CanConvert);
    }

    [SkippableFact]
    public async Task ARouteWhoseToolIsMissingBlocksAndPointsToTools()
    {
        var main = new MainViewModel();
        await main.AddFilesAsync([Samples.Path_("images/sample.png")]);
        var item = main.Items[0];
        var ocr = item.Routes.FirstOrDefault(r => r.Engine == Engine.Ocr);
        Assert.NotNull(ocr);
        item.SelectedRoute = ocr;
        // Text recognition comes from Windows, so on another system it is blocked with a reason.
        if (!ToolLocator.OcrAvailable) Assert.False(item.CanConvert);
        Assert.Contains(item.Findings, f => f.Message.Contains("Windows"));
    }

    [SkippableFact]
    public async Task AConversionRunsFromTheQueueToADoneRow()
    {
        using var temp = new TempFolder();
        var main = new MainViewModel { OutputFolder = temp.File_("out") };
        await main.AddFilesAsync([Samples.Path_("images/sample.png")]);
        var item = main.Items[0];
        item.SelectedRoute = item.Routes.First(r => r.Id == "jpg");
        main.Start(item);
        for (int i = 0; i < 200 && !(item.IsFinished || item.IsFailed); i++) await Task.Delay(50);
        Assert.True(item.IsFinished, item.ErrorText);
        Assert.EndsWith(".jpg", item.OutputPath);
        Assert.True(File.Exists(item.OutputPath));
        Assert.Equal("1 file · 1 done", main.QueueSummary);
    }

    [SkippableFact]
    public async Task ARemovedRowIsCancelledAndGone()
    {
        var main = new MainViewModel();
        await main.AddFilesAsync([Samples.Path_("images/sample.png")]);
        main.Remove(main.Items[0]);
        Assert.Empty(main.Items);
        Assert.True(main.HasNoItems);
    }
}

public class SettingsTests
{
    [SkippableFact]
    public void AModelManifestIsFoundWhereOllamaKeepsIt()
    {
        var path = CodeModels.ManifestPath("qwen2.5-coder:7b");
        Assert.EndsWith(Path.Combine("registry.ollama.ai", "library", "qwen2.5-coder", "7b"), path);
        Assert.EndsWith(Path.Combine("someone", "model", "latest"), CodeModels.ManifestPath("someone/model"));
    }

    [SkippableFact]
    public void EveryToolFeatureHasAPackageOrAStep()
    {
        Assert.All(ToolFeature.All, f => Assert.True(f.Packages.Length > 0 || f.ExtraSteps.Length > 0, f.Id));
        Assert.All(ToolFeature.All.SelectMany(f => f.Packages), p => Assert.Matches(@"^[A-Za-z0-9.+-]+\.[A-Za-z0-9.+-]+$", p));
    }

    [SkippableFact]
    public void SettingsSurviveARoundTrip()
    {
        var settings = new AppSettings { OllamaModel = "codellama:7b", RepairAttempts = 0, PageOutput = PageOutput.Zip, OutputFolder = "C:\\Out" };
        var json = System.Text.Json.JsonSerializer.Serialize(settings);
        var back = System.Text.Json.JsonSerializer.Deserialize<AppSettings>(json)!;
        Assert.Equal("codellama:7b", back.OllamaModel);
        Assert.Equal(PageOutput.Zip, back.PageOutput);
        Assert.Equal(0, back.RepairAttempts);
    }

    [SkippableFact]
    public void ALocatorFindsAProgramOnThePathAndNotOneThatIsNotThere()
    {
        var tools = new ToolLocator();
        Assert.NotNull(tools.Locate(ToolLocator.IsWindows ? "cmd" : "ls"));
        Assert.Null(tools.Locate("no-such-program-" + Guid.NewGuid().ToString("N")));
    }
}
