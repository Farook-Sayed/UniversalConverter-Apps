using System.Globalization;
using System.Text;
using ImageMagick;
using UglyToad.PdfPig;
using UglyToad.PdfPig.Core;
using UglyToad.PdfPig.Writer;

namespace UniversalConverter.Core;

/// <summary>What can be merged into one file.</summary>
public enum MergeKind
{
    /// <summary>Pictures and PDFs become the pages of one PDF.</summary>
    Pdf,
    /// <summary>Audio files are played one after another in one audio file.</summary>
    Audio,
    /// <summary>Videos are joined into one video.</summary>
    Video,
    /// <summary>Text documents (Markdown, text, HTML, Word, OpenDocument, RTF) become one document.</summary>
    Document,
}

/// <summary>The page size of the PDF when pictures are merged into it. PDFs that are merged keep their own pages.</summary>
public enum MergePageSize { A4, Letter, FitPicture }

public static class MergePageSizeExtensions
{
    public static string Title(this MergePageSize size) => size switch
    {
        MergePageSize.A4 => "A4 pages",
        MergePageSize.Letter => "US Letter pages",
        _ => "Same size as each picture",
    };

    /// <summary>The page for a picture of this many pixels, in points. A4 and Letter turn to fit a picture that is wider than tall.</summary>
    public static (double Width, double Height) PageFor(this MergePageSize size, int width, int height)
    {
        if (size == MergePageSize.FitPicture)
        {
            // 150 pixels to the inch is sharp on paper and keeps the page a sensible size. A PDF page cannot be larger than 200 inches.
            const double scale = 72.0 / 150.0;
            return (Math.Clamp(width * scale, 36, 14_400), Math.Clamp(height * scale, 36, 14_400));
        }
        var (w, h) = size == MergePageSize.A4 ? (595.28, 841.89) : (612.0, 792.0);
        return width > height ? (h, w) : (w, h);
    }

    /// <summary>The space left around the picture. Pictures that set their own page size fill it.</summary>
    public static double Margin(this MergePageSize size) => size == MergePageSize.FitPicture ? 0 : 18;
}

/// <summary>A set of files that can become one file, and what they can become.</summary>
public sealed record MergeGroup(MergeKind Kind, IReadOnlyList<DetectedFile> Files, IReadOnlyList<OutputFormat> Targets)
{
    /// <summary>The tool the merge needs, or null when it needs nothing to install.</summary>
    public Engine? Engine
    {
        get
        {
            var engine = Targets.FirstOrDefault()?.Engine;
            return engine is UniversalConverter.Core.Engine.Pdf or UniversalConverter.Core.Engine.Image ? null : engine;
        }
    }

    /// <summary>A plain description, such as "3 pictures and 2 PDFs into one PDF".</summary>
    public string Title
    {
        get
        {
            static string Count(int n, string one, string many) => $"{n} {(n == 1 ? one : many)}";
            switch (Kind)
            {
                case MergeKind.Pdf:
                    int pdfs = Files.Count(f => f.FormatId == "pdf"), pictures = Files.Count - pdfs;
                    if (pdfs == 0) return $"{Count(pictures, "picture", "pictures")} into one PDF";
                    if (pictures == 0) return $"{Count(pdfs, "PDF", "PDFs")} into one PDF";
                    return $"{Count(pictures, "picture", "pictures")} and {Count(pdfs, "PDF", "PDFs")} into one PDF";
                case MergeKind.Audio: return $"{Count(Files.Count, "audio file", "audio files")} into one";
                case MergeKind.Video: return $"{Count(Files.Count, "video", "videos")} into one";
                default: return $"{Count(Files.Count, "document", "documents")} into one";
            }
        }
    }

    public string Name => Kind switch { MergeKind.Pdf => "PDF", MergeKind.Audio => "Audio", MergeKind.Video => "Video", _ => "Document" };
}

/// <summary>Finds what can be merged among the files in the queue.</summary>
public static class MergePlanner
{
    public static readonly IReadOnlySet<string> DocumentFormats = new HashSet<string> { "md", "txt", "html", "docx", "odt", "rtf" };
    public static readonly string[] AudioTargets = ["mp3", "wav", "flac", "m4a", "ogg"];
    public static readonly string[] VideoTargets = ["mp4", "mkv", "webm", "mov"];
    public static readonly string[] DocumentTargets = ["docx", "md", "txt", "html", "rtf", "epub"];

    /// <summary>Every merge the files allow. A kind needs at least two files.</summary>
    public static List<MergeGroup> GroupsFor(IEnumerable<DetectedFile> files)
    {
        var all = files.ToList();
        var groups = new List<MergeGroup>();
        // PDF first: pictures and PDFs can be mixed. SVG is left out, because the picture library draws it with no fonts.
        var pdfFiles = all.Where(f => f.FormatId == "pdf" || f.Category == MediaCategory.Image).ToList();
        if (pdfFiles.Count >= 2) groups.Add(new(MergeKind.Pdf, pdfFiles, [Target("pdf", Engine.Pdf)]));
        var audio = all.Where(f => f.Category == MediaCategory.Audio).ToList();
        if (audio.Count >= 2) groups.Add(new(MergeKind.Audio, audio, AudioTargets.Select(t => Target(t, Engine.Ffmpeg)).ToList()));
        var video = all.Where(f => f.Category == MediaCategory.Video).ToList();
        if (video.Count >= 2) groups.Add(new(MergeKind.Video, video, VideoTargets.Select(t => Target(t, Engine.Ffmpeg)).ToList()));
        var documents = all.Where(f => DocumentFormats.Contains(f.FormatId) && f.Category != MediaCategory.Code).ToList();
        if (documents.Count >= 2) groups.Add(new(MergeKind.Document, documents, DocumentTargets.Select(t => Target(t, Engine.Pandoc)).ToList()));
        return groups;
    }

    private static OutputFormat Target(string id, Engine engine) =>
        new(id, FormatCatalog.DisplayName(id) ?? id.ToUpperInvariant(), id, engine);

    /// <summary>The format a merge of these files suggests: the one the first file already has, when it is on offer.</summary>
    public static OutputFormat? SuggestedTarget(MergeGroup group) =>
        group.Targets.FirstOrDefault(t => t.Id == group.Files.FirstOrDefault()?.FormatId) ?? group.Targets.FirstOrDefault();
}

/// <summary>One merge: the files in the order they are joined, and what they become.</summary>
public sealed record MergeRequest(MergeKind Kind, IReadOnlyList<DetectedFile> Inputs, OutputFormat Target, string OutputDirectory,
                                  string Name = "Merged", MergePageSize PageSize = MergePageSize.A4);

public sealed partial class Converter
{
    /// <summary>Joins the files of the request into one file, in the order given.</summary>
    public async Task<ConversionResult> MergeAsync(MergeRequest request, CancellationToken cancellation = default)
    {
        if (request.Inputs.Count < 2) throw ConversionException.Unsupported("Choose at least two files to merge.");
        var work = Path.Combine(Path.GetTempPath(), "fc-work-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(work);
        try
        {
            cancellation.ThrowIfCancellationRequested();
            var job = new Job(_progress, cancellation);
            var produced = request.Kind switch
            {
                MergeKind.Pdf => await MergePdfAsync(job, request, work),
                MergeKind.Audio or MergeKind.Video => await MergeMediaAsync(job, request, work),
                _ => await MergeDocumentsAsync(job, request, work),
            };
            cancellation.ThrowIfCancellationRequested();
            Directory.CreateDirectory(request.OutputDirectory);
            var final = OutputNaming.Move(produced, SafeName(request.Name), request.Target.FileExtension, request.OutputDirectory);
            return new ConversionResult(final, request.Target.Engine, job.Log, null, job.Notes);
        }
        finally
        {
            try { Directory.Delete(work, true); } catch { /* the folder is removed later */ }
        }
    }

    /// <summary>A file name with nothing in it that could point to another folder.</summary>
    internal static string SafeName(string name)
    {
        var cleaned = new string(name.Select(c => c is '/' or '\\' or ':' or '\0' or '*' or '?' or '"' or '<' or '>' or '|' ? '-' : c).ToArray()).Trim();
        return cleaned.Length == 0 || cleaned is "." or ".." ? "Merged" : cleaned;
    }

    // MARK: PDF

    private async Task<string> MergePdfAsync(Job job, MergeRequest request, string work)
    {
        var output = Path.Combine(work, "merged.pdf");
        int pages = await Task.Run(() => PdfMerger.Merge(request.Inputs, request.PageSize, output, index =>
            job.Report($"Adding {index + 1} of {request.Inputs.Count}", (double)index / request.Inputs.Count), job.Cancellation), job.Cancellation);
        job.Log.Add($"merged {request.Inputs.Count} files into {pages} page(s)");
        return output;
    }

    // MARK: Audio and video

    private async Task<string> MergeMediaAsync(Job job, MergeRequest request, string work)
    {
        var tool = Tools.Locate("ffmpeg") ?? throw ConversionException.ToolNotFound("FFmpeg");
        bool isVideo = request.Kind == MergeKind.Video;
        var durations = new List<double>();
        var withAudio = new List<bool>();
        foreach (var file in request.Inputs)
        {
            job.Cancellation.ThrowIfCancellationRequested();
            durations.Add(await MediaDurationAsync(file.Path, job.Cancellation)
                          ?? throw ConversionException.Unsupported($"{Path.GetFileName(file.Path)} could not be read, so it cannot be merged."));
            withAudio.Add(await HasAudioAsync(file.Path, job.Cancellation));
        }
        if (!isVideo && withAudio.IndexOf(false) is int silent and >= 0)
            throw ConversionException.Unsupported($"{Path.GetFileName(request.Inputs[silent].Path)} has no sound track, so there is no audio to merge.");
        bool keepAudio = withAudio.All(a => a);
        if (isVideo && !keepAudio) job.Notes.Add("At least one video has no sound track, so the merged video has no sound.");
        var first = isVideo ? await VideoStreamAsync(request.Inputs[0].Path, job.Cancellation) : null;
        var output = Path.Combine(work, "merged." + request.Target.FileExtension);
        var arguments = FfmpegMerge.Arguments(request.Inputs.Select(i => i.Path).ToList(), request.Target.Id, isVideo, first?.Width, first?.Height,
                                              first?.FrameRate, keepAudio, output, ResourcePlan.ThreadsPerConversion());
        double total = durations.Sum();
        job.Log.Add("ffmpeg " + string.Join(' ', arguments));
        var result = await ProcessRunner.RunAsync(tool, arguments, cancellation: job.Cancellation, onOutput: line =>
        {
            if (total <= 0 || !line.StartsWith("out_time_us=")) return;
            if (double.TryParse(line["out_time_us=".Length..], NumberStyles.Float, CultureInfo.InvariantCulture, out var micro))
                job.Report("Joining", micro / 1_000_000 / total);
        });
        if (result.ExitCode != 0) throw ConversionException.ToolFailed("FFmpeg", result.ExitCode, LastLines(result.StdErr));
        return RequireOutput(output, "FFmpeg");
    }

    /// <summary>The size and frame rate of a video's first picture stream.</summary>
    private async Task<(int Width, int Height, double? FrameRate)?> VideoStreamAsync(string path, CancellationToken cancellation)
    {
        var probe = Tools.Locate("ffprobe");
        if (probe is null) return null;
        try
        {
            var result = await ProcessRunner.RunAsync(probe, ["-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height,avg_frame_rate", "-of", "csv=p=0", path], cancellation: cancellation);
            if (result.ExitCode != 0) return null;
            var parts = result.StdOut.Trim().Split(',');
            if (parts.Length < 2 || !int.TryParse(parts[0], out var w) || !int.TryParse(parts[1], out var h)) return null;
            double? rate = null;
            if (parts.Length >= 3)
            {
                var fraction = parts[2].Split('/').Select(p => double.TryParse(p, NumberStyles.Float, CultureInfo.InvariantCulture, out var d) ? d : (double?)null).ToList();
                if (fraction.Count == 2 && fraction[0] is double a && fraction[1] is double b && b > 0) rate = a / b;
                else if (fraction.Count == 1 && fraction[0] is double single) rate = single;
            }
            return (w, h, rate is > 1 and < 240 ? rate : null);
        }
        catch (ConversionException) { return null; }
    }

    // MARK: Documents

    private async Task<string> MergeDocumentsAsync(Job job, MergeRequest request, string work)
    {
        var pandoc = Tools.Locate("pandoc") ?? throw ConversionException.ToolNotFound("Pandoc");
        var to = FormatCatalog.PandocName(request.Target.Id, false)
                 ?? throw ConversionException.Unsupported($"Pandoc cannot write {request.Target.Id}.");
        var names = request.Inputs.Select(f => FormatCatalog.PandocName(f.FormatId, true)
            ?? throw ConversionException.Unsupported($"{Path.GetFileName(f.Path)} cannot be merged as a document.")).ToList();
        List<string> sources = request.Inputs.Select(f => f.Path).ToList();
        string from;
        if (names.Distinct().Count() == 1) from = names[0];
        else
        {
            // Pandoc reads one kind of file per run, so each file is first turned into Markdown and those are joined.
            from = "markdown";
            sources = [];
            for (int i = 0; i < request.Inputs.Count; i++)
            {
                job.Cancellation.ThrowIfCancellationRequested();
                job.Report($"Reading {i + 1} of {request.Inputs.Count}", (double)i / request.Inputs.Count);
                var part = Path.Combine(work, $"part-{i}.md");
                await ExecuteAsync(job, "Pandoc", pandoc, ["--from", names[i], "--to", "markdown", "--wrap=none", "-o", part, request.Inputs[i].Path]);
                sources.Add(part);
            }
            job.Notes.Add("The files were different kinds, so they were joined as Markdown. Some layout may be lost.");
        }
        var output = Path.Combine(work, "merged." + request.Target.FileExtension);
        var arguments = new List<string> { "--from", from, "--to", to, "-o", output };
        if (to is "html" or "epub" or "rtf") arguments.Add("--standalone");
        arguments.AddRange(sources);
        job.Report("Joining");
        await ExecuteAsync(job, "Pandoc", pandoc, arguments);
        return RequireOutput(output, "Pandoc");
    }
}

/// <summary>Joins pictures and PDFs into one PDF with PdfPig and Magick.NET, which are part of the app.</summary>
public static class PdfMerger
{
    /// <summary>Writes the merged PDF and returns how many pages it has. <paramref name="progress"/> is told which file (from 0) is next.</summary>
    public static int Merge(IReadOnlyList<DetectedFile> inputs, MergePageSize pageSize, string output, Action<int> progress, CancellationToken cancellation)
    {
        var builder = new PdfDocumentBuilder();
        var open = new List<PdfDocument>();
        try
        {
            for (int index = 0; index < inputs.Count; index++)
            {
                cancellation.ThrowIfCancellationRequested();
                progress(index);
                var file = inputs[index];
                var name = Path.GetFileName(file.Path);
                if (file.FormatId == "pdf")
                {
                    PdfDocument source;
                    try { source = PdfDocument.Open(file.Path); open.Add(source); }
                    catch (UglyToad.PdfPig.Exceptions.PdfDocumentEncryptedException)
                    {
                        throw ConversionException.Unsupported($"{name} is password-protected. Enter its password in the file list first, then merge it.");
                    }
                    catch (Exception ex) when (ex is not ConversionException)
                    {
                        throw ConversionException.Unsupported($"{name} could not be opened as a PDF.");
                    }
                    for (int number = 1; number <= source.NumberOfPages; number++) builder.AddPage(source, number);
                }
                else AddPicture(builder, file, pageSize, name);
            }
            var bytes = builder.Build();
            if (builder.Pages.Count == 0) throw ConversionException.Unsupported("There was nothing to merge: the files have no pages.");
            File.WriteAllBytes(output, bytes);
            return builder.Pages.Count;
        }
        finally
        {
            foreach (var document in open) document.Dispose();
        }
    }

    /// <summary>One PDF page holding one picture. The picture goes in as a JPEG on white, which keeps the file small.</summary>
    private static void AddPicture(PdfDocumentBuilder builder, DetectedFile file, MergePageSize pageSize, string name)
    {
        byte[] jpeg;
        int width, height;
        try
        {
            using var image = ImageProcessing.Load(file.Path);
            image.ColorAlpha(MagickColors.White);
            width = (int)image.Width;
            height = (int)image.Height;
            image.Quality = 90;
            jpeg = image.ToByteArray(MagickFormat.Jpeg);
        }
        catch (Exception ex) when (ex is MagickException or ConversionException)
        {
            throw ConversionException.Unsupported($"{name} could not be read as a picture, so it cannot be merged.");
        }
        var (pageWidth, pageHeight) = pageSize.PageFor(width, height);
        var page = builder.AddPage(pageWidth, pageHeight);
        // The picture is as large as fits inside the margins, in its own proportions, in the middle of the page.
        double margin = pageSize.Margin();
        double roomWidth = pageWidth - 2 * margin, roomHeight = pageHeight - 2 * margin;
        double scale = Math.Min(roomWidth / width, roomHeight / height);
        double w = width * scale, h = height * scale;
        double x = (pageWidth - w) / 2, y = (pageHeight - h) / 2;
        page.AddJpeg(jpeg, new PdfRectangle(x, y, x + w, y + h));
    }
}

/// <summary>The FFmpeg command that joins audio or video files. It is built apart from running it, so it can be tested.</summary>
public static class FfmpegMerge
{
    /// <summary>Every file is first made alike (the same sample rate and channels, and for video the same size and frame rate), because
    /// FFmpeg's join needs inputs that match. Video is scaled to fit the first video and padded with black.</summary>
    public static List<string> Arguments(IReadOnlyList<string> inputs, string targetId, bool isVideo, int? width, int? height, double? frameRate,
                                         bool keepAudio, string output, int threads)
    {
        var arguments = new List<string> { "-hide_banner", "-loglevel", "error", "-nostats", "-progress", "pipe:1", "-y" };
        foreach (var input in inputs) arguments.AddRange(["-i", input]);

        // Sizes must be even for most video encoders.
        int w = Math.Max(2, (width ?? 1280) / 2 * 2), h = Math.Max(2, (height ?? 720) / 2 * 2);
        var fps = frameRate is double r ? (Math.Round(r * 1000) / 1000).ToString("0.###", CultureInfo.InvariantCulture) : "30";
        var filters = new List<string>();
        var joined = new StringBuilder();
        for (int i = 0; i < inputs.Count; i++)
        {
            if (isVideo)
            {
                filters.Add($"[{i}:v:0]scale={w}:{h}:force_original_aspect_ratio=decrease,pad={w}:{h}:(ow-iw)/2:(oh-ih)/2,setsar=1,fps={fps},format=yuv420p[v{i}]");
                joined.Append($"[v{i}]");
            }
            if (keepAudio)
            {
                filters.Add($"[{i}:a:0]aresample=44100,aformat=sample_fmts=fltp:channel_layouts=stereo[a{i}]");
                joined.Append($"[a{i}]");
            }
        }
        var outputs = (isVideo ? "[v]" : "") + (keepAudio ? "[a]" : "");
        filters.Add($"{joined}concat=n={inputs.Count}:v={(isVideo ? 1 : 0)}:a={(keepAudio ? 1 : 0)}{outputs}");
        arguments.AddRange(["-filter_complex", string.Join(';', filters)]);
        if (isVideo) arguments.AddRange(["-map", "[v]"]);
        if (keepAudio) arguments.AddRange(["-map", "[a]"]);
        arguments.AddRange(Converter.FfmpegOptions(targetId));
        arguments.AddRange(["-threads", threads.ToString(CultureInfo.InvariantCulture), output]);
        return arguments;
    }
}
