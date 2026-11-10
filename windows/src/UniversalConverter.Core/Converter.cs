using System.Globalization;
using System.IO.Compression;
using System.Text;
using ImageMagick;

namespace UniversalConverter.Core;

public sealed record ConversionRequest(DetectedFile Input, Route Route, string OutputDirectory,
                                       PdfCompression? PdfCompression = null, ImageAdjustments? ImageAdjustments = null);

public sealed record ConversionResult(string OutputPath, Engine Engine, IReadOnlyList<string> Log,
                                      ValidationResult? Validation, IReadOnlyList<string> Notes);

/// <summary>Runs a conversion. Each engine writes into a private work folder first, and the finished file is then moved
/// into the output folder under a name that does not overwrite anything.</summary>
public sealed partial class Converter
{
    public ToolLocator Tools { get; }
    public OllamaClient Ollama { get; }
    public int RepairAttempts { get; }
    public PageOutput PageOutput { get; }
    private readonly Action<ConversionProgress> _progress;
    private readonly CodeValidator _validator;

    public const int MaxCodeBytes = 256 * 1024;
    public static readonly IReadOnlySet<string> AudioOnlyTargets = new HashSet<string> { "mp3", "wav", "flac", "m4a", "ogg" };

    public Converter(ToolLocator? tools = null, OllamaClient? ollama = null, int repairAttempts = 1,
                     PageOutput pageOutput = PageOutput.Folder, Action<ConversionProgress>? progress = null)
    {
        Tools = tools ?? new ToolLocator();
        Ollama = ollama ?? new OllamaClient(model: CodeModels.Selected);
        RepairAttempts = repairAttempts;
        PageOutput = pageOutput;
        _progress = progress ?? (_ => { });
        _validator = new CodeValidator(Tools);
    }

    /// <summary>The state of one conversion: its work folder, its log, its notes, and where to report progress.</summary>
    private sealed class Job(Action<ConversionProgress> sink, CancellationToken cancellation)
    {
        public List<string> Log { get; } = [];
        public List<string> Notes { get; } = [];
        public CancellationToken Cancellation { get; } = cancellation;
        /// <summary>Maps one step's progress into its share of the whole route.</summary>
        public int StepIndex { get; set; }
        public int StepCount { get; set; } = 1;
        public PdfCompression PdfCompression { get; init; } = new PdfCompression.Medium();
        public ImageAdjustments ImageAdjustments { get; init; } = ImageAdjustments.Unchanged;

        public void Report(string message, double? fraction = null)
        {
            if (StepCount > 1)
            {
                sink(new ConversionProgress($"Step {StepIndex + 1} of {StepCount}: {message}",
                                            fraction is double f ? (StepIndex + f) / StepCount : (double)StepIndex / StepCount));
                return;
            }
            sink(new ConversionProgress(message, fraction));
        }
    }

    /// <summary>Runs every step of the request's route in order. Each step reads the previous step's output.</summary>
    public async Task<ConversionResult> ConvertAsync(ConversionRequest request, CancellationToken cancellation = default)
    {
        var baseDir = Path.Combine(Path.GetTempPath(), "fc-work-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(baseDir);
        try
        {
            cancellation.ThrowIfCancellationRequested();
            var finalTarget = request.Route.Target;
            // Java needs the public class name to match the file name, so the name must be a legal identifier.
            var finalStem = finalTarget.Id == "java"
                ? FormatCatalog.JavaClassName(FileNames.Stem(request.Input.Path))
                : FileNames.Stem(request.Input.Path);

            var job = new Job(_progress, cancellation)
            {
                PdfCompression = request.PdfCompression ?? new PdfCompression.Medium(),
                ImageAdjustments = request.ImageAdjustments ?? ImageAdjustments.Unchanged,
                StepCount = request.Route.Steps.Count,
            };
            ValidationResult? validation = null;
            var current = request.Input;
            for (int index = 0; index < request.Route.Steps.Count; index++)
            {
                cancellation.ThrowIfCancellationRequested();
                var step = request.Route.Steps[index];
                var stepDir = Path.Combine(baseDir, $"step-{index}");
                Directory.CreateDirectory(stepDir);
                bool isLast = index == request.Route.Steps.Count - 1;
                // The file name of an intermediate result is "out.<ext>", so its stem is "out".
                var stem = isLast ? finalStem : FileNames.Stem(current.Path);
                job.StepIndex = index;
                if (job.StepCount > 1) job.Log.Add($"step {index + 1} of {job.StepCount}: {step.Output.Label}");
                job.Report("Converting…", job.StepCount > 1 ? 0 : null);

                var (produced, check) = await RunStepAsync(job, current, step.Output, stem, stepDir);
                if (isLast) validation = check;
                current = new DetectedFile(produced, step.OutputCategory, step.Output.Id, "application/octet-stream",
                                           DetectionMethod.MagicBytes, false);
            }

            // A cancelled conversion must not leave a finished file behind.
            cancellation.ThrowIfCancellationRequested();
            Directory.CreateDirectory(request.OutputDirectory);
            // A folder of pages has no extension. A ZIP file of pages keeps its own. Everything else takes the target's.
            string? ext = Directory.Exists(current.Path) ? null
                : Path.GetExtension(current.Path).Equals(".zip", StringComparison.OrdinalIgnoreCase) && finalTarget.Id != "zip" ? "zip"
                : finalTarget.FileExtension;
            var finalPath = OutputNaming.Move(current.Path, finalStem, ext, request.OutputDirectory);
            return new ConversionResult(finalPath, finalTarget.Engine, job.Log, validation, job.Notes);
        }
        finally
        {
            try { Directory.Delete(baseDir, true); } catch { /* the folder is removed later */ }
        }
    }

    /// <summary>One conversion, run by the engine the step names.</summary>
    private async Task<(string Path, ValidationResult? Check)> RunStepAsync(Job job, DetectedFile input, OutputFormat target,
                                                                              string stem, string workDir)
    {
        switch (target.Engine)
        {
            case Engine.Ffmpeg: return (await RunFfmpegAsync(job, input, target, workDir), null);
            case Engine.Image: return (await RunImageAsync(job, input, target, workDir), null);
            case Engine.Ocr: return (await RunImageTextAsync(job, input, workDir), null);
            case Engine.Pdf: return (await RunPdfAsync(job, input, target, workDir), null);
            case Engine.LibreOffice: return (await RunLibreOfficeAsync(job, input, target, workDir), null);
            case Engine.Pandoc: return (await RunPandocAsync(job, input, target, workDir), null);
            case Engine.FontTools: return (await RunFontsAsync(job, input, target, workDir), null);
            case Engine.Ghostscript:
                return (input.FormatId == "pdf"
                    ? await CompressPdfAsync(job, input, workDir)
                    : await RunGhostscriptAsync(job, input, target, workDir), null);
            case Engine.Assimp: return (await RunAssimpAsync(job, input, target, workDir), null);
            case Engine.Calibre: return (await RunCalibreAsync(job, input, target, workDir), null);
            case Engine.Archive or Engine.SevenZip: return (await RunArchiveAsync(job, input, target, workDir), null);
            case Engine.Ollama:
                var (path, check) = await RunCodeTranslationAsync(job, input, target, stem, workDir);
                return (path, check);
            default: throw ConversionException.Unsupported($"No converter is set up for {target.Label}.");
        }
    }

    // MARK: Video and audio

    public static IReadOnlyList<string> FfmpegOptions(string targetId) => targetId switch
    {
        "mp4" => ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-movflags", "+faststart"],
        "wmv" => ["-c:v", "wmv2", "-b:v", "2M", "-c:a", "wmav2"],
        "flv" => ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac"],
        "3gp" => ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-ar", "44100"],
        "mov" => ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac"],
        "avi" => ["-c:v", "mpeg4", "-q:v", "4", "-c:a", "libmp3lame"],
        "webm" => ["-c:v", "libvpx-vp9", "-crf", "32", "-b:v", "0", "-c:a", "libopus"],
        "gif" => ["-an", "-vf", "fps=12,scale=480:-1:flags=lanczos"],
        "mp3" => ["-vn", "-c:a", "libmp3lame", "-q:a", "2"],
        "wav" => ["-vn", "-c:a", "pcm_s16le"],
        "flac" => ["-vn", "-c:a", "flac"],
        "m4a" => ["-vn", "-c:a", "aac", "-b:a", "192k"],
        // Opus inside an Ogg container. Vorbis is not built into every FFmpeg.
        "ogg" => ["-vn", "-c:a", "libopus", "-b:a", "128k"],
        _ => [],
    };

    private async Task<string> RunFfmpegAsync(Job job, DetectedFile input, OutputFormat target, string workDir)
    {
        var tool = Tools.Locate("ffmpeg") ?? throw ConversionException.ToolNotFound("FFmpeg");
        // A video without an audio track has no sound to save. FFmpeg's own error for this is unclear.
        if (AudioOnlyTargets.Contains(target.Id) && input.Category == MediaCategory.Video && !await HasAudioAsync(input.Path, job.Cancellation))
            throw ConversionException.Unsupported($"{Path.GetFileName(input.Path)} has no sound track, so there is no audio to save.");
        var output = Path.Combine(workDir, "out." + target.FileExtension);
        // FFmpeg writes its progress as key=value lines. Their time, against the length, is the percentage.
        var duration = await MediaDurationAsync(input.Path, job.Cancellation);
        var args = new List<string> { "-hide_banner", "-loglevel", "error", "-nostats", "-progress", "pipe:1", "-y", "-i", input.Path };
        args.AddRange(FfmpegOptions(target.Id));
        args.Add(output);
        job.Log.Add("ffmpeg " + string.Join(' ', args));
        var result = await ProcessRunner.RunAsync(tool, args, cancellation: job.Cancellation, onOutput: line =>
        {
            if (duration is not > 0 || !line.StartsWith("out_time_us=")) return;
            if (double.TryParse(line["out_time_us=".Length..], NumberStyles.Float, CultureInfo.InvariantCulture, out var micro))
                job.Report("Converting", micro / 1_000_000 / duration.Value);
        });
        if (result.ExitCode != 0) throw ConversionException.ToolFailed("FFmpeg", result.ExitCode, LastLines(result.StdErr));
        return RequireOutput(output, "FFmpeg");
    }

    private async Task<double?> MediaDurationAsync(string path, CancellationToken cancellation)
    {
        var probe = Tools.Locate("ffprobe");
        if (probe is null) return null;
        try
        {
            var result = await ProcessRunner.RunAsync(probe, ["-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", path], cancellation: cancellation);
            return result.ExitCode == 0 && double.TryParse(result.StdOut.Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out var d) ? d : null;
        }
        catch (ConversionException) { return null; }
    }

    /// <summary>True when the file has at least one audio stream. If ffprobe is missing, returns true and lets FFmpeg report.</summary>
    private async Task<bool> HasAudioAsync(string path, CancellationToken cancellation)
    {
        var probe = Tools.Locate("ffprobe");
        if (probe is null) return true;
        var result = await ProcessRunner.RunAsync(probe, ["-v", "error", "-select_streams", "a", "-show_entries", "stream=index", "-of", "csv=p=0", path], cancellation: cancellation);
        return result.ExitCode != 0 || result.StdOut.Trim().Length > 0;
    }

    // MARK: Pictures

    private async Task<string> RunImageAsync(Job job, DetectedFile input, OutputFormat target, string workDir)
    {
        var output = Path.Combine(workDir, "out." + target.FileExtension);
        var adjustments = job.ImageAdjustments;
        job.Log.Add($"image {Path.GetFileName(input.Path)} -> {target.Id} (built-in)");
        long originalSize = new FileInfo(input.Path).Length;
        bool onlyCompressing = input.FormatId == target.Id && !adjustments.ChangesPicture && adjustments.KeepMetadata;
        string KeepOriginal(string note) { job.Notes.Add(note); File.Copy(input.Path, output); return output; }

        if (onlyCompressing)
        {
            if (adjustments.Compression == CompressionPreset.Custom && originalSize <= adjustments.CustomBytes)
                return KeepOriginal($"The file is already {FileSize.Text(adjustments.CustomBytes)} or smaller, so it was not changed.");
            if (adjustments.Compression == CompressionPreset.Original)
                return KeepOriginal("Nothing was changed, so this is an exact copy. Choose a change under Adjust.");
        }
        var path = input.Path;
        var rendered = await Task.Run(() => ImageProcessing.Render(path, target.Id, adjustments, job.Cancellation), job.Cancellation);
        job.Notes.AddRange(rendered.Notes);
        if (onlyCompressing && rendered.Data.Length >= originalSize)
            return KeepOriginal("Compression did not make this file smaller, so the original was kept.");
        await File.WriteAllBytesAsync(output, rendered.Data, job.Cancellation);
        return output;
    }

    /// <summary>The "Text (OCR)" format: the text in a picture, read by Windows.</summary>
    private async Task<string> RunImageTextAsync(Job job, DetectedFile input, string workDir)
    {
        var engine = Ocr.Engine ?? throw ConversionException.Unsupported("Reading text from pictures needs Windows 10 or 11.");
        var output = Path.Combine(workDir, "out.txt");
        job.Log.Add($"text read from {Path.GetFileName(input.Path)} with Windows text recognition");
        var path = input.Path;
        var png = await Task.Run(() => PictureForReading(path), job.Cancellation);
        var text = await engine.RecognizeAsync(png, job.Cancellation);
        job.Notes.Add(text.Trim().Length == 0 ? "No text was found in this picture." : "This text was read from the picture. Check it for mistakes.");
        await File.WriteAllTextAsync(output, text, new UTF8Encoding(false), job.Cancellation);
        return output;
    }

    /// <summary>A PNG for text recognition: rotated, on white (transparent areas would read as black) and not too large.</summary>
    internal static byte[] PictureForReading(string path)
    {
        using var image = ImageProcessing.Load(path, 8000);
        image.ColorAlpha(MagickColors.White);
        return image.ToByteArray(MagickFormat.Png);
    }

    // MARK: PDF

    private async Task<string> RunPdfAsync(Job job, DetectedFile input, OutputFormat target, string workDir)
    {
        var pdf = await File.ReadAllBytesAsync(input.Path, job.Cancellation);
        if (target.Id == "txt") return await PdfToTextAsync(job, pdf, workDir);

        // Every page becomes one picture. pdfium draws them, at 150 dpi.
        var pages = Directory.CreateDirectory(Path.Combine(workDir, "pages")).FullName;
        int count;
        try { count = PDFtoImage.Conversion.GetPageCount(pdf); }
        catch (Exception ex) { throw ConversionException.Unsupported($"This PDF could not be opened. {FirstLine(ex.Message)}"); }
        job.Log.Add($"pdfium: {count} page(s) at 150 dpi");
        await Task.Run(() =>
        {
            for (int i = 0; i < count; i++)
            {
                job.Cancellation.ThrowIfCancellationRequested();
                job.Report($"Page {i + 1} of {count}", count > 1 ? (double)i / count : null);
                var file = Path.Combine(pages, $"page-{i + 1:D3}.{target.FileExtension}");
                var options = new PDFtoImage.RenderOptions(Dpi: 150, WithAnnotations: true, BackgroundColor: SkiaSharp.SKColors.White);
                if (target.Id == "jpg") PDFtoImage.Conversion.SaveJpeg(file, pdf, i, options: options);
                else PDFtoImage.Conversion.SavePng(file, pdf, i, options: options);
            }
        }, job.Cancellation);
        return PackagePages(job, pages, target.FileExtension, workDir, "PDF");
    }

    /// <summary>The text of a PDF. A page with a text layer gives that text. A scanned page, which has no text layer,
    /// is drawn as a picture and read by Windows.</summary>
    private async Task<string> PdfToTextAsync(Job job, byte[] pdf, string workDir)
    {
        var output = Path.Combine(workDir, "out.txt");
        var pages = new List<string>();
        int scanned = 0;
        bool recognized = false;
        UglyToad.PdfPig.PdfDocument document;
        try { document = UglyToad.PdfPig.PdfDocument.Open(pdf); }
        catch (Exception ex) { throw ConversionException.Unsupported($"This PDF could not be opened. {FirstLine(ex.Message)}"); }
        using (document)
        {
            int count = document.NumberOfPages;
            for (int i = 1; i <= count; i++)
            {
                job.Cancellation.ThrowIfCancellationRequested();
                job.Report("Reading the pages", (double)(i - 1) / count);
                var layer = (UglyToad.PdfPig.DocumentLayoutAnalysis.TextExtractor.ContentOrderTextExtractor.GetText(document.GetPage(i)) ?? "").Trim();
                if (layer.Length > 0) { pages.Add(layer); continue; }
                scanned++;
                var engine = Ocr.Engine;
                if (engine is null) continue;
                var png = Path.Combine(workDir, $"scan-{i}.png");
                var index = i - 1;
                await Task.Run(() => PDFtoImage.Conversion.SavePng(png, pdf, index,
                    options: new PDFtoImage.RenderOptions(Dpi: 200, BackgroundColor: SkiaSharp.SKColors.White)), job.Cancellation);
                var text = (await engine.RecognizeAsync(await File.ReadAllBytesAsync(png, job.Cancellation), job.Cancellation)).Trim();
                File.Delete(png);
                if (text.Length > 0) { recognized = true; pages.Add(text); }
            }
        }
        await File.WriteAllTextAsync(output, string.Join("\n\n", pages), new UTF8Encoding(false), job.Cancellation);
        if (scanned > 0 && recognized)
            job.Notes.Add(pages.Count == scanned
                ? "This PDF has no text layer, so its text was read from the page images. Check it for mistakes."
                : $"{scanned} page(s) have no text layer, so their text was read from the page images. Check them for mistakes.");
        else if (scanned > 0 && Ocr.Engine is null)
            job.Notes.Add($"{scanned} page(s) are pictures with no text layer. Reading them needs Windows 10 or 11.");
        else if (scanned > 0)
            job.Notes.Add("No text was found on the scanned pages.");
        return output;
    }

    /// <summary>Makes a PDF smaller with Ghostscript. A preset runs once. A custom size tries stronger settings until the
    /// file fits. A result that is not smaller than the original is replaced by a copy of the original.</summary>
    private async Task<string> CompressPdfAsync(Job job, DetectedFile input, string workDir)
    {
        var tool = ToolLocator.GhostscriptPath(Tools) ?? throw ConversionException.ToolNotFound("Ghostscript");
        long originalSize = new FileInfo(input.Path).Length;
        var kept = Path.Combine(workDir, "out.pdf");
        string KeepOriginal() { File.Copy(input.Path, kept); return kept; }
        var compression = job.PdfCompression;

        if (compression.GoalBytes is long goalBytes && originalSize <= goalBytes)
        {
            job.Notes.Add($"The file is already {FileSize.Text(goalBytes)} or smaller, so it was not changed.");
            return KeepOriginal();
        }
        string[] baseArgs = ["-q", "-dNOPAUSE", "-dBATCH", "-dSAFER", "-sDEVICE=pdfwrite", "-dCompatibilityLevel=1.6"];
        var attempts = compression.Attempts;
        (string Path, long Size)? smallest = null;
        for (int i = 0; i < attempts.Count; i++)
        {
            job.Cancellation.ThrowIfCancellationRequested();
            // One attempt cannot be measured, so it shows a spinner.
            job.Report(attempts.Count > 1 ? $"Compressing, try {i + 1} of {attempts.Count}" : "Compressing",
                       attempts.Count > 1 ? (double)i / attempts.Count : null);
            var output = Path.Combine(workDir, $"compressed-{i}.pdf");
            await ExecuteAsync(job, "Ghostscript", tool, [.. baseArgs, .. attempts[i], "-sOutputFile=" + output, input.Path]);
            long size = File.Exists(output) ? new FileInfo(output).Length : 0;
            if (size == 0) continue;
            if (smallest is null || size < smallest.Value.Size) smallest = (output, size);
            if (compression.GoalBytes is long goal && size <= goal) break;
        }
        var best = smallest ?? throw ConversionException.OutputMissing("Ghostscript");
        if (best.Size >= originalSize)
        {
            job.Notes.Add("Compression did not make this file smaller, so the original was kept.");
            return KeepOriginal();
        }
        if (compression.GoalBytes is long target && best.Size > target)
            job.Notes.Add($"Could not get the file to {FileSize.Text(target)}. The smallest version is {FileSize.Text(best.Size)}.");
        File.Move(best.Path, kept);
        return kept;
    }

    /// <summary>PostScript and EPS to PDF, or to one image per page (Ghostscript).</summary>
    private async Task<string> RunGhostscriptAsync(Job job, DetectedFile input, OutputFormat target, string workDir)
    {
        var tool = ToolLocator.GhostscriptPath(Tools) ?? throw ConversionException.ToolNotFound("Ghostscript");
        string[] baseArgs = ["-q", "-dNOPAUSE", "-dBATCH", "-dSAFER"];
        if (target.Id == "pdf")
        {
            var output = Path.Combine(workDir, "out.pdf");
            await ExecuteAsync(job, "Ghostscript", tool, [.. baseArgs, "-sDEVICE=pdfwrite", "-sOutputFile=" + output, input.Path]);
            return RequireOutput(output, "Ghostscript");
        }
        string[] device = target.Id switch
        {
            "png" => ["-sDEVICE=png16m", "-r150"],
            "jpg" => ["-sDEVICE=jpeg", "-dJPEGQ=90", "-r150"],
            _ => throw ConversionException.Unsupported($"Ghostscript cannot write {target.Id}."),
        };
        var pages = Directory.CreateDirectory(Path.Combine(workDir, "pages")).FullName;
        await ExecuteAsync(job, "Ghostscript", tool, [.. baseArgs, .. device,
            "-sOutputFile=" + Path.Combine(pages, "page-%03d." + target.FileExtension), input.Path]);
        return PackagePages(job, pages, target.FileExtension, workDir, "Ghostscript");
    }

    /// <summary>Turns a folder of page images into the step's result. One page stays a single image. Several pages become
    /// a folder, or a ZIP file when the user chose that in Settings.</summary>
    private string PackagePages(Job job, string pages, string ext, string workDir, string tool)
    {
        var images = Directory.GetFiles(pages, "*." + ext).Order().ToList();
        if (images.Count == 0) throw ConversionException.OutputMissing(tool);
        if (images.Count == 1)
        {
            var single = Path.Combine(workDir, "out." + ext);
            File.Move(images[0], single);
            return single;
        }
        if (PageOutput == PageOutput.Zip)
        {
            var zip = Path.Combine(workDir, "out.zip");
            job.Log.Add($"{images.Count} pages, one image each, saved in a ZIP file");
            ZipFile.CreateFromDirectory(pages, zip, CompressionLevel.Optimal, false);
            return zip;
        }
        job.Log.Add($"{images.Count} pages, one image each, saved in a folder");
        return pages;
    }

    // MARK: Documents, e-books, fonts, 3D

    private async Task<string> RunLibreOfficeAsync(Job job, DetectedFile input, OutputFormat target, string workDir)
    {
        // soffice.com waits for the conversion to finish. soffice.exe can return at once.
        var tool = Tools.Locate("soffice.com", "soffice") ?? throw ConversionException.ToolNotFound("LibreOffice");
        // A private profile per run. A shared profile makes a second run fail while the first is open.
        var profile = Directory.CreateDirectory(Path.Combine(workDir, "profile")).FullName;
        var args = new List<string>
        {
            "--headless", "--norestore", "-env:UserInstallation=" + new Uri(profile + Path.DirectorySeparatorChar).AbsoluteUri.TrimEnd('/'),
            "--convert-to", target.FileExtension, "--outdir", workDir, input.Path,
        };
        // LibreOffice opens a PDF in its drawing module, which cannot save Word or OpenDocument text.
        if (input.FormatId == "pdf" && target.Id is "docx" or "odt") args.Insert(0, "--infilter=writer_pdf_import");
        job.Log.Add("soffice " + string.Join(' ', args));
        var result = await ProcessRunner.RunAsync(tool, args, cancellation: job.Cancellation);
        if (result.ExitCode != 0) throw ConversionException.ToolFailed("LibreOffice", result.ExitCode, LastLines(result.StdErr + result.StdOut));
        // LibreOffice names its output after the input file's name, which may be an intermediate "out" file.
        return RequireOutput(Path.Combine(workDir, FileNames.Stem(input.Path) + "." + target.FileExtension), "LibreOffice");
    }

    private async Task<string> RunPandocAsync(Job job, DetectedFile input, OutputFormat target, string workDir)
    {
        var tool = Tools.Locate("pandoc") ?? throw ConversionException.ToolNotFound("Pandoc");
        var from = FormatCatalog.PandocName(input.FormatId, true);
        var to = FormatCatalog.PandocName(target.Id, false);
        if (from is null || to is null) throw ConversionException.Unsupported($"Pandoc cannot convert {input.FormatId} to {target.Id}.");
        var output = Path.Combine(workDir, "out." + target.FileExtension);
        var args = new List<string> { "--from", from, "--to", to, "-o", output };
        // Without --standalone, Pandoc writes a fragment that is not a complete RTF or HTML file.
        if (to is "html" or "epub" or "rtf") args.Add("--standalone");
        args.Add(input.Path);
        job.Log.Add("pandoc " + string.Join(' ', args));
        var result = await ProcessRunner.RunAsync(tool, args, cancellation: job.Cancellation);
        if (result.ExitCode != 0) throw ConversionException.ToolFailed("Pandoc", result.ExitCode, LastLines(result.StdErr));
        return RequireOutput(output, "Pandoc");
    }

    private async Task<string> RunCalibreAsync(Job job, DetectedFile input, OutputFormat target, string workDir)
    {
        var tool = Tools.Locate("ebook-convert") ?? throw ConversionException.ToolNotFound("Calibre");
        var output = Path.Combine(workDir, "out." + target.FileExtension);
        await ExecuteAsync(job, "Calibre", tool, [input.Path, output]);
        return RequireOutput(output, "Calibre");
    }

    private async Task<string> RunFontsAsync(Job job, DetectedFile input, OutputFormat target, string workDir)
    {
        var python = ToolLocator.FontPython(Tools) ?? throw ConversionException.ToolNotFound("fontTools (install it from Tools)");
        var output = Path.Combine(workDir, "out." + target.FileExtension);
        const string script = """
            import sys
            from fontTools.ttLib import TTFont
            src, dst, target = sys.argv[1:4]
            font = TTFont(src)
            cff = 'CFF ' in font
            if target in ('woff', 'woff2'):
                font.flavor = target
            elif target == 'otf' and not cff:
                sys.exit('This font has TrueType outlines, so it cannot be saved as OTF.')
            elif target == 'ttf' and cff:
                sys.exit('This font has PostScript outlines, so it cannot be saved as TTF.')
            else:
                font.flavor = None
            font.save(dst)
            """;
        job.Log.Add($"fontTools {Path.GetFileName(input.Path)} -> {target.Id}");
        var result = await ProcessRunner.RunAsync(python, ["-c", script, input.Path, output, target.Id], cancellation: job.Cancellation);
        if (result.ExitCode != 0)
        {
            if (result.StdErr.Contains("No module named")) throw ConversionException.ToolNotFound("fontTools (install it from Tools)");
            throw ConversionException.Unsupported(LastLines(result.StdErr));
        }
        return RequireOutput(output, "fontTools");
    }

    /// <summary>Assimp's name for each 3D target.</summary>
    public static string? AssimpFormat(string targetId) => targetId switch
    {
        "obj" => "obj", "stl" => "stl", "ply" => "ply", "dae" => "collada", "gltf" => "gltf2", "glb" => "glb2", _ => null,
    };

    private async Task<string> RunAssimpAsync(Job job, DetectedFile input, OutputFormat target, string workDir)
    {
        var format = AssimpFormat(target.Id) ?? throw ConversionException.Unsupported($"Assimp cannot write {target.Id}.");
        var output = Path.Combine(workDir, "out." + target.FileExtension);
        // An installed assimp program is used if there is one. Otherwise the library that comes with the app does the work.
        if (Tools.Locate("assimp") is { } tool)
        {
            await ExecuteAsync(job, "Assimp", tool, ["export", input.Path, output, "-f" + format]);
            return RequireOutput(output, "Assimp");
        }
        job.Log.Add($"assimp (built-in) {Path.GetFileName(input.Path)} -> {format}");
        var path = input.Path;
        await Task.Run(() =>
        {
            try
            {
                using var context = new Assimp.AssimpContext();
                var scene = context.ImportFile(path, Assimp.PostProcessSteps.None);
                if (!context.ExportFile(scene, output, format))
                    throw ConversionException.Unsupported("The 3D model could not be written in this format.");
            }
            catch (Assimp.AssimpException ex) { throw ConversionException.Unsupported($"The 3D model could not be converted. {FirstLine(ex.Message)}"); }
        }, job.Cancellation);
        return RequireOutput(output, "Assimp");
    }

    // MARK: Archives

    /// <summary>Unpacks an archive into a private folder, then packs the same top-level items in the new format.</summary>
    private async Task<string> RunArchiveAsync(Job job, DetectedFile input, OutputFormat target, string workDir)
    {
        var extracted = Directory.CreateDirectory(Path.Combine(workDir, "extracted")).FullName;
        job.Log.Add($"unpacking {Path.GetFileName(input.Path)}");
        var path = input.Path;
        int skippedLinks;
        try
        {
            skippedLinks = await Task.Run(() => Archives.Extract(path, input.FormatId, extracted, job.Cancellation), job.Cancellation);
        }
        catch (Exception ex) when (ex is not OperationCanceledException and not ConversionException)
        {
            var message = ex.Message;
            if (message.Contains("password", StringComparison.OrdinalIgnoreCase) || ex is System.Security.Cryptography.CryptographicException)
                throw ConversionException.Unsupported("This archive is password-protected. Universal Converter cannot open password-protected archives yet.");
            throw ConversionException.Unsupported($"This archive could not be opened. {FirstLine(message)}");
        }
        Archives.DropLinks(extracted, job.Notes, skippedLinks);

        var items = Directory.GetFileSystemEntries(extracted).Select(Path.GetFileName).Order().ToList();
        if (items.Count == 0) throw ConversionException.Unsupported("The archive is empty, so there is nothing to convert.");

        var output = Path.Combine(workDir, "out." + target.FileExtension);
        switch (target.Id)
        {
            case "7z":
                var sevenZip = Tools.Locate("7zz", "7z") ?? throw ConversionException.ToolNotFound("7-Zip");
                job.Log.Add("7-Zip: a -t7z out.7z " + string.Join(' ', items));
                var result = await ProcessRunner.RunAsync(sevenZip, ["a", "-y", "-t7z", output, .. items!], workingDirectory: extracted, cancellation: job.Cancellation);
                if (result.ExitCode != 0) throw ConversionException.ToolFailed("7-Zip", result.ExitCode, FailureLines(result.StdErr + result.StdOut));
                break;
            default:
                await Task.Run(() => Archives.Pack(extracted, target.Id, output), job.Cancellation);
                break;
        }
        return RequireOutput(output, "Archive");
    }

    // MARK: Code

    private async Task<(string, ValidationResult)> RunCodeTranslationAsync(Job job, DetectedFile input, OutputFormat target, string stem, string workDir)
    {
        var source = FormatCatalog.CodeLanguageForId(input.FormatId);
        var destination = FormatCatalog.CodeLanguageForId(target.Id);
        if (source is null || destination is null) throw ConversionException.Unsupported("Unknown language pair.");
        long size = new FileInfo(input.Path).Length;
        if (size > MaxCodeBytes) throw ConversionException.InputTooLarge(size, MaxCodeBytes);
        var code = CodeText.Read(input.Path);

        if (!await Ollama.EnsureRunningAsync(Tools, cancellation: job.Cancellation))
            throw ConversionException.OllamaUnavailable("Could not start Ollama. Open the Ollama app or run ollama serve, then try again.");
        // Check the source first. Broken input usually gives a broken translation.
        var fileName = $"{stem}.{target.FileExtension}";
        var sourceCheck = await _validator.ValidateAsync(code, source, Path.GetFileName(input.Path), workDir, job.Cancellation);
        job.Log.Add("source syntax check: " + sourceCheck.Summary);

        job.Log.Add($"ollama generate model={Ollama.Model} {source.Id}->{destination.Id}");
        string translated;
        if (Encoding.UTF8.GetByteCount(code) <= CodeChunker.WholeFileBytes)
        {
            translated = await GenerateCodeAsync(CodePrompt.Make(source, destination, code, stem), job.Cancellation);
        }
        else
        {
            // A Java class is cut between its members. Any other long file is cut at its top-level definitions.
            var javaClass = source.Id == "java" ? CodeChunker.SplitJavaClass(code) : null;
            var pieces = javaClass?.Parts ?? CodeChunker.Split(code);
            job.Log.Add($"long file: translating {pieces.Count} parts, then joining them");
            var translatedParts = new List<string>();
            for (int i = 0; i < pieces.Count; i++)
            {
                job.Cancellation.ThrowIfCancellationRequested();
                job.Report($"Translating part {i + 1} of {pieces.Count}", (double)i / pieces.Count);
                var prompt = javaClass is not null
                    ? CodePrompt.Members(source, destination, pieces[i], javaClass.ClassName, javaClass.Header, i + 1, pieces.Count)
                    : CodePrompt.Part(source, destination, pieces[i], stem, i + 1, pieces.Count);
                translatedParts.Add(await GenerateCodeAsync(prompt, job.Cancellation));
            }
            if (destination.Id == "java")
            {
                // A class in the source stays a class of its own. Any other class is one the model added around a part.
                translated = CodeChunker.JoinJavaClass(translatedParts, stem, CodeChunker.TypeNames(code));
                job.Log.Add($"Java: the parts are joined into one class named {stem}");
            }
            else translated = CodeChunker.Join(translatedParts);
            if (javaClass is not null)
                job.Notes.Add($"This long Java class was translated member by member, so {javaClass.ClassName} is now top-level functions and variables, not a class. Check how they fit together.");
        }
        job.Report("Checking the code");
        var check = await _validator.ValidateAsync(translated, destination, fileName, workDir, job.Cancellation);

        // One repair attempt: send the checker's own error messages back to the model.
        if (check is ValidationResult.Failed failed && RepairAttempts > 0)
        {
            job.Log.Add("syntax check failed:");
            job.Log.AddRange(failed.Messages.Select(m => "  " + m));
            if (Encoding.UTF8.GetByteCount(translated) > CodeChunker.RepairBytes)
                job.Log.Add("the file is too large for one repair request, so it is saved with the errors listed");
            else
            {
                job.Log.Add("asking the model to repair the code");
                job.Report("Repairing the code");
                translated = await GenerateCodeAsync(CodePrompt.Repair(destination, translated, failed.Messages, stem), job.Cancellation);
                check = await _validator.ValidateAsync(translated, destination, fileName, workDir, job.Cancellation);
            }
        }
        job.Log.Add("syntax check: " + check.Summary);
        var output = Path.Combine(workDir, "out." + target.FileExtension);
        await File.WriteAllTextAsync(output, translated, new UTF8Encoding(false), job.Cancellation);
        return (output, check);
    }

    /// <summary>Runs the model and cleans its reply. Throws when the reply contains no code.</summary>
    private async Task<string> GenerateCodeAsync(string prompt, CancellationToken cancellation)
    {
        var text = CodeOutputCleaner.Clean(await Ollama.GenerateAsync(prompt, cancellation));
        return text.Length > 0 ? text : throw ConversionException.Unsupported("The model returned no code. Try again.");
    }

    // MARK: Helpers

    private async Task ExecuteAsync(Job job, string tool, string executable, IEnumerable<string> arguments, string? cwd = null)
    {
        var args = arguments.ToList();
        job.Log.Add($"{Path.GetFileName(executable)} {string.Join(' ', args)}");
        var result = await ProcessRunner.RunAsync(executable, args, workingDirectory: cwd, cancellation: job.Cancellation);
        if (result.ExitCode != 0) throw ConversionException.ToolFailed(tool, result.ExitCode, FailureLines(result.StdErr + result.StdOut));
    }

    private static string RequireOutput(string path, string tool) =>
        File.Exists(path) || Directory.Exists(path) ? path : throw ConversionException.OutputMissing(tool);

    private static string FirstLine(string text) => text.Split('\n')[0].Trim();

    /// <summary>The lines that say what went wrong. 7-Zip marks them with "ERROR:". Otherwise, the last lines of the output.</summary>
    public static string FailureLines(string text)
    {
        var errors = text.Split('\n').Select(l => l.Trim()).Where(l => l.StartsWith("ERROR")).ToList();
        return errors.Count == 0 ? LastLines(text) : string.Join('\n', errors.Take(3));
    }

    /// <summary>The last few meaningful lines of a tool's log, for error messages.</summary>
    public static string LastLines(string text, int count = 6) =>
        string.Join('\n', text.Split('\n').Select(l => l.Trim()).Where(l => l.Length > 0).TakeLast(count));

    /// <summary>Deletes work folders that an earlier run left behind. Only folders older than a day go.</summary>
    public static void RemoveStaleWork(TimeSpan? olderThan = null)
    {
        var age = olderThan ?? TimeSpan.FromDays(1);
        try
        {
            foreach (var dir in Directory.GetDirectories(Path.GetTempPath(), "fc-work-*"))
                if (DateTime.UtcNow - Directory.GetLastWriteTimeUtc(dir) > age) try { Directory.Delete(dir, true); } catch { }
        }
        catch { /* the temp folder could not be read */ }
    }
}

public static class CodeText
{
    /// <summary>Reads a source file as text. UTF-8 with or without a byte order mark; anything else is read as Windows-1252.</summary>
    public static string Read(string path)
    {
        var bytes = File.ReadAllBytes(path);
        try { return new UTF8Encoding(false, true).GetString(bytes).TrimStart('﻿').Replace("\r\n", "\n"); }
        catch (DecoderFallbackException) { return Encoding.Latin1.GetString(bytes).Replace("\r\n", "\n"); }
    }
}

public static class OutputNaming
{
    /// <summary>A name that does not exist yet. A null extension gives a bare name, which is used for folders.</summary>
    public static string UniquePath(string stem, string? ext, string directory)
    {
        string Name(string b) => ext is null ? b : $"{b}.{ext}";
        var candidate = Path.Combine(directory, Name(stem));
        int counter = 2;
        while (File.Exists(candidate) || Directory.Exists(candidate))
            candidate = Path.Combine(directory, Name($"{stem} ({counter++})"));
        return candidate;
    }

    /// <summary>Moves a result into place under a name nobody else has taken. Two conversions that finish together can pick
    /// the same name, so a name that turns out to be taken is replaced by the next free one.</summary>
    public static string Move(string source, string stem, string? ext, string directory)
    {
        Exception? last = null;
        for (int i = 0; i < 100; i++)
        {
            // Choosing a name and taking it happen under one lock. Windows refuses to overwrite by itself, but not every
            // system checks and moves in one step.
            lock (MoveGate)
            {
                var destination = UniquePath(stem, ext, directory);
                try
                {
                    if (Directory.Exists(source)) Directory.Move(source, destination);
                    else File.Move(source, destination, overwrite: false);
                    return destination;
                }
                catch (IOException ex) when (File.Exists(destination) || Directory.Exists(destination)) { last = ex; }
            }
        }
        throw last ?? new IOException("The result could not be saved.");
    }

    private static readonly object MoveGate = new();
}
