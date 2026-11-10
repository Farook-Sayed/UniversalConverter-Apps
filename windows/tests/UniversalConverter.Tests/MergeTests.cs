using System.Globalization;
using ImageMagick;
using UglyToad.PdfPig;
using UglyToad.PdfPig.Fonts.Standard14Fonts;
using UglyToad.PdfPig.Core;
using UglyToad.PdfPig.Writer;
using UniversalConverter.Core;
using Xunit;

namespace UniversalConverter.Tests;

/// <summary>Merging several files into one: pictures and PDFs into a PDF, audio, video and text documents.</summary>
public class MergeTests : IDisposable
{
    private readonly TempFolder _temp = new();
    public void Dispose() => _temp.Dispose();

    // A small PDF that needs the password "secret" to open, made with PDFKit.
    private const string LockedPdf = "JVBERi0xLjYKJcTl8uXrp/Og0MTGCjQgMCBvYmoKPDwgL0xlbmd0aCAzMiAvRmlsdGVyIC9GbGF0ZURlY29kZSA+PgpzdHJlYW0KkTpbpW6RGk7GjPAy6SoVNEgw0NCKdpSZ6jbnzmGIwVQKZW5kc3RyZWFtCmVuZG9iagoxIDAgb2JqCjw8IC9UeXBlIC9QYWdlIC9QYXJlbnQgMiAwIFIgL1Jlc291cmNlcyAzIDAgUiAvQ29udGVudHMgNCAwIFIgL01lZGlhQm94IFswIDAgNjEyIDc5Ml0KL1JvdGF0ZSAwID4+CmVuZG9iagozIDAgb2JqCjw8IC9Qcm9jU2V0IFsgL1BERiBdID4+CmVuZG9iagoyIDAgb2JqCjw8IC9UeXBlIC9QYWdlcyAvTWVkaWFCb3ggWzAgMCA2MTIgNzkyXSAvQ291bnQgMSAvS2lkcyBbIDEgMCBSIF0gPj4KZW5kb2JqCjUgMCBvYmoKPDwgL1R5cGUgL0NhdGFsb2cgL1BhZ2VzIDIgMCBSIC9WZXJzaW9uIC8xLjYgPj4KZW5kb2JqCjYgMCBvYmoKPDwgL1Byb2R1Y2VyIChsXDAyMmaFPFwwMDFcMDEyO1wwMTX3XDAzMVhcMDIyXDAwMSWru9j0XDAyMcuaXDAwMH7pnFwwMDOxOTdi0VLLu1Dd5zpueVwwMzB0izrB7JBn40TUhLZcMDIxXDAyMVwwMzBvwTM59ka7WsVcMDAws5XzStJcMDM1pPq8rFwwMTXKXDAzMCkKL0NyZWF0aW9uRGF0ZSAoIEhcMDAzXDAxNHTt571s77rT9vZcMDE2cuaA77WSXCgmy3ZcMDM1QKpcMDMyeobtYtN8flwwMzNOXDAzNX56XDAyMzdI4lZ8ZikKL01vZERhdGUgKEy+v+Lp8lwwMzdX01wopIVfXDAzNv47hFVcMDE0bdr1/VVu19/g2cz3zttcMDA1xVwwMDPeYMbLilwwMDEsXVwwMjRwMHopCj4+CmVuZG9iago3IDAgb2JqCjw8IC9GaWx0ZXIgL1N0YW5kYXJkIC9WIDQgL1IgNCAvTGVuZ3RoIDEyOCAvQ0YgPDwgL1N0ZENGIDw8IC9BdXRoRXZlbnQgL0RvY09wZW4KL0NGTSAvQUVTVjIgL0xlbmd0aCAxNiA+PiA+PiAvU3RtRiAvU3RkQ0YgL1N0ckYgL1N0ZENGIC9FbmNyeXB0TWV0YWRhdGEgdHJ1ZQovTyA8MGU1MjI5MjVhM2U0ZTg3NGMzY2ZhY2JlZjUxMWE3M2FjNGVjMmJkODY1ZGNkM2Q0NjI3NjE0OTE3YWJmZDdlND4gL1UgPDA1NmU2NjhhNGRhYzcyN2E4YzQ4NTcxY2FkZWNhMDRjMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDA+Ci9QIC00ID4+CmVuZG9iagp4cmVmCjAgOAowMDAwMDAwMDAwIDY1NTM1IGYgCjAwMDAwMDAxMjUgMDAwMDAgbiAKMDAwMDAwMDI3OCAwMDAwMCBuIAowMDAwMDAwMjM5IDAwMDAwIG4gCjAwMDAwMDAwMjIgMDAwMDAgbiAKMDAwMDAwMDM2MSAwMDAwMCBuIAowMDAwMDAwNDI0IDAwMDAwIG4gCjAwMDAwMDA3NjQgMDAwMDAgbiAKdHJhaWxlcgo8PCAvU2l6ZSA4IC9Sb290IDUgMCBSIC9FbmNyeXB0IDcgMCBSIC9JbmZvIDYgMCBSIC9JRCBbIDw4M2Q2ZTk1OGM3MWZkNmY5YTFjYzE2YTg3ZjVkZTA2ZT4KPDgzZDZlOTU4YzcxZmQ2ZjlhMWNjMTZhODdmNWRlMDZlPiBdID4+CnN0YXJ0eHJlZgoxMDg1CiUlRU9GCg==";

    // MARK: Helpers

    private static DetectedFile Detect(string path) => new FileDetector().Detect(path);

    private DetectedFile Picture(string name, string color, int width = 300, int height = 400, MagickFormat format = MagickFormat.Png)
    {
        var path = _temp.File_(name);
        using var image = new MagickImage(new MagickColor(color), (uint)width, (uint)height);
        image.Write(path, format);
        return Detect(path);
    }

    private DetectedFile Pdf(string name, int pages)
    {
        var path = _temp.File_(name);
        var builder = new PdfDocumentBuilder();
        var font = builder.AddStandard14Font(Standard14Font.Helvetica);
        for (int i = 1; i <= pages; i++) builder.AddPage(200, 200).AddText($"Page {i}", 24, new PdfPoint(20, 90), font);
        File.WriteAllBytes(path, builder.Build());
        return Detect(path);
    }

    private static string[] PageText(string pdf)
    {
        using var document = PdfDocument.Open(pdf);
        return document.GetPages().Select(p => p.Text.Trim()).ToArray();
    }

    /// <summary>The colour at the middle of a page, drawn by pdfium, as 0..255 red, green and blue.</summary>
    private (int R, int G, int B) Centre(string pdf, int page)
    {
        var png = _temp.File_($"page-{Guid.NewGuid():N}.png");
        PDFtoImage.Conversion.SavePng(png, File.ReadAllBytes(pdf), page, options: new PDFtoImage.RenderOptions(Dpi: 40, BackgroundColor: SkiaSharp.SKColors.White));
        using var image = new MagickImage(png);
        var pixel = image.GetPixels().GetPixel((int)image.Width / 2, (int)image.Height / 2)!.ToColor()!;
        return (pixel.R / 257, pixel.G / 257, pixel.B / 257);
    }

    private MergeRequest Request(MergeKind kind, IReadOnlyList<DetectedFile> files, string target, string name = "Merged", MergePageSize pageSize = MergePageSize.A4, string folder = "out")
    {
        var group = MergePlanner.GroupsFor(files).First(g => g.Kind == kind);
        var format = group.Targets.First(t => t.Id == target);
        return new MergeRequest(kind, files, format, _temp.File_(folder), name, pageSize);
    }

    private async Task Ffmpeg(params string[] arguments)
    {
        var tool = new ToolLocator().Locate("ffmpeg") ?? throw new SkipException("FFmpeg is not installed");
        var result = await ProcessRunner.RunAsync(tool, ["-hide_banner", "-loglevel", "error", "-y", .. arguments]);
        Assert.True(result.ExitCode == 0, result.StdErr);
    }

    private async Task<string> Probe(string path, string entries, string stream, string section = "stream")
    {
        var probe = new ToolLocator().Locate("ffprobe")!;
        var result = await ProcessRunner.RunAsync(probe, ["-v", "error", "-select_streams", stream, "-show_entries", entries, "-of", "csv=p=0", path]);
        return result.StdOut.Trim();
    }

    private async Task<double> Duration(string path)
    {
        var probe = new ToolLocator().Locate("ffprobe")!;
        var result = await ProcessRunner.RunAsync(probe, ["-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", path]);
        return double.Parse(result.StdOut.Trim(), CultureInfo.InvariantCulture);
    }

    // MARK: What can be merged

    [SkippableFact]
    public void TwoPicturesOrPDFsOfferOneMergeIntoAPDF()
    {
        var a = Picture("a.png", "red");
        var b = Picture("b.jpg", "green", format: MagickFormat.Jpeg);
        var groups = MergePlanner.GroupsFor([a, b]);
        Assert.Equal([MergeKind.Pdf], groups.Select(g => g.Kind));
        Assert.Equal("2 pictures into one PDF", groups[0].Title);
        Assert.Equal("1 picture and 1 PDF into one PDF", MergePlanner.GroupsFor([a, Pdf("p.pdf", 1)])[0].Title);
        Assert.Equal("2 PDFs into one PDF", MergePlanner.GroupsFor([Pdf("p.pdf", 1), Pdf("q.pdf", 2)])[0].Title);
    }

    [SkippableFact]
    public void OneFileOffersNoMerge()
    {
        Assert.Empty(MergePlanner.GroupsFor([Picture("a.png", "red")]));
        Assert.Empty(MergePlanner.GroupsFor([]));
    }

    [SkippableFact]
    public void EachKindOfFileIsGroupedWithItsOwnKind()
    {
        File.WriteAllText(_temp.File_("one.md"), "# One");
        File.WriteAllText(_temp.File_("two.html"), "<h1>Two</h1>");
        File.WriteAllText(_temp.File_("x.py"), "print(1)");
        var files = new[] { Picture("a.png", "red"), Picture("b.png", "green"), Detect(_temp.File_("one.md")), Detect(_temp.File_("two.html")), Detect(_temp.File_("x.py")) };
        var groups = MergePlanner.GroupsFor(files);
        Assert.Equal([MergeKind.Pdf, MergeKind.Document], groups.Select(g => g.Kind));
        Assert.Equal(2, groups[1].Files.Count);
        Assert.Contains(groups[1].Targets, t => t.Id == "docx");
    }

    [SkippableFact]
    public void ThePDFMergeNeedsNothingToInstallButTheOthersNameTheirTool()
    {
        var pictures = MergePlanner.GroupsFor([Picture("a.png", "red"), Picture("b.png", "green")])[0];
        Assert.Null(pictures.Engine);
        File.WriteAllText(_temp.File_("a.md"), "a"); File.WriteAllText(_temp.File_("b.md"), "b");
        Assert.Equal(Engine.Pandoc, MergePlanner.GroupsFor([Detect(_temp.File_("a.md")), Detect(_temp.File_("b.md"))])[0].Engine);
    }

    [SkippableFact]
    public void TheSuggestedFormatIsTheFirstFilesOwn()
    {
        var flac = new DetectedFile("a.flac", MediaCategory.Audio, "flac", "audio/flac", DetectionMethod.MagicBytes, false);
        var mp3 = new DetectedFile("b.mp3", MediaCategory.Audio, "mp3", "audio/mpeg", DetectionMethod.MagicBytes, false);
        Assert.Equal("flac", MergePlanner.SuggestedTarget(MergePlanner.GroupsFor([flac, mp3])[0])!.Id);
        Assert.Equal("mp3", MergePlanner.SuggestedTarget(MergePlanner.GroupsFor([mp3, flac])[0])!.Id);
    }

    // MARK: PDF

    [SkippableFact]
    public async Task PDFsAreJoinedPageForPageInTheOrderGiven()
    {
        var two = Pdf("two.pdf", 2); var three = Pdf("three.pdf", 3);
        var result = await new Converter().MergeAsync(Request(MergeKind.Pdf, [two, three], "pdf"));
        Assert.Equal(["Page 1", "Page 2", "Page 1", "Page 2", "Page 3"], PageText(result.OutputPath));
        var reversed = await new Converter().MergeAsync(Request(MergeKind.Pdf, [three, two], "pdf", folder: "rev"));
        var text = PageText(reversed.OutputPath);
        Assert.Equal(5, text.Length);
        Assert.Equal("Page 3", text[2]);
    }

    [SkippableFact]
    public async Task PicturesBecomeOnePagePerPictureInOrder()
    {
        var files = new[] { Picture("1.png", "#ff0000"), Picture("2.png", "#00ff00"), Picture("3.jpg", "#0000ff", format: MagickFormat.Jpeg) };
        var result = await new Converter().MergeAsync(Request(MergeKind.Pdf, files, "pdf"));
        Assert.Equal(3, PageText(result.OutputPath).Length);
        var colours = Enumerable.Range(0, 3).Select(i => Centre(result.OutputPath, i)).ToList();
        Assert.True(colours[0].R > 200 && colours[0].G < 60, $"{colours[0]}");
        Assert.True(colours[1].G > 200 && colours[1].R < 60, $"{colours[1]}");
        Assert.True(colours[2].B > 200 && colours[2].R < 60, $"{colours[2]}");
    }

    [SkippableFact]
    public async Task PicturePagesAreA4AndTurnForAWidePicture()
    {
        var tall = Picture("t.png", "red", 300, 400); var wide = Picture("w.png", "green", 400, 300);
        var result = await new Converter().MergeAsync(Request(MergeKind.Pdf, [tall, wide], "pdf"));
        using var document = PdfDocument.Open(result.OutputPath);
        Assert.Equal(595.28, document.GetPage(1).Width, 0.5); Assert.Equal(841.89, document.GetPage(1).Height, 0.5);
        Assert.Equal(841.89, document.GetPage(2).Width, 0.5); Assert.Equal(595.28, document.GetPage(2).Height, 0.5);
        var letter = await new Converter().MergeAsync(Request(MergeKind.Pdf, [tall, wide], "pdf", pageSize: MergePageSize.Letter, folder: "l"));
        using var us = PdfDocument.Open(letter.OutputPath);
        Assert.Equal(612, us.GetPage(1).Width, 0.5);
    }

    [SkippableFact]
    public async Task APictureKeepsItsProportionsAndSitsInTheMiddleOfAWhiteMargin()
    {
        var result = await new Converter().MergeAsync(Request(MergeKind.Pdf, [Picture("r.png", "#ff0000", 300, 400), Picture("s.png", "#ff0000", 300, 400)], "pdf"));
        var png = _temp.File_("p.png");
        PDFtoImage.Conversion.SavePng(png, File.ReadAllBytes(result.OutputPath), 0, options: new PDFtoImage.RenderOptions(Dpi: 72, BackgroundColor: SkiaSharp.SKColors.White));
        using var image = new MagickImage(png);
        var corner = image.GetPixels().GetPixel(3, 3)!.ToColor()!; var middle = image.GetPixels().GetPixel((int)image.Width / 2, (int)image.Height / 2)!.ToColor()!;
        Assert.True(corner.G > 60_000, "the margin is white");
        Assert.True(middle.G < 15_000, "the picture is red in the middle");
    }

    [SkippableFact]
    public async Task APageCanTakeTheSizeOfItsPicture()
    {
        var small = Picture("s.png", "red", 300, 150); var big = Picture("b.png", "blue", 1500, 750);
        var result = await new Converter().MergeAsync(Request(MergeKind.Pdf, [small, big], "pdf", pageSize: MergePageSize.FitPicture));
        using var document = PdfDocument.Open(result.OutputPath);
        Assert.Equal(144, document.GetPage(1).Width, 0.5); Assert.Equal(72, document.GetPage(1).Height, 0.5);
        Assert.Equal(2, document.GetPage(2).Width / document.GetPage(2).Height, 2);
        Assert.True(document.GetPage(2).Width > document.GetPage(1).Width);
        Assert.True(Centre(result.OutputPath, 1).B > 200, "the picture fills its page");
    }

    [SkippableFact]
    public async Task PicturesAndPDFsCanBeMixedAndKeepTheirOrder()
    {
        var result = await new Converter().MergeAsync(Request(MergeKind.Pdf, [Picture("r.png", "#ff0000"), Pdf("two.pdf", 2), Picture("b.jpg", "#0000ff", format: MagickFormat.Jpeg)], "pdf"));
        var text = PageText(result.OutputPath);
        Assert.Equal(4, text.Length);
        Assert.Equal("Page 1", text[1]); Assert.Equal("Page 2", text[2]);
        Assert.True(Centre(result.OutputPath, 0).R > 200);
        Assert.True(Centre(result.OutputPath, 3).B > 200);
    }

    /// <summary>A PDF made by another program has its own fonts and structure. Its text and look must survive the merge.</summary>
    [SkippableFact]
    public async Task ARealWorldPDFKeepsItsTextAndItsLookAfterAMerge()
    {
        var sample = Samples.Path_("documents/sample.pdf");
        var original = Detect(sample);
        var result = await new Converter().MergeAsync(Request(MergeKind.Pdf, [Picture("a.png", "#336699"), original, original], "pdf"));
        var before = PageText(sample);
        var after = PageText(result.OutputPath);
        Assert.Equal(1 + before.Length * 2, after.Length);
        Assert.Equal(before[0], after[1]);
        Assert.Equal(before[0], after[1 + before.Length]);
        // Drawn by pdfium, the merged page has the same dark text pixels as the original page.
        int Dark(string pdf, int page)
        {
            var png = _temp.File_($"dark-{Guid.NewGuid():N}.png");
            PDFtoImage.Conversion.SavePng(png, File.ReadAllBytes(pdf), page, options: new PDFtoImage.RenderOptions(Dpi: 60, BackgroundColor: SkiaSharp.SKColors.White));
            using var image = new MagickImage(png);
            return image.GetPixels().Count(p => p.ToColor()!.R < 100 * 257);
        }
        var a = Dark(sample, 0); var b = Dark(result.OutputPath, 1);
        Assert.True(a > 0);
        Assert.InRange((double)b / a, 0.9, 1.1);
    }

    [SkippableFact]
    public async Task APhotoThatIsTurnedIsStoodUpInThePDF()
    {
        var path = _temp.File_("turned.jpg");
        using (var photo = new MagickImage(new MagickColor("#ff0000"), 400, 300))
        {
            var exif = new ExifProfile();
            exif.SetValue(ExifTag.Orientation, (ushort)6);
            photo.SetProfile(exif);
            photo.Orientation = Orientation.RightTop;
            photo.Write(path);
        }
        var result = await new Converter().MergeAsync(Request(MergeKind.Pdf, [Detect(path), Picture("o.png", "green")], "pdf"));
        using var document = PdfDocument.Open(result.OutputPath);
        Assert.True(document.GetPage(1).Width < document.GetPage(1).Height, "the picture was stood up, so its page is portrait");
    }

    [SkippableFact]
    public async Task APasswordProtectedPDFIsRefusedByName()
    {
        var locked = _temp.File_("locked.pdf");
        File.WriteAllBytes(locked, System.Convert.FromBase64String(LockedPdf));
        var error = await Assert.ThrowsAsync<ConversionException>(() => new Converter().MergeAsync(Request(MergeKind.Pdf, [Pdf("plain.pdf", 1), Detect(locked)], "pdf")));
        Assert.Contains("locked.pdf", error.Message);
        Assert.Contains("password", error.Message);
    }

    [SkippableFact]
    public async Task APictureThatCannotBeReadIsNamedAndNothingIsSaved()
    {
        var bad = _temp.File_("bad.png");
        File.WriteAllText(bad, "this is not a picture");
        var badFile = new DetectedFile(bad, MediaCategory.Image, "png", "image/png", DetectionMethod.ExtensionOnly, false);
        var error = await Assert.ThrowsAsync<ConversionException>(() => new Converter().MergeAsync(Request(MergeKind.Pdf, [Picture("good.png", "red"), badFile], "pdf")));
        Assert.Contains("bad.png", error.Message);
        Assert.False(Directory.Exists(_temp.File_("out")), "no half-made file is left");
    }

    [SkippableFact]
    public async Task MergingNeedsAtLeastTwoFiles()
    {
        var one = Picture("a.png", "red");
        var group = new MergeGroup(MergeKind.Pdf, [one], [new OutputFormat("pdf", "PDF", "pdf", Engine.Pdf)]);
        var error = await Assert.ThrowsAsync<ConversionException>(() => new Converter().MergeAsync(new MergeRequest(MergeKind.Pdf, [one], group.Targets[0], _temp.File_("out"))));
        Assert.Contains("at least two", error.Message);
    }

    [SkippableFact]
    public async Task TheNameCannotPointOutsideTheOutputFolderAndNothingIsOverwritten()
    {
        var files = new[] { Picture("a.png", "red"), Picture("b.png", "green") };
        var evil = await new Converter().MergeAsync(Request(MergeKind.Pdf, files, "pdf", name: "../../evil"));
        Assert.Equal(Path.GetFullPath(_temp.File_("out")), Path.GetDirectoryName(evil.OutputPath));
        var first = await new Converter().MergeAsync(Request(MergeKind.Pdf, files, "pdf", name: "Report"));
        var second = await new Converter().MergeAsync(Request(MergeKind.Pdf, files, "pdf", name: "Report"));
        Assert.Equal("Report.pdf", Path.GetFileName(first.OutputPath));
        Assert.Equal("Report (2).pdf", Path.GetFileName(second.OutputPath));
    }

    [SkippableFact]
    public async Task TheMergedPDFReportsItsProgressFromZeroToOne()
    {
        var files = Enumerable.Range(0, 6).Select(i => Picture($"p{i}.png", "red")).ToList();
        var log = new ProgressLog();
        await new Converter(progress: log.Add).MergeAsync(Request(MergeKind.Pdf, files, "pdf"));
        var fractions = log.All.Select(p => p.Fraction).Where(f => f is not null).Select(f => f!.Value).ToList();
        Assert.Equal(6, fractions.Count);
        Assert.Equal(fractions.Order(), fractions);
        Assert.All(fractions, f => Assert.InRange(f, 0, 1));
    }

    [SkippableFact]
    public async Task CancellingAPDFMergeStopsItAndSavesNothing()
    {
        var files = Enumerable.Range(0, 3).Select(i => Picture($"p{i}.png", "red")).ToList();
        using var cancel = new CancellationTokenSource();
        cancel.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => new Converter().MergeAsync(Request(MergeKind.Pdf, files, "pdf"), cancel.Token));
        Assert.False(Directory.Exists(_temp.File_("out")));
    }

    // MARK: Audio and video

    [SkippableFact]
    public async Task AudioFilesAreJoinedEndToEndEvenWhenTheirFormatsDiffer()
    {
        await Ffmpeg("-f", "lavfi", "-i", "sine=frequency=440:duration=1", _temp.File_("a.wav"));
        await Ffmpeg("-f", "lavfi", "-i", "sine=frequency=880:duration=2", "-ac", "1", "-ar", "22050", _temp.File_("b.flac"));
        await Ffmpeg("-f", "lavfi", "-i", "sine=frequency=660:duration=1.5", _temp.File_("c.mp3"));
        var files = new[] { "a.wav", "b.flac", "c.mp3" }.Select(n => Detect(_temp.File_(n))).ToList();
        var result = await new Converter().MergeAsync(Request(MergeKind.Audio, files, "mp3"));
        Assert.Equal("mp3", Detect(result.OutputPath).FormatId);
        Assert.Equal(4.5, await Duration(result.OutputPath), 0.2);
        var wav = await new Converter().MergeAsync(Request(MergeKind.Audio, files, "wav", folder: "wav"));
        Assert.Equal("44100", await Probe(wav.OutputPath, "stream=sample_rate", "a:0"));
    }

    [SkippableFact]
    public async Task AVideoWithNoSoundIsRefusedForAnAudioMerge()
    {
        await Ffmpeg("-f", "lavfi", "-i", "sine=duration=1", _temp.File_("a.wav"));
        await Ffmpeg("-f", "lavfi", "-i", "testsrc=duration=1:size=160x120:rate=10", "-pix_fmt", "yuv420p", _temp.File_("silent.mp4"));
        var files = new[] { Detect(_temp.File_("a.wav")), Detect(_temp.File_("silent.mp4")) };
        var request = new MergeRequest(MergeKind.Audio, files, new OutputFormat("mp3", "MP3", "mp3", Engine.Ffmpeg), _temp.File_("out"));
        var error = await Assert.ThrowsAsync<ConversionException>(() => new Converter().MergeAsync(request));
        Assert.Contains("silent.mp4", error.Message);
        Assert.Contains("no sound track", error.Message);
    }

    [SkippableFact]
    public async Task VideosOfDifferentSizesAreJoinedAtTheFirstOnesSize()
    {
        await Ffmpeg("-f", "lavfi", "-i", "testsrc=duration=1:size=320x240:rate=25", "-f", "lavfi", "-i", "sine=duration=1", "-shortest", "-pix_fmt", "yuv420p", "-c:v", "libx264", _temp.File_("a.mp4"));
        await Ffmpeg("-f", "lavfi", "-i", "testsrc=duration=2:size=640x360:rate=30", "-f", "lavfi", "-i", "sine=duration=2", "-shortest", "-pix_fmt", "yuv420p", "-c:v", "libx264", _temp.File_("b.mp4"));
        var files = new[] { "a.mp4", "b.mp4" }.Select(n => Detect(_temp.File_(n))).ToList();
        var log = new ProgressLog();
        var result = await new Converter(progress: log.Add).MergeAsync(Request(MergeKind.Video, files, "mp4"));
        Assert.Equal("mp4", Detect(result.OutputPath).FormatId);
        Assert.Equal(3, await Duration(result.OutputPath), 0.3);
        Assert.Equal("320,240", await Probe(result.OutputPath, "stream=width,height", "v:0"));
        Assert.Equal("audio", await Probe(result.OutputPath, "stream=codec_type", "a:0"));
        var fractions = log.All.Select(p => p.Fraction).Where(f => f is not null).Select(f => f!.Value).ToList();
        Assert.NotEmpty(fractions);
        Assert.True(fractions.Max() > 0.5);
        Assert.Empty(result.Notes);
    }

    [SkippableFact]
    public async Task VideosWhereOneHasNoSoundAreJoinedWithoutSoundAndTheUserIsTold()
    {
        await Ffmpeg("-f", "lavfi", "-i", "testsrc=duration=1:size=160x120:rate=10", "-f", "lavfi", "-i", "sine=duration=1", "-shortest", "-pix_fmt", "yuv420p", _temp.File_("a.mp4"));
        await Ffmpeg("-f", "lavfi", "-i", "testsrc=duration=1:size=160x120:rate=10", "-pix_fmt", "yuv420p", _temp.File_("silent.mp4"));
        var files = new[] { "a.mp4", "silent.mp4" }.Select(n => Detect(_temp.File_(n))).ToList();
        var result = await new Converter().MergeAsync(Request(MergeKind.Video, files, "mp4"));
        Assert.Contains(result.Notes, n => n.Contains("no sound"));
        Assert.Equal("", await Probe(result.OutputPath, "stream=codec_type", "a:0"));
        Assert.Equal(2, await Duration(result.OutputPath), 0.3);
    }

    [SkippableFact]
    public void TheJoinCommandMatchesEveryInputAndLeavesOutSoundThatIsNotThere()
    {
        string[] inputs = ["/tmp/in1.mp4", "/tmp/in2.mp4", "/tmp/in3.mp4"];
        var withSound = FfmpegMerge.Arguments(inputs, "mp4", true, 321, 241, 29.97, true, "/tmp/out.mp4", 4);
        var graph = withSound[withSound.IndexOf("-filter_complex") + 1];
        Assert.Contains("concat=n=3:v=1:a=1[v][a]", graph);
        Assert.Contains("scale=320:240", graph);
        Assert.Contains("fps=29.97", graph);
        Assert.Equal(3, withSound.Count(a => a == "-i"));
        Assert.Equal("/tmp/out.mp4", withSound[^1]);
        var silent = FfmpegMerge.Arguments(inputs, "mp4", true, null, null, null, false, "/tmp/out.mp4", 2);
        var silentGraph = silent[silent.IndexOf("-filter_complex") + 1];
        Assert.Contains("concat=n=3:v=1:a=0[v]", silentGraph);
        Assert.DoesNotContain("aresample", silentGraph);
        Assert.Contains("scale=1280:720", silentGraph);
        var audio = FfmpegMerge.Arguments(inputs, "mp3", false, null, null, null, true, "/tmp/out.mp3", 2);
        var audioGraph = audio[audio.IndexOf("-filter_complex") + 1];
        Assert.Contains("concat=n=3:v=0:a=1[a]", audioGraph);
        Assert.DoesNotContain("scale", audioGraph);
    }

    [SkippableFact]
    public async Task CancellingAMediaMergeStopsFfmpegAndSavesNothing()
    {
        await Ffmpeg("-f", "lavfi", "-i", "testsrc=duration=40:size=1280x720:rate=30", "-f", "lavfi", "-i", "sine=duration=40", "-shortest", "-pix_fmt", "yuv420p", "-preset", "ultrafast", _temp.File_("a.mp4"));
        var files = new[] { Detect(_temp.File_("a.mp4")), Detect(_temp.File_("a.mp4")) };
        using var cancel = new CancellationTokenSource();
        var task = new Converter().MergeAsync(Request(MergeKind.Video, files, "webm"), cancel.Token);
        await Task.Delay(1500);
        cancel.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => task);
        Assert.False(Directory.Exists(_temp.File_("out")));
    }

    // MARK: Documents

    private static async Task<string> PlainText(string path)
    {
        var pandoc = new ToolLocator().Locate("pandoc")!;
        var from = Path.GetExtension(path) switch { ".docx" => "docx", ".html" => "html", _ => "markdown" };
        return (await ProcessRunner.RunAsync(pandoc, ["--from", from, "--to", "plain", path])).StdOut;
    }

    [SkippableFact]
    public async Task MarkdownFilesAreJoinedInOrder()
    {
        Skip.If(new ToolLocator().Locate("pandoc") is null, "Pandoc is not installed");
        File.WriteAllText(_temp.File_("one.md"), "# Alpha\n\nFirst chapter.");
        File.WriteAllText(_temp.File_("two.md"), "# Beta\n\nSecond chapter.");
        File.WriteAllText(_temp.File_("three.md"), "# Gamma\n\nThird chapter.");
        var files = new[] { "one.md", "two.md", "three.md" }.Select(n => Detect(_temp.File_(n))).ToList();
        var result = await new Converter().MergeAsync(Request(MergeKind.Document, files, "md"));
        var text = File.ReadAllText(result.OutputPath);
        var order = new[] { "Alpha", "Beta", "Gamma" }.Select(w => text.IndexOf(w, StringComparison.Ordinal)).ToList();
        Assert.All(order, i => Assert.True(i >= 0));
        Assert.Equal(order.Order(), order);
        Assert.Empty(result.Notes);
        var docx = await new Converter().MergeAsync(Request(MergeKind.Document, files, "docx", folder: "w"));
        var words = await PlainText(docx.OutputPath);
        Assert.True(words.IndexOf("Alpha", StringComparison.Ordinal) < words.IndexOf("Gamma", StringComparison.Ordinal));
    }

    [SkippableFact]
    public async Task DocumentsOfDifferentKindsAreJoinedAndTheUserIsTold()
    {
        Skip.If(new ToolLocator().Locate("pandoc") is null, "Pandoc is not installed");
        File.WriteAllText(_temp.File_("notes.md"), "# Notes\n\nFrom markdown.");
        File.WriteAllText(_temp.File_("page.html"), "<h1>Page</h1><p>From html.</p>");
        var first = Detect(_temp.File_("notes.md")); var second = Detect(_temp.File_("page.html"));
        var result = await new Converter().MergeAsync(Request(MergeKind.Document, [first, second], "docx"));
        var text = await PlainText(result.OutputPath);
        Assert.True(text.IndexOf("From markdown", StringComparison.Ordinal) < text.IndexOf("From html", StringComparison.Ordinal));
        Assert.Contains(result.Notes, n => n.Contains("different kinds"));
        var mixed = await new Converter().MergeAsync(Request(MergeKind.Document, [Detect(result.OutputPath), first], "txt", folder: "t"));
        var joined = File.ReadAllText(mixed.OutputPath);
        Assert.Contains("From html", joined); Assert.Contains("From markdown", joined);
    }

    private static class Skip { public static void If(bool condition, string reason) { if (condition) throw new SkipException(reason); } }
}
