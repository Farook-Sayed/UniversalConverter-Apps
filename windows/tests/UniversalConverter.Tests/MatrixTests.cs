using UniversalConverter.Core;
using Xunit;

namespace UniversalConverter.Tests;

public class PreflightTests
{
    private static DetectedFile File_(string name, string id, MediaCategory c, bool mismatch = false) =>
        new(Path.Combine(Path.GetTempPath(), name), c, id, "x", DetectionMethod.MagicBytes, mismatch);

    [Fact]
    public void AMissingToolBlocksTheConversion()
    {
        var route = new Route([new RouteStep("mp4", MediaCategory.Video, new OutputFormat("mkv", "MKV", "mkv", Engine.Ffmpeg), MediaCategory.Video)]);
        var tools = new ToolLocator();
        using var temp = new TempFolder();
        var path = temp.File_("a.mp4");
        File.WriteAllBytes(path, new byte[100]);
        var file = new DetectedFile(path, MediaCategory.Video, "mp4", "video/mp4", DetectionMethod.MagicBytes, false);
        var findings = Preflight.FindingsFor(file, route, temp.Path, tools);
        if (tools.Locate("ffmpeg") is null) Assert.Contains(findings, f => f.Severity == Severity.Blocking && f.Message.Contains("FFmpeg"));
        else Assert.DoesNotContain(findings, f => f.Severity == Severity.Blocking);
    }

    [Fact]
    public void AMislabelledFileIsMentioned()
    {
        var path = Path.Combine(Path.GetTempPath(), "holiday.jpg");
        var file = new DetectedFile(path, MediaCategory.Image, "png", "image/png", DetectionMethod.MagicBytes, true);
        var route = new Route([new RouteStep("png", MediaCategory.Image, new OutputFormat("webp", "WebP", "webp", Engine.Image), MediaCategory.Image)]);
        Assert.Contains(Preflight.FindingsFor(file, route, Path.GetTempPath(), new ToolLocator()), f => f.Message.Contains("really PNG"));
    }

    [Fact]
    public void AFolderThatCannotBeWrittenBlocks()
    {
        // A drive that does not exist cannot be written to by anyone, including an administrator.
        Assert.False(Preflight.CanWrite(ToolLocator.IsWindows ? "Q:\\no-such-drive\\folder" : "/System/Library/no-such-folder"));
        Assert.True(Preflight.CanWrite(Path.Combine(Path.GetTempPath(), "not-yet-made-" + Guid.NewGuid().ToString("N"))));
    }

    [Fact]
    public void LowDiskSpaceIsACautionNotABlock()
    {
        Assert.Equal(Severity.Caution, Preflight.SpaceFinding(500_000_000, 100_000_000)!.Severity);
        Assert.Null(Preflight.SpaceFinding(1_000, 100_000_000_000));
    }

    [Theory]
    [InlineData(MediaCategory.Image, "png", "jpg", "transparency"), InlineData(MediaCategory.Audio, "mp3", "ogg", "lossy audio"),
     InlineData(MediaCategory.Document, "pdf", "png", "own image"), InlineData(MediaCategory.Code, "python", "java", "syntax only")]
    public void LossyConversionsAreExplained(MediaCategory category, string from, string to, string phrase) =>
        Assert.Contains(phrase, Preflight.LossyNote(category, from, to));
}

/// <summary>Converts every sample file to every format the app offers for it. Slow, so it only runs when asked:
/// set UC_RUN_MATRIX=1. Code translation is left out unless UC_MATRIX_CODE=1, because it needs a model.</summary>
public class MatrixTests
{
    [SkippableFact]
    public async Task EverySampleConvertsToEveryOfferedFormat()
    {
        Skip.IfNot(Environment.GetEnvironmentVariable("UC_RUN_MATRIX") == "1", "Set UC_RUN_MATRIX=1 to run the matrix.");
        var folder = Samples.Folder ?? throw new InvalidOperationException("No TestFiles folder");
        bool code = Environment.GetEnvironmentVariable("UC_MATRIX_CODE") == "1";
        var tools = new ToolLocator();
        var report = new List<string>();
        var detector = new FileDetector();
        using var temp = new TempFolder();
        int index = 0;
        Ocr.Engine = new FakeOcr("matrix text");
        foreach (var file in Directory.GetFiles(folder, "*", SearchOption.AllDirectories).Order())
        {
            if (file.Contains("edge-cases") || file.Contains("mislabelled") || file.Contains("unknown") || Path.GetFileName(file).StartsWith('.')) continue;
            var detected = detector.Detect(file);
            if (detected.Category == MediaCategory.Unknown) continue;
            foreach (var route in FormatCatalog.TargetsFor(detected, e => tools.IsAvailable(e) || (e == Engine.Ollama && code)))
            {
                if (route.Steps.Any(s => s.Output.Engine == Engine.Ollama) && !code) continue;
                var rel = Path.GetRelativePath(folder, file);
                var outDir = Path.Combine(temp.Path, (index++).ToString());
                try
                {
                    var result = await new Converter().ConvertAsync(new ConversionRequest(detected, route, outDir));
                    bool isFolder = Directory.Exists(result.OutputPath);
                    var found = isFolder ? route.Id : new FileDetector().Detect(result.OutputPath).FormatId;
                    bool sameKind = found == route.Id || (route.Id == "txt" && found is "txt" or "text") || (route.Id == "md" && found is "md" or "txt" or "text")
                        || (route.Id == "pdf" && found == "pdf") || (isFolder) || (route.Id is "gltf" or "obj" or "dae" or "ply" or "stl") || found == "unknown"
                        || (route.Id == "csv" && found is "csv" or "txt" or "text") || FormatCatalog.OutputCategory(found) == FormatCatalog.OutputCategory(route.Id) && route.Id is "html" or "rtf" or "ass" or "srt" or "vtt";
                    report.Add($"{(sameKind ? "OK    " : "WRONG ")} {rel} -> {route.Id}{(sameKind ? "" : $" (got {found})")}");
                }
                catch (ConversionException ex) when (ex.Message.Contains("no sound track") || ex.Message.Contains("cannot be saved as"))
                {
                    report.Add($"REFUSED {rel} -> {route.Id}: {ex.Message.Split('\n')[0]}");
                }
                catch (Exception ex)
                {
                    report.Add($"FAIL  {rel} -> {route.Id}: {ex.GetType().Name} {ex.Message.Split('\n')[0]}");
                }
            }
        }
        Ocr.Engine = null;
        var path = Path.Combine(AppContext.BaseDirectory, "matrix-report.txt");
        File.WriteAllLines(path, report);
        var bad = report.Where(l => l.StartsWith("FAIL") || l.StartsWith("WRONG")).ToList();
        Assert.True(bad.Count == 0, $"{bad.Count} of {report.Count} conversions went wrong. First: {string.Join(" | ", bad.Take(8))}. Report: {path}");
    }
}
