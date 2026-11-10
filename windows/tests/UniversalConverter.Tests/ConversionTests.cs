using ImageMagick;
using UniversalConverter.Core;

namespace UniversalConverter.Tests;

public class ImageTests
{
    private static ImageAdjustments With(Func<ImageAdjustments, ImageAdjustments> change) => change(ImageAdjustments.Unchanged);

    private static (uint W, uint H) SizeOf(byte[] data) { using var i = new MagickImage(data); return (i.Width, i.Height); }

    [SkippableFact]
    public void ADrawnCropKeepsThatPartOfThePicture()
    {
        using var temp = new TempFolder();
        var src = Samples.Picture(temp.Path);
        var data = ImageProcessing.Render(src, "png", With(a => a with { CropRect = new FractionRect(0.25, 0, 0.5, 1) })).Data;
        Assert.Equal((200u, 300u), SizeOf(data));
    }

    [SkippableFact]
    public void ACropBoxMovesToTheSpotItCovers()
    {
        using var temp = new TempFolder();
        var src = Samples.Picture(temp.Path); // a bright circle in the middle
        var centre = ImageProcessing.Render(src, "png", With(a => a with { CropRect = new FractionRect(0.4, 0.4, 0.2, 0.2) })).Data;
        var corner = ImageProcessing.Render(src, "png", With(a => a with { CropRect = new FractionRect(0, 0, 0.2, 0.2) })).Data;
        using var c = new MagickImage(centre); using var k = new MagickImage(corner);
        Assert.True(c.GetPixels().GetPixel(5, 5)!.ToColor()!.R > 40_000, "the middle of the picture is the orange circle");
        Assert.True(k.GetPixels().GetPixel(5, 5)!.ToColor()!.R < 20_000, "the corner is the dark background");
    }

    [SkippableFact]
    public void ShapesGiveTheRectangleTheyCover()
    {
        var square = ImageCrop.Square.FractionRect(1.5)!.Value;
        Assert.Equal(1 / 1.5, square.Width, 4);
        Assert.Equal((1 - 1 / 1.5) / 2, square.X, 4);
        Assert.Equal(0.5, ImageCrop.Square.FractionRect(0.5)!.Value.Height, 4);
        Assert.Null(ImageCrop.Off.FractionRect(1.5));
    }

    [SkippableFact]
    public void ResizeNeverEnlarges()
    {
        using var temp = new TempFolder();
        var src = Samples.Picture(temp.Path);
        Assert.Equal((200u, 150u), SizeOf(ImageProcessing.Render(src, "png", With(a => a with { Resize = ResizeMode.Percent, ResizeValue = 50 })).Data));
        Assert.Equal((100u, 75u), SizeOf(ImageProcessing.Render(src, "png", With(a => a with { Resize = ResizeMode.LongestSide, ResizeValue = 100 })).Data));
        Assert.Equal((400u, 300u), SizeOf(ImageProcessing.Render(src, "png", With(a => a with { Resize = ResizeMode.LongestSide, ResizeValue = 4000 })).Data));
    }

    [SkippableFact]
    public void StrongerCompressionMakesASmallerJpeg()
    {
        using var temp = new TempFolder();
        var src = Path.Combine(temp.Path, "noise.png");
        using (var noise = new MagickImage("plasma:fractal", 600, 400)) noise.Write(src);
        long Size(CompressionPreset p) => ImageProcessing.Render(src, "jpg", With(a => a with { Compression = p })).Data.Length;
        Assert.True(Size(CompressionPreset.Low) > Size(CompressionPreset.Medium));
        Assert.True(Size(CompressionPreset.Medium) > Size(CompressionPreset.High));
    }

    [SkippableFact]
    public void ACustomSizeIsMetOrTheSmallestIsReported()
    {
        using var temp = new TempFolder();
        var src = Path.Combine(temp.Path, "noise.png");
        using (var noise = new MagickImage("plasma:fractal", 800, 600)) noise.Write(src);
        var fit = ImageProcessing.Render(src, "jpg", With(a => a with { Compression = CompressionPreset.Custom, CustomBytes = 20_000 }));
        Assert.True(fit.Data.Length <= 20_000, $"{fit.Data.Length} bytes");
        var impossible = ImageProcessing.Render(src, "jpg", With(a => a with { Compression = CompressionPreset.Custom, CustomBytes = 50 }));
        Assert.Contains(impossible.Notes, n => n.Contains("Could not get the file to"));
        // A lossless format reaches the goal by making the picture smaller.
        var png = ImageProcessing.Render(src, "png", With(a => a with { Compression = CompressionPreset.Custom, CustomBytes = 100_000 }));
        Assert.True(png.Data.Length <= 100_000, $"{png.Data.Length} bytes");
        Assert.True(SizeOf(png.Data).W < 800);
    }

    [SkippableFact]
    public void SketchDrawsOnWhitePaper()
    {
        using var temp = new TempFolder();
        var src = Samples.Picture(temp.Path);
        using var sketch = new MagickImage(ImageProcessing.Render(src, "png", With(a => a with { Effect = ImageEffect.Sketch })).Data);
        var flat = sketch.GetPixels().GetPixel(10, 10)!.ToColor()!;
        Assert.True(flat.R > 59_000 && flat.G > 59_000, "flat areas wash out to white");
        var stats = sketch.Statistics().Composite();
        Assert.True(stats.Mean > 40_000, "the drawing is mostly paper");
    }

    [SkippableFact]
    public void BackgroundRemovalKeepsTheSubjectAndMakesTheRestTransparent()
    {
        using var temp = new TempFolder();
        var src = Samples.Picture(temp.Path, width: 512, height: 512);
        var result = ImageProcessing.Render(src, "png", With(a => a with { RemoveBackground = true }));
        using var image = new MagickImage(result.Data);
        Assert.True(image.HasAlpha);
        var corner = image.GetPixels().GetPixel(3, 3)!.ToColor()!;
        var middle = image.GetPixels().GetPixel(256, 256)!.ToColor()!;
        Assert.True(corner.A < 30_000, $"the corner should be see-through, alpha {corner.A}");
        Assert.True(middle.A > 30_000, $"the subject should stay solid, alpha {middle.A}");
    }

    [SkippableFact]
    public void ARemovedBackgroundIsWhiteInAJpegAndSaysSo()
    {
        using var temp = new TempFolder();
        var src = Samples.Picture(temp.Path, width: 512, height: 512);
        var result = ImageProcessing.Render(src, "jpg", With(a => a with { RemoveBackground = true }));
        Assert.Contains(result.Notes, n => n.Contains("no transparency"));
        using var image = new MagickImage(result.Data);
        Assert.False(image.HasAlpha);
        Assert.True(image.GetPixels().GetPixel(3, 3)!.ToColor()!.R > 60_000, "the background is white");
    }

    [SkippableFact]
    public void AFlatPictureWithNoSubjectIsLeftAlone()
    {
        using var temp = new TempFolder();
        var path = Path.Combine(temp.Path, "flat.png");
        using (var flat = new MagickImage(MagickColors.SteelBlue, 200, 200)) flat.Write(path);
        var result = ImageProcessing.Render(path, "png", With(a => a with { RemoveBackground = true }));
        Assert.Contains(result.Notes, n => n.Contains("No clear subject"));
    }

    [SkippableFact]
    public void DetailsAreKeptUnlessTheUserTurnsThemOff()
    {
        using var temp = new TempFolder();
        var path = Path.Combine(temp.Path, "gps.jpg");
        using (var photo = new MagickImage(new MagickColor("#336699"), 200, 100))
        {
            var exif = new ExifProfile();
            exif.SetValue(ExifTag.Make, "Contoso");
            photo.SetProfile(exif);
            photo.Write(path);
        }
        using var kept = new MagickImage(ImageProcessing.Render(path, "jpg", ImageAdjustments.Unchanged).Data);
        using var stripped = new MagickImage(ImageProcessing.Render(path, "jpg", With(a => a with { KeepMetadata = false })).Data);
        Assert.NotNull(kept.GetExifProfile());
        Assert.Null(stripped.GetExifProfile());
    }

    [SkippableFact]
    public void ARotatedPhotoIsStoodUp()
    {
        using var temp = new TempFolder();
        var path = Path.Combine(temp.Path, "turned.jpg");
        using (var photo = new MagickImage(new MagickColor("#336699"), 200, 100))
        {
            // The camera's "rotate 90" mark, in the details and on the picture, because Magick.NET writes it from both.
            var exif = new ExifProfile();
            exif.SetValue(ExifTag.Orientation, (ushort)6);
            photo.SetProfile(exif);
            photo.Orientation = Orientation.RightTop;
            photo.Write(path);
        }
        Assert.Equal((100u, 200u), SizeOf(ImageProcessing.Render(path, "png", ImageAdjustments.Unchanged).Data));
    }

    [SkippableFact]
    public void HeicPicturesAreRead()
    {
        using var temp = new TempFolder();
        var heic = temp.File_("photo.heic");
        var sips = "/usr/bin/sips";
        if (!File.Exists(sips)) throw new SkipException("sips is not available");
        var made = ProcessRunner.RunAsync(sips, ["-s", "format", "heic", Samples.Path_("images/sample.png"), "--out", heic]).Result;
        Assert.Equal(0, made.ExitCode);
        Assert.Equal("heic", new FileDetector().Detect(heic).FormatId);
        Assert.Equal((320u, 240u), SizeOf(ImageProcessing.Render(heic, "jpg", ImageAdjustments.Unchanged).Data));
    }

    [SkippableFact]
    public void ACameraRawFileFallsBackToItsEmbeddedPreview()
    {
        using var temp = new TempFolder();
        // A stand-in RAW: a TIFF header followed by data and a full-size JPEG preview, as real RAW files hold.
        using var preview = new MagickImage("plasma:fractal", 640, 480);
        var jpeg = preview.ToByteArray(MagickFormat.Jpeg);
        var raw = new List<byte> { 0x49, 0x49, 0x2A, 0x00, 8, 0, 0, 0 };
        raw.AddRange(new byte[5000]);
        raw.AddRange(jpeg);
        raw.AddRange(new byte[100]);
        var path = temp.File_("photo.dng");
        File.WriteAllBytes(path, raw.ToArray());
        Assert.Equal("dng", new FileDetector().Detect(path).FormatId);
        Assert.Equal((640u, 480u), SizeOf(ImageProcessing.Render(path, "png", ImageAdjustments.Unchanged).Data));
    }

    [SkippableFact]
    public async Task APictureThatIsOnlyBeingCompressedNeverGrows()
    {
        using var temp = new TempFolder();
        var src = Samples.Path_("images/sample.jpg");
        var detected = new FileDetector().Detect(src);
        var route = FormatCatalog.TargetsFor(detected).Single(r => r.Id == "jpg");
        var result = await new Converter().ConvertAsync(new ConversionRequest(detected, route, temp.File_("out"),
            ImageAdjustments: With(a => a with { Compression = CompressionPreset.High })));
        Assert.True(new FileInfo(result.OutputPath).Length <= new FileInfo(src).Length);
    }

    [SkippableFact]
    public async Task ANoOpAdjustmentIsAnExactCopyAndSaysSo()
    {
        using var temp = new TempFolder();
        var src = Samples.Path_("images/sample.png");
        var detected = new FileDetector().Detect(src);
        var route = FormatCatalog.TargetsFor(detected).Single(r => r.Id == "png");
        var result = await new Converter().ConvertAsync(new ConversionRequest(detected, route, temp.File_("out")));
        Assert.Equal(File.ReadAllBytes(src), File.ReadAllBytes(result.OutputPath));
        Assert.Contains(result.Notes, n => n.Contains("exact copy"));
    }
}

public class TextReadingTests
{
    [SkippableFact]
    public async Task APictureIsReadWithTheSystemsTextRecognition()
    {
        using var temp = new TempFolder();
        var src = Samples.Picture(temp.Path);
        var fake = new FakeOcr("HELLO WORLD");
        Ocr.Engine = fake;
        try
        {
            var detected = new FileDetector().Detect(src);
            var route = FormatCatalog.TargetsFor(detected).First(r => r.Id == "txt" && r.Engine == Engine.Ocr);
            var result = await new Converter().ConvertAsync(new ConversionRequest(detected, route, temp.File_("out")));
            Assert.Equal("HELLO WORLD", File.ReadAllText(result.OutputPath));
            Assert.Equal(1, fake.Calls);
        }
        finally { Ocr.Engine = null; }
    }

    [SkippableFact]
    public async Task APictureWithNoTextSaysSo()
    {
        using var temp = new TempFolder();
        var src = Samples.Picture(temp.Path);
        Ocr.Engine = new FakeOcr("");
        try
        {
            var detected = new FileDetector().Detect(src);
            var route = FormatCatalog.TargetsFor(detected).First(r => r.Id == "txt" && r.Engine == Engine.Ocr);
            var result = await new Converter().ConvertAsync(new ConversionRequest(detected, route, temp.File_("out")));
            Assert.Contains(result.Notes, n => n.Contains("No text was found"));
        }
        finally { Ocr.Engine = null; }
    }

    [SkippableFact]
    public void ATransparentPictureIsPutOnWhiteBeforeReading()
    {
        using var temp = new TempFolder();
        var path = Path.Combine(temp.Path, "clear.png");
        using (var clear = new MagickImage(MagickColors.Transparent, 100, 100)) clear.Write(path);
        using var prepared = new MagickImage(Converter_PictureForReading(path));
        Assert.True(prepared.GetPixels().GetPixel(5, 5)!.ToColor()!.R > 60_000);
    }

    private static byte[] Converter_PictureForReading(string path) =>
        (byte[])typeof(Converter).GetMethod("PictureForReading", System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Static)!.Invoke(null, [path])!;

    [SkippableFact]
    public async Task AScannedPdfIsReadPageByPageAndTheUserIsTold()
    {
        using var temp = new TempFolder();
        // A PDF made from a picture has no text layer, as a scan has none.
        var scan = temp.File_("scan.pdf");
        using (var pages = new MagickImageCollection())
        {
            pages.Add(new MagickImage(MagickColors.White, 300, 200));
            pages.Add(new MagickImage(MagickColors.White, 300, 200));
            pages.Write(scan, MagickFormat.Pdf);
        }
        var fake = new FakeOcr("SCANNED PAGE");
        Ocr.Engine = fake;
        try
        {
            var detected = new FileDetector().Detect(scan);
            var route = FormatCatalog.TargetsFor(detected).First(r => r.Id == "txt" && r.Engine == Engine.Pdf);
            var result = await new Converter().ConvertAsync(new ConversionRequest(detected, route, temp.File_("out")));
            var text = File.ReadAllText(result.OutputPath);
            Assert.Equal("SCANNED PAGE\n\nSCANNED PAGE".Replace("\n", Environment.NewLine == "\r\n" ? "\n" : "\n"), text.Replace("\r\n", "\n"));
            Assert.Equal(2, fake.Calls);
            Assert.Contains(result.Notes, n => n.Contains("no text layer"));
        }
        finally { Ocr.Engine = null; }
    }

    [SkippableFact]
    public async Task ATypedPdfNeedsNoRecognition()
    {
        using var temp = new TempFolder();
        var src = Samples.Path_("documents/sample.pdf");
        var fake = new FakeOcr("SHOULD NOT BE USED");
        Ocr.Engine = fake;
        try
        {
            var detected = new FileDetector().Detect(src);
            var route = FormatCatalog.TargetsFor(detected).First(r => r.Id == "txt" && r.Engine == Engine.Pdf);
            var result = await new Converter().ConvertAsync(new ConversionRequest(detected, route, temp.File_("out")));
            Assert.Equal(0, fake.Calls);
            Assert.True(File.ReadAllText(result.OutputPath).Trim().Length > 5);
        }
        finally { Ocr.Engine = null; }
    }

    [SkippableFact]
    public async Task AScannedPdfWithoutRecognitionSaysWhyItIsEmpty()
    {
        using var temp = new TempFolder();
        var scan = temp.File_("scan.pdf");
        using (var page = new MagickImage(MagickColors.White, 300, 200)) page.Write(scan, MagickFormat.Pdf);
        Ocr.Engine = null;
        var detected = new FileDetector().Detect(scan);
        var route = FormatCatalog.TargetsFor(detected).First(r => r.Id == "txt" && r.Engine == Engine.Pdf);
        var result = await new Converter().ConvertAsync(new ConversionRequest(detected, route, temp.File_("out")));
        Assert.Contains(result.Notes, n => n.Contains("needs Windows"));
    }
}

public class PdfTests
{
    [SkippableFact]
    public async Task EveryPageBecomesOneImage()
    {
        using var temp = new TempFolder();
        var src = temp.File_("three.pdf");
        using (var pages = new MagickImageCollection())
        {
            for (int i = 0; i < 3; i++) pages.Add(new MagickImage(MagickColors.White, 300, 200));
            pages.Write(src, MagickFormat.Pdf);
        }
        var detected = new FileDetector().Detect(src);
        var route = FormatCatalog.TargetsFor(detected).First(r => r.Id == "png" && r.Engine == Engine.Pdf);
        var folder = await new Converter().ConvertAsync(new ConversionRequest(detected, route, temp.File_("out")));
        Assert.True(Directory.Exists(folder.OutputPath));
        Assert.Equal(3, Directory.GetFiles(folder.OutputPath, "*.png").Length);
        var zip = await new Converter(pageOutput: PageOutput.Zip).ConvertAsync(new ConversionRequest(detected, route, temp.File_("out2")));
        Assert.EndsWith(".zip", zip.OutputPath);
        Assert.Equal(3, System.IO.Compression.ZipFile.OpenRead(zip.OutputPath).Entries.Count);
    }

    [SkippableFact]
    public async Task OnePageStaysASingleImage()
    {
        using var temp = new TempFolder();
        var detected = new FileDetector().Detect(Samples.Path_("documents/sample.pdf"));
        var route = FormatCatalog.TargetsFor(detected).First(r => r.Id == "jpg" && r.Engine == Engine.Pdf);
        var result = await new Converter().ConvertAsync(new ConversionRequest(detected, route, temp.File_("out")));
        Assert.EndsWith(".jpg", result.OutputPath);
        Assert.Equal("jpg", new FileDetector().Detect(result.OutputPath).FormatId);
    }

    [SkippableFact]
    public async Task ACorruptPdfGivesAMessageNotACrash()
    {
        using var temp = new TempFolder();
        var path = temp.File_("broken.pdf");
        File.WriteAllText(path, "%PDF-1.4\nthis is not a real pdf");
        var detected = new FileDetector().Detect(path);
        var route = FormatCatalog.TargetsFor(detected).First(r => r.Id == "txt" && r.Engine == Engine.Pdf);
        var error = await Assert.ThrowsAsync<ConversionException>(() => new Converter().ConvertAsync(new ConversionRequest(detected, route, temp.File_("out"))));
        Assert.Contains("could not be opened", error.Message);
    }
}

public class ArchiveTests
{
    private static async Task<ConversionResult> Convert(string sample, string target, string outDir)
    {
        var detected = new FileDetector().Detect(Samples.Path_(sample));
        var route = FormatCatalog.TargetsFor(detected).First(r => r.Id == target);
        return await new Converter().ConvertAsync(new ConversionRequest(detected, route, outDir));
    }

    [SkippableTheory]
    [InlineData("archives/sample.zip", "targz"), InlineData("archives/sample.zip", "tar"), InlineData("archives/sample.7z", "zip"),
     InlineData("archives/sample.tar.gz", "zip"), InlineData("archives/sample.7z", "targz")]
    public async Task ArchivesKeepTheirFilesWhenRepacked(string sample, string target)
    {
        using var temp = new TempFolder();
        var result = await Convert(sample, target, temp.Path);
        Assert.Equal(target, new FileDetector().Detect(result.OutputPath).FormatId);
        var back = new FileDetector().Detect(result.OutputPath);
        var again = FormatCatalog.TargetsFor(back).First(r => r.Id == (target == "zip" ? "tar" : "zip"));
        var second = await new Converter().ConvertAsync(new ConversionRequest(back, again, Path.Combine(temp.Path, "again")));
        Assert.Equal(again.Id, new FileDetector().Detect(second.OutputPath).FormatId);
    }

    [SkippableFact]
    public async Task SevenZipOutputUsesTheInstalledProgram()
    {
        if (!new ToolLocator().IsAvailable(Engine.SevenZip)) throw new SkipException("7-Zip is not installed");
        using var temp = new TempFolder();
        var result = await Convert("archives/sample.zip", "7z", temp.Path);
        Assert.Equal("7z", new FileDetector().Detect(result.OutputPath).FormatId);
    }

    [SkippableFact]
    public async Task AnArchiveWithALinkOutsideItDoesNotLeakTheFile()
    {
        using var temp = new TempFolder();
        var secret = temp.File_("secret.txt");
        File.WriteAllText(secret, "top secret");
        var packed = Path.Combine(temp.Path, "linked.tar");
        var staging = Directory.CreateDirectory(Path.Combine(temp.Path, "staging")).FullName;
        File.WriteAllText(Path.Combine(staging, "ok.txt"), "fine");
        // Windows lets only administrators and developer-mode users make links, so without that there is nothing to test.
        try { File.CreateSymbolicLink(Path.Combine(staging, "link.txt"), secret); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { throw new Xunit.SkipException("This account cannot create symbolic links."); }
        System.Formats.Tar.TarFile.CreateFromDirectory(staging, packed, false);
        var detected = new FileDetector().Detect(packed);
        var route = FormatCatalog.TargetsFor(detected).First(r => r.Id == "zip");
        var result = await new Converter().ConvertAsync(new ConversionRequest(detected, route, Path.Combine(temp.Path, "out")));
        using var archive = System.IO.Compression.ZipFile.OpenRead(result.OutputPath);
        Assert.DoesNotContain(archive.Entries, e => e.Name == "link.txt");
        Assert.Contains(result.Notes, n => n.Contains("symbolic link"));
    }

    [SkippableFact]
    public async Task AnEntryThatLeavesTheFolderIsRefused()
    {
        using var temp = new TempFolder();
        var path = Path.Combine(temp.Path, "evil.zip");
        using (var zip = System.IO.Compression.ZipFile.Open(path, System.IO.Compression.ZipArchiveMode.Create))
        {
            var entry = zip.CreateEntry("../escaped.txt");
            using var writer = new StreamWriter(entry.Open());
            writer.Write("x");
        }
        var detected = new FileDetector().Detect(path);
        var route = FormatCatalog.TargetsFor(detected).First(r => r.Id == "tar");
        await Assert.ThrowsAsync<ConversionException>(() => new Converter().ConvertAsync(new ConversionRequest(detected, route, Path.Combine(temp.Path, "out"))));
        Assert.False(File.Exists(Path.Combine(temp.Path, "escaped.txt")));
    }

    [SkippableFact]
    public async Task ARarFileIsReadWhenOneIsGiven()
    {
        var sample = Environment.GetEnvironmentVariable("UC_RAR_SAMPLE");
        if (sample is null || !File.Exists(sample)) throw new SkipException("Set UC_RAR_SAMPLE to a RAR file to run this test.");
        using var temp = new TempFolder();
        var detected = new FileDetector().Detect(sample);
        Assert.Equal("rar", detected.FormatId);
        var route = FormatCatalog.TargetsFor(detected).First(r => r.Id == "zip");
        var result = await new Converter().ConvertAsync(new ConversionRequest(detected, route, temp.Path));
        Assert.NotEmpty(System.IO.Compression.ZipFile.OpenRead(result.OutputPath).Entries);
    }
}

public class ProgressTests
{
    [SkippableFact]
    public async Task AVideoConversionReportsAPercentageThatRises()
    {
        var tools = new ToolLocator();
        if (tools.Locate("ffmpeg") is not { } ffmpeg) throw new SkipException("FFmpeg is not installed");
        using var temp = new TempFolder();
        var clip = temp.File_("clip.mp4");
        var made = await ProcessRunner.RunAsync(ffmpeg, ["-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc=duration=4:size=320x240:rate=25", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-y", clip]);
        Assert.Equal(0, made.ExitCode);
        var detected = new FileDetector().Detect(clip);
        var route = FormatCatalog.TargetsFor(detected).First(r => r.Id == "mkv");
        var log = new ProgressLog();
        await new Converter(progress: log.Add).ConvertAsync(new ConversionRequest(detected, route, temp.File_("out")));
        var fractions = log.All.Select(p => p.Fraction).Where(f => f is not null).Select(f => f!.Value).ToList();
        Assert.NotEmpty(fractions);
        Assert.All(fractions, f => Assert.InRange(f, 0, 1));
        Assert.True(fractions.Max() > 0.5);
    }

    [SkippableFact]
    public async Task AnUnmeasuredConversionReportsNoFraction()
    {
        using var temp = new TempFolder();
        var src = Samples.Picture(temp.Path);
        var detected = new FileDetector().Detect(src);
        var route = FormatCatalog.TargetsFor(detected).First(r => r.Id == "jpg");
        var log = new ProgressLog();
        await new Converter(progress: log.Add).ConvertAsync(new ConversionRequest(detected, route, temp.File_("out")));
        Assert.NotEmpty(log.All);
        Assert.All(log.All, p => Assert.Null(p.Fraction));
    }

    [SkippableFact]
    public async Task ARouteOfSeveralStepsOnlyMovesForward()
    {
        var tools = new ToolLocator();
        if (tools.Locate("ffmpeg") is not { } ffmpeg) throw new SkipException("FFmpeg is not installed");
        using var temp = new TempFolder();
        var tone = temp.File_("tone.wav");
        await ProcessRunner.RunAsync(ffmpeg, ["-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "sine=duration=3", "-y", tone]);
        var detected = new FileDetector().Detect(tone);
        var route = new Route([
            new RouteStep("wav", MediaCategory.Audio, new OutputFormat("flac", "FLAC", "flac", Engine.Ffmpeg), MediaCategory.Audio),
            new RouteStep("flac", MediaCategory.Audio, new OutputFormat("mp3", "MP3", "mp3", Engine.Ffmpeg), MediaCategory.Audio)]);
        var log = new ProgressLog();
        await new Converter(progress: log.Add).ConvertAsync(new ConversionRequest(detected, route, temp.File_("out")));
        var fractions = log.All.Select(p => p.Fraction).Where(f => f is not null).Select(f => f!.Value).ToList();
        Assert.True(fractions.Max() > 0.5);
        for (int i = 1; i < fractions.Count; i++) Assert.True(fractions[i - 1] <= fractions[i] + 0.001, string.Join(",", fractions));
    }

    [SkippableFact]
    public async Task CancellingStopsAProgramAndLeavesNothingBehind()
    {
        var tools = new ToolLocator();
        if (tools.Locate("ffmpeg") is not { } ffmpeg) throw new SkipException("FFmpeg is not installed");
        using var temp = new TempFolder();
        var clip = temp.File_("long.mp4");
        await ProcessRunner.RunAsync(ffmpeg, ["-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc=duration=60:size=1280x720:rate=30", "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", "-y", clip]);
        var detected = new FileDetector().Detect(clip);
        var route = FormatCatalog.TargetsFor(detected).First(r => r.Id == "webm");
        using var cancel = new CancellationTokenSource();
        var task = new Converter().ConvertAsync(new ConversionRequest(detected, route, temp.File_("out")), cancel.Token);
        await Task.Delay(1500);
        cancel.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => task);
        Assert.False(Directory.Exists(temp.File_("out")) && Directory.GetFiles(temp.File_("out")).Length > 0);
    }
}

public class ToolConversionTests
{
    private static async Task<ConversionResult?> TryConvert(string sample, string target, TempFolder temp)
    {
        var detected = new FileDetector().Detect(Samples.Path_(sample));
        var tools = new ToolLocator();
        var route = FormatCatalog.TargetsFor(detected, e => tools.IsAvailable(e)).FirstOrDefault(r => r.Id == target);
        if (route is null) return null;
        return await new Converter().ConvertAsync(new ConversionRequest(detected, route, temp.Path));
    }

    [SkippableTheory]
    [InlineData("video/sample.mp4", "webm"), InlineData("video/sample.mp4", "mp3"), InlineData("audio/sample.wav", "flac"),
     InlineData("subtitles/sample.srt", "vtt"), InlineData("documents/sample.docx", "pdf"), InlineData("markup/sample.md", "docx"),
     InlineData("fonts/sample.ttf", "woff2"), InlineData("postscript/sample.ps", "pdf")]
    public async Task AToolBackedConversionProducesTheRightFormat(string sample, string target)
    {
        using var temp = new TempFolder();
        ConversionResult? result;
        try { result = await TryConvert(sample, target, temp); }
        // A program is found but one of its parts is not set up, such as Python without the font module.
        catch (ConversionException ex) when (ex.Message.Contains("is not installed")) { throw new SkipException(ex.Message); }
        if (result is null) throw new SkipException($"The tool for {sample} to {target} is not installed");
        var found = new FileDetector().Detect(result.OutputPath);
        Assert.True(new FileInfo(result.OutputPath).Length > 0);
        Assert.Equal(target, found.FormatId);
    }

    [SkippableFact]
    public async Task ASilentVideoSaysItHasNoSound()
    {
        if (new ToolLocator().Locate("ffmpeg") is null) throw new SkipException("FFmpeg is not installed");
        using var temp = new TempFolder();
        var error = await Assert.ThrowsAsync<ConversionException>(async () => await TryConvert("video/silent.mp4", "mp3", temp));
        Assert.Contains("no sound track", error.Message);
    }

    [SkippableFact]
    public async Task APdfIsMadeSmaller()
    {
        var tools = new ToolLocator();
        if (ToolLocator.GhostscriptPath(tools) is null) throw new SkipException("Ghostscript is not installed");
        using var temp = new TempFolder();
        var big = temp.File_("big.pdf");
        using (var photo = new MagickImage("plasma:fractal", 1600, 1200)) photo.Write(big, MagickFormat.Pdf);
        var detected = new FileDetector().Detect(big);
        var route = FormatCatalog.TargetsFor(detected).First(r => r.Id == "pdf");
        var result = await new Converter().ConvertAsync(new ConversionRequest(detected, route, temp.File_("out"), new PdfCompression.High()));
        Assert.True(new FileInfo(result.OutputPath).Length < new FileInfo(big).Length);
        var custom = await new Converter().ConvertAsync(new ConversionRequest(detected, route, temp.File_("out2"), new PdfCompression.Custom(300_000)));
        Assert.True(new FileInfo(custom.OutputPath).Length <= 300_000 || custom.Notes.Any(n => n.Contains("Could not get")));
    }

    [SkippableFact]
    public async Task TwoConversionsFinishingTogetherNeverOverwriteEachOther()
    {
        using var temp = new TempFolder();
        var src = Samples.Picture(temp.Path);
        var detected = new FileDetector().Detect(src);
        var route = FormatCatalog.TargetsFor(detected).First(r => r.Id == "jpg");
        var out_ = temp.File_("out");
        var results = await Task.WhenAll(Enumerable.Range(0, 6).Select(_ => new Converter().ConvertAsync(new ConversionRequest(detected, route, out_))));
        Assert.Equal(6, results.Select(r => r.OutputPath).Distinct().Count());
        Assert.Equal(6, Directory.GetFiles(out_).Length);
    }
}
