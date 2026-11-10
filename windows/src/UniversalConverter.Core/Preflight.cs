namespace UniversalConverter.Core;

public enum Severity { Info, Caution, Blocking }

/// <summary>Something the user should know before or after a conversion.</summary>
public sealed record Finding(Severity Severity, string Message);

/// <summary>Checks made before a conversion starts. Each rule is a small pure function so it can be tested.</summary>
public static class Preflight
{
    /// <summary>Files at or above this size get a note that the conversion will take a while.</summary>
    public const long LargeFileBytes = 500L * 1024 * 1024;

    public static List<Finding> FindingsFor(DetectedFile file, Route target, string outputFolder, ToolLocator tools)
    {
        var result = new List<Finding>();
        long size = SizeOf(file.Path);
        if (size == 0) result.Add(new(Severity.Blocking, $"{Path.GetFileName(file.Path)} is empty, so there is nothing to convert."));
        if (file.ExtensionMismatch)
        {
            var ext = Path.GetExtension(file.Path).TrimStart('.');
            var name = ext.Length == 0 ? "The file name" : $"The name ends in .{ext}";
            result.Add(new(Severity.Caution, $"{name}, but the file is really {file.FormatId.ToUpperInvariant()}. The contents were used."));
        }
        // Every tool the route uses must be installed, not only the last one.
        foreach (var step in target.Steps)
            if (MissingToolFinding(step.Output, file, tools) is { } missing) result.Add(missing);
        if (target.IsMultiStep)
        {
            var path = string.Join(" → ", new[] { file.FormatId.ToUpperInvariant() }.Concat(target.Steps.Select(s => s.Output.FileExtension.ToUpperInvariant())));
            result.Add(new(Severity.Info, $"This takes {target.Steps.Count} steps, each with its own tool: {path}. Quality can drop a little at each step."));
        }
        if (!CanWrite(outputFolder))
            result.Add(new(Severity.Blocking, $"Universal Converter cannot write to {Path.GetFileName(outputFolder.TrimEnd(Path.DirectorySeparatorChar))}. Choose another output folder in Settings."));
        if (SpaceFinding(size, FreeBytes(outputFolder)) is { } space) result.Add(space);
        if (SizeFinding(size) is { } large) result.Add(large);
        if (LossyNote(file.Category, file.FormatId, target.Id) is { } lossy) result.Add(new(Severity.Caution, lossy));
        if (file.Category == MediaCategory.Code && CheckerName(target.Id) is { } checker && tools.Locate(CheckerBinaries(target.Id)) is null)
            result.Add(new(Severity.Info, $"{checker} is not installed, so the translated code will not be syntax-checked."));
        // Two steps can need the same tool, and each would add the same message.
        return result.DistinctBy(f => f.Message).ToList();
    }

    /// <summary>Lost quality or detail when converting this source to this target. Null when nothing is lost.</summary>
    public static string? LossyNote(MediaCategory sourceCategory, string sourceId, string targetId)
    {
        string[] lossyAudio = ["mp3", "m4a", "ogg"];
        string[] lossyVideo = ["mp4", "mkv", "webm", "avi", "mov", "wmv", "flv", "3gp", "m2ts", "mpg", "vob"];
        if ((sourceCategory == MediaCategory.Ebook || sourceId == "epub") && targetId is "pdf" or "txt")
            return "Reflowable e-books lose their layout when saved as PDF or plain text.";
        if ((sourceId == "pdf" || sourceCategory == MediaCategory.Postscript) && targetId is "png" or "jpg")
            return "Each page is saved as its own image. Several pages go into a folder, or a ZIP file if Settings says so.";
        if (targetId == "gif" && sourceCategory == MediaCategory.Video) return "GIF has no sound and only 256 colours, so expect lower quality.";
        if (lossyAudio.Contains(sourceId) && lossyAudio.Contains(targetId)) return "Converting between lossy audio formats loses a little quality each time.";
        if (lossyVideo.Contains(sourceId) && targetId is "mp4" or "webm" && sourceId != targetId) return "Video is re-encoded, which takes time and can lower quality slightly.";
        if (sourceCategory is MediaCategory.Image or MediaCategory.Vector)
        {
            string[] transparent = ["png", "gif", "webp", "tiff", "svg", "avif", "heic"];
            if (targetId == "jpg" && (transparent.Contains(sourceId) || sourceCategory == MediaCategory.Vector)) return "JPEG has no transparency, so transparent areas become solid.";
            if (targetId == "gif" && sourceId != "gif") return "GIF is limited to 256 colours, so photos and gradients will look banded.";
        }
        if (sourceCategory == MediaCategory.Document && targetId == "md") return "Markdown keeps the text and basic structure, but loses layout, images and styling.";
        if (sourceCategory == MediaCategory.Markup && targetId == "pdf") return "The PDF layout comes from the converter and can differ from a web browser.";
        if (sourceCategory == MediaCategory.Spreadsheet && targetId == "csv") return "CSV keeps only the first sheet and drops all formatting and formulas.";
        if (sourceCategory == MediaCategory.Subtitle && targetId == "srt" && sourceId == "ass") return "Subtitle styling and positioning are removed when saving as SRT.";
        if (sourceCategory == MediaCategory.Markup && sourceId == "ipynb" && targetId == "md") return "Notebook outputs such as plots and tables are left out of the Markdown.";
        if (sourceCategory == MediaCategory.Code) return "The translation is checked for syntax only. Test the result before you rely on it.";
        return null;
    }

    /// <summary>A blocking finding when the tool that performs this conversion is not installed.</summary>
    public static Finding? MissingToolFinding(OutputFormat target, DetectedFile file, ToolLocator tools)
    {
        string? Need(string name, string where) => $"{name} is not installed. Install it from Tools in the app{where}.";
        var message = target.Engine switch
        {
            Engine.Ffmpeg => tools.Locate("ffmpeg") is null ? Need("FFmpeg", "") : null,
            Engine.LibreOffice => tools.Locate("soffice") is null ? Need("LibreOffice", "") : null,
            Engine.Pandoc => tools.Locate("pandoc") is null ? Need("Pandoc", "") : null,
            Engine.Calibre => tools.Locate("ebook-convert") is null ? Need("Calibre", "") : null,
            Engine.Ghostscript => ToolLocator.GhostscriptPath(tools) is null ? Need("Ghostscript", "") : null,
            Engine.SevenZip => tools.Locate("7zz", "7z") is null ? Need("7-Zip", "") : null,
            Engine.Ollama => tools.Locate("ollama") is null ? Need("Ollama", " (Code translation)") : null,
            Engine.FontTools => ToolLocator.FontPython(tools) is null ? "fontTools is not set up. Install it from Tools (Fonts)." : null,
            Engine.Ocr => ToolLocator.OcrAvailable ? null : "Reading text from pictures needs Windows 10 or 11.",
            _ => null,
        };
        return message is null ? null : new Finding(Severity.Blocking, message);
    }

    public static Finding? SpaceFinding(long fileSize, long? freeBytes)
    {
        if (freeBytes is not long free || fileSize <= 0) return null;
        long needed = fileSize * 3 + 1024L * 1024 * 1024;
        return free < needed ? new Finding(Severity.Caution, $"Only {FileSize.Text(free)} is free. Conversions can need about three times the file's size.") : null;
    }

    public static Finding? SizeFinding(long fileSize) =>
        fileSize >= LargeFileBytes ? new Finding(Severity.Info, $"This is a large file ({FileSize.Text(fileSize)}). The conversion may take several minutes.") : null;

    public static string? CheckerName(string languageId) => languageId switch
    {
        "python" => "Python", "ruby" => "Ruby", "c" => "clang (C)", "cpp" => "clang (C++)", "java" => "javac",
        "rust" => "rustc", "go" => "gofmt", "javascript" => "Node.js", "typescript" => "TypeScript (tsc)", _ => null,
    };

    internal static string[] CheckerBinaries(string languageId) => languageId switch
    {
        "python" => ["python3.12", "python3", "python"], "ruby" => ["ruby"], "c" or "cpp" => ["clang", "gcc"], "java" => ["javac"],
        "rust" => ["rustc"], "go" => ["gofmt"], "javascript" => ["node"], "typescript" => ["tsc"], _ => [],
    };

    // MARK: Helpers

    /// <summary>The folder itself, or the closest parent that exists. A results folder that has not been made yet is
    /// fine: the app creates it, as long as its parent can be written to.</summary>
    public static string NearestExistingFolder(string folder)
    {
        var candidate = Path.GetFullPath(folder);
        while (!Directory.Exists(candidate) && Path.GetDirectoryName(candidate) is { } parent) candidate = parent;
        return candidate;
    }

    /// <summary>Whether the app can save into a folder. The check writes and deletes a small file, so its answer is kept for ten
    /// seconds: the queue checks every row whenever anything changes, and the folder is often synced by OneDrive.</summary>
    public static bool CanWrite(string folder)
    {
        var key = NearestExistingFolder(folder);
        lock (WriteCache)
        {
            if (WriteCache.TryGetValue(key, out var known) && DateTime.UtcNow - known.At < TimeSpan.FromSeconds(10)) return known.Ok;
        }
        bool ok = ProbeWrite(key);
        lock (WriteCache) WriteCache[key] = (ok, DateTime.UtcNow);
        return ok;
    }

    private static readonly Dictionary<string, (bool Ok, DateTime At)> WriteCache = new(StringComparer.OrdinalIgnoreCase);

    private static bool ProbeWrite(string existingFolder)
    {
        try
        {
            var probe = Path.Combine(existingFolder, ".uc-write-" + Guid.NewGuid().ToString("N"));
            using (File.Create(probe)) { }
            File.Delete(probe);
            return true;
        }
        catch { return false; }
    }

    public static long SizeOf(string path) => File.Exists(path) ? new FileInfo(path).Length : 0;

    public static long? FreeBytes(string folder)
    {
        try { return new DriveInfo(Path.GetPathRoot(NearestExistingFolder(folder))!).AvailableFreeSpace; }
        catch { return null; }
    }
}
