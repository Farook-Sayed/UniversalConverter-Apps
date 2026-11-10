namespace UniversalConverter.Core;

/// <summary>The routing table: which formats exist, which engine handles each conversion, and what each input becomes.</summary>
public static class FormatCatalog
{
    // MARK: Code languages

    public static readonly IReadOnlyList<CodeLanguage> CodeLanguages =
    [
        new("python", "Python", ["py"]), new("java", "Java", ["java"]), new("c", "C", ["c", "h"]),
        new("cpp", "C++", ["cpp", "cc", "cxx", "hpp"]), new("rust", "Rust", ["rs"]),
        new("javascript", "JavaScript", ["js"]), new("typescript", "TypeScript", ["ts"]),
        new("ruby", "Ruby", ["rb"]), new("go", "Go", ["go"]), new("csharp", "C#", ["cs"]),
    ];

    public static CodeLanguage? CodeLanguageForExtension(string ext) => CodeLanguages.FirstOrDefault(l => l.Extensions.Contains(ext));
    public static CodeLanguage? CodeLanguageForId(string id) => CodeLanguages.FirstOrDefault(l => l.Id == id);

    private static readonly HashSet<string> JavaKeywords =
    [
        "abstract", "assert", "boolean", "break", "byte", "case", "catch", "char", "class", "const", "continue",
        "default", "do", "double", "else", "enum", "extends", "final", "finally", "float", "for", "goto", "if",
        "implements", "import", "instanceof", "int", "interface", "long", "native", "new", "package", "private",
        "protected", "public", "return", "short", "static", "strictfp", "super", "switch", "synchronized", "this",
        "throw", "throws", "transient", "try", "void", "volatile", "while", "true", "false", "null",
    ];

    /// <summary>A legal Java class name built from a file name. Java requires the public class to match the file name.</summary>
    public static string JavaClassName(string stem)
    {
        var name = new string(stem.Select(c => (c < 128 && char.IsLetterOrDigit(c)) || c == '_' ? c : '_').ToArray());
        if (name.Length == 0) return "Main";
        if (name[0] < 128 && char.IsDigit(name[0])) name = "_" + name;
        if (JavaKeywords.Contains(name)) name += "_";
        return name;
    }

    // MARK: Known formats

    private static readonly Dictionary<string, string[]> FormatExtensions = new()
    {
        ["mp4"] = ["mp4", "m4v"], ["mkv"] = ["mkv"], ["webm"] = ["webm"], ["avi"] = ["avi"], ["mov"] = ["mov"], ["gif"] = ["gif"],
        ["mp3"] = ["mp3"], ["wav"] = ["wav"], ["flac"] = ["flac"], ["m4a"] = ["m4a", "m4b"], ["ogg"] = ["ogg", "oga"],
        ["png"] = ["png"], ["jpg"] = ["jpg", "jpeg"], ["webp"] = ["webp"], ["bmp"] = ["bmp"], ["tiff"] = ["tif", "tiff"],
        ["avif"] = ["avif"], ["heic"] = ["heic", "heif"], ["svg"] = ["svg"], ["pdf"] = ["pdf", "ai"], ["docx"] = ["docx"],
        ["mobi"] = ["mobi", "prc"], ["azw3"] = ["azw3", "azw"], ["fb2"] = ["fb2"], ["eps"] = ["eps"], ["ps"] = ["ps"],
        ["obj"] = ["obj"], ["stl"] = ["stl"], ["ply"] = ["ply"], ["dae"] = ["dae"], ["gltf"] = ["gltf"], ["glb"] = ["glb"],
        ["fbx"] = ["fbx"], ["doc"] = ["doc"], ["odt"] = ["odt"], ["rtf"] = ["rtf"], ["html"] = ["html", "htm"],
        ["txt"] = ["txt"], ["md"] = ["md", "markdown"], ["epub"] = ["epub"], ["xlsx"] = ["xlsx"], ["xls"] = ["xls"],
        ["ods"] = ["ods"], ["csv"] = ["csv"], ["pptx"] = ["pptx"], ["ppt"] = ["ppt"], ["odp"] = ["odp"],
        ["wmv"] = ["wmv"], ["flv"] = ["flv"], ["3gp"] = ["3gp", "3g2"], ["m2ts"] = ["m2ts", "mts"], ["vob"] = ["vob"],
        ["mpg"] = ["mpg", "mpeg"], ["srt"] = ["srt"], ["vtt"] = ["vtt"], ["ass"] = ["ass", "ssa"], ["ipynb"] = ["ipynb"],
        ["ttf"] = ["ttf"], ["otf"] = ["otf"], ["woff"] = ["woff"], ["woff2"] = ["woff2"],
        ["zip"] = ["zip"], ["7z"] = ["7z"], ["gz"] = ["gz"], ["targz"] = ["tar.gz", "tgz"], ["tar"] = ["tar"], ["rar"] = ["rar"],
        ["cr2"] = ["cr2"], ["cr3"] = ["cr3"], ["nef"] = ["nef", "nrw"], ["arw"] = ["arw", "srf"], ["dng"] = ["dng"],
        ["raf"] = ["raf"], ["orf"] = ["orf"], ["rw2"] = ["rw2"],
    };

    /// <summary>Camera RAW formats. Each is read as a picture.</summary>
    public static readonly IReadOnlySet<string> RawFormats = new HashSet<string> { "cr2", "cr3", "nef", "arw", "dng", "raf", "orf", "rw2" };

    public static string? RawFormatForExtension(string ext) => RawFormats.FirstOrDefault(r => ExtensionsForFormat(r).Contains(ext));

    /// <summary>Picture formats the built-in image engine writes. HEIC can be read but not written on Windows.</summary>
    public static readonly IReadOnlySet<string> ImageTargets = new HashSet<string> { "png", "jpg", "tiff", "gif", "bmp", "webp", "avif" };

    public static string[] ExtensionsForFormat(string id)
    {
        if (FormatExtensions.TryGetValue(id, out var known)) return known;
        return CodeLanguageForId(id)?.Extensions ?? [];
    }

    // MARK: Target groups

    private static readonly string[] VideoTargets = ["mp4", "mkv", "webm", "avi", "mov", "wmv", "flv", "3gp", "gif", "mp3", "wav"];
    private static readonly string[] AudioTargets = ["mp3", "wav", "flac", "m4a", "ogg"];
    private static readonly string[] RasterTargets = ["png", "jpg", "webp", "gif", "bmp", "tiff", "avif", "pdf"];
    private static readonly string[] VectorTargets = ["png", "jpg", "pdf"];
    private static readonly string[] WordTargets = ["pdf", "docx", "odt", "rtf", "html", "txt", "md"];
    private static readonly string[] SheetTargets = ["pdf", "xlsx", "ods", "csv"];
    private static readonly string[] SlideTargets = ["pdf", "pptx", "odp"];
    private static readonly string[] MarkupTargets = ["docx", "html", "rtf", "txt", "md", "epub"];
    private static readonly string[] ArchiveTargets = ["zip", "7z", "targz", "tar"];
    private static readonly string[] SubtitleTargets = ["srt", "vtt", "ass"];
    private static readonly string[] PostscriptTargets = ["pdf", "png", "jpg"];
    private static readonly string[] EbookTargets = ["epub", "mobi", "azw3", "fb2", "pdf", "docx", "txt"];
    private static readonly string[] CalibreMarkupTargets = ["mobi", "azw3", "fb2"];
    private static readonly string[] ModelTargets = ["obj", "stl", "ply", "dae", "gltf", "glb"];
    private static readonly string[] PdfTargets = ["txt", "png", "jpg", "docx", "odt", "html"];

    private static readonly Dictionary<string, string> Labels = new()
    {
        ["mp4"] = "MP4 video", ["mkv"] = "Matroska video", ["webm"] = "WebM video", ["avi"] = "AVI video",
        ["mov"] = "QuickTime movie", ["gif"] = "Animated GIF", ["mp3"] = "MP3 audio", ["wav"] = "WAV audio",
        ["flac"] = "FLAC audio", ["m4a"] = "M4A audio", ["ogg"] = "Ogg Opus audio", ["png"] = "PNG image",
        ["jpg"] = "JPEG image", ["webp"] = "WebP image", ["bmp"] = "BMP image", ["tiff"] = "TIFF image",
        ["pdf"] = "PDF document", ["docx"] = "Word document (.docx)", ["odt"] = "OpenDocument text (.odt)",
        ["rtf"] = "Rich Text (.rtf)", ["html"] = "Web page (.html)", ["txt"] = "Plain text (.txt)",
        ["md"] = "Markdown (.md)", ["epub"] = "EPUB book", ["xlsx"] = "Excel workbook (.xlsx)",
        ["ods"] = "OpenDocument spreadsheet (.ods)", ["csv"] = "CSV spreadsheet", ["pptx"] = "PowerPoint (.pptx)",
        ["odp"] = "OpenDocument presentation (.odp)", ["zip"] = "ZIP archive", ["7z"] = "7-Zip archive",
        ["targz"] = "Compressed tar (.tar.gz)", ["tar"] = "Tar archive (.tar)", ["avif"] = "AVIF image", ["heic"] = "HEIC image",
        ["cr2"] = "Canon RAW (CR2)", ["cr3"] = "Canon RAW (CR3)", ["nef"] = "Nikon RAW (NEF)", ["arw"] = "Sony RAW (ARW)",
        ["dng"] = "Adobe DNG raw", ["raf"] = "Fujifilm RAW (RAF)", ["orf"] = "Olympus RAW (ORF)", ["rw2"] = "Panasonic RAW (RW2)",
        ["wmv"] = "Windows Media video", ["flv"] = "Flash video", ["3gp"] = "3GP mobile video",
        ["srt"] = "SubRip subtitles (.srt)", ["vtt"] = "WebVTT subtitles (.vtt)", ["ass"] = "SubStation Alpha subtitles (.ass)",
        ["ttf"] = "TrueType font (.ttf)", ["otf"] = "OpenType font (.otf)", ["woff"] = "WOFF web font", ["woff2"] = "WOFF2 web font",
        ["ipynb"] = "Jupyter notebook (.ipynb)", ["mobi"] = "Kindle book (.mobi)", ["azw3"] = "Kindle book (.azw3)",
        ["fb2"] = "FictionBook e-book (.fb2)", ["eps"] = "Encapsulated PostScript (.eps)", ["ps"] = "PostScript (.ps)",
        ["obj"] = "Wavefront OBJ model (.obj)", ["stl"] = "STL model (.stl)", ["ply"] = "PLY model (.ply)",
        ["dae"] = "COLLADA model (.dae)", ["gltf"] = "glTF model (.gltf)", ["glb"] = "glTF binary model (.glb)",
    };

    private static string ExtensionFor(string target)
    {
        if (CodeLanguageForId(target) is { } code) return code.Extensions[0];
        return target == "targz" ? "tar.gz" : target;
    }

    /// <summary>Engine for a given input category and target.</summary>
    private static Engine? EngineFor(string formatId, MediaCategory category, string target)
    {
        switch (category)
        {
            case MediaCategory.Video or MediaCategory.Audio: return Engine.Ffmpeg;
            case MediaCategory.Image or MediaCategory.Vector: return Engine.Image;
            case MediaCategory.Document:
                // PDF files: text and images are read here, and documents come from LibreOffice.
                if (formatId == "pdf") return target is "txt" or "png" or "jpg" ? Engine.Pdf : Engine.LibreOffice;
                // Pandoc reads .docx but not .doc, .odt or .rtf, so Markdown only comes from .docx.
                if (target == "md") return formatId == "docx" ? Engine.Pandoc : null;
                return Engine.LibreOffice;
            case MediaCategory.Spreadsheet or MediaCategory.Presentation: return Engine.LibreOffice;
            case MediaCategory.Markup:
                if (CalibreMarkupTargets.Contains(target)) return Engine.Calibre;
                if (target == "pdf") return formatId == "epub" ? Engine.Calibre : formatId == "html" ? Engine.LibreOffice : null;
                return Engine.Pandoc;
            case MediaCategory.Ebook: return Engine.Calibre;
            case MediaCategory.Code: return Engine.Ollama;
            case MediaCategory.Archive: return target == "7z" ? Engine.SevenZip : Engine.Archive;
            case MediaCategory.Postscript: return Engine.Ghostscript;
            case MediaCategory.Model3D: return Engine.Assimp;
            case MediaCategory.Subtitle: return Engine.Ffmpeg;
            case MediaCategory.Font: return Engine.FontTools;
            default: return null;
        }
    }

    /// <summary>A short, plain name for a format, such as "Word document". Null when there is none.</summary>
    public static string? DisplayName(string id)
    {
        if (CodeLanguageForId(id) is { } code) return $"{code.Label} source code";
        if (!Labels.TryGetValue(id, out var label)) return null;
        var paren = label.IndexOf(" (", StringComparison.Ordinal);
        return paren >= 0 ? label[..paren] : label;
    }

    /// <summary>Single-step conversions from one format, in the order the tables list them.</summary>
    public static List<OutputFormat> DirectTargets(string formatId, MediaCategory category, Func<Engine, bool>? available = null)
    {
        available ??= _ => true;
        IEnumerable<string> candidates = category switch
        {
            MediaCategory.Video => VideoTargets,
            MediaCategory.Audio => AudioTargets,
            MediaCategory.Image => RasterTargets,
            MediaCategory.Vector => VectorTargets,
            MediaCategory.Document => formatId == "pdf" ? PdfTargets : WordTargets,
            MediaCategory.Postscript => PostscriptTargets,
            MediaCategory.Model3D => ModelTargets,
            MediaCategory.Spreadsheet => SheetTargets,
            MediaCategory.Presentation => SlideTargets,
            MediaCategory.Markup => MarkupTargets.Concat(formatId is "html" or "epub" ? ["pdf"] : [])
                                                 .Concat(formatId == "epub" ? CalibreMarkupTargets : []),
            MediaCategory.Ebook => EbookTargets,
            MediaCategory.Code => CodeLanguages.Select(l => l.Id),
            // Only the formats the app can unpack. A plain .gz is detected but not converted.
            MediaCategory.Archive => new[] { "zip", "7z", "rar", "targz", "tar" }.Contains(formatId) ? ArchiveTargets : [],
            MediaCategory.Subtitle => SubtitleTargets,
            MediaCategory.Font => formatId is "woff" or "woff2" ? ["ttf", "otf"] : ["woff", "woff2"],
            _ => [],
        };

        var results = new List<OutputFormat>();
        foreach (var target in candidates)
        {
            if (target == formatId) continue;
            if (EngineFor(formatId, category, target) is not { } engine || !available(engine)) continue;
            // Writing text from a picture or a PDF needs nothing that is not already built in.
            var label = CodeLanguageForId(target)?.Label ?? (Labels.TryGetValue(target, out var l) ? l : target.ToUpperInvariant());
            results.Add(new OutputFormat(target, label, ExtensionFor(target), engine));
        }
        // A PDF can be made smaller. That is a conversion to PDF with a compression level.
        if (formatId == "pdf" && category == MediaCategory.Document && available(Engine.Ghostscript))
            results.Add(new OutputFormat("pdf", "PDF, smaller file", "pdf", Engine.Ghostscript));
        // A picture can be read as text.
        if (category == MediaCategory.Image && available(Engine.Ocr))
            results.Add(new OutputFormat("txt", "Text (OCR)", "txt", Engine.Ocr));
        // A picture can stay in its format and still be resized, cropped or compressed. GIF is left out,
        // because saving it again would keep only the first frame of an animation.
        if (category == MediaCategory.Image && formatId != "gif" && ImageTargets.Contains(formatId) && available(Engine.Image))
            results.Add(new OutputFormat(formatId, $"{(Labels.TryGetValue(formatId, out var name) ? name : formatId.ToUpperInvariant())}, adjusted",
                                         ExtensionFor(formatId), Engine.Image));
        return results;
    }

    /// <summary>The category a format has once it is the output of a conversion.</summary>
    public static MediaCategory OutputCategory(string id)
    {
        if (CodeLanguageForId(id) is not null) return MediaCategory.Code;
        return id switch
        {
            "mp4" or "mkv" or "webm" or "avi" or "mov" or "wmv" or "flv" or "3gp" or "m2ts" or "mpg" or "vob" => MediaCategory.Video,
            "mp3" or "wav" or "flac" or "m4a" or "ogg" => MediaCategory.Audio,
            "png" or "jpg" or "webp" or "gif" or "bmp" or "tiff" or "avif" or "heic" => MediaCategory.Image,
            "svg" => MediaCategory.Vector,
            "pdf" or "docx" or "doc" or "odt" or "rtf" => MediaCategory.Document,
            "xlsx" or "xls" or "ods" or "csv" => MediaCategory.Spreadsheet,
            "pptx" or "ppt" or "odp" => MediaCategory.Presentation,
            "html" or "txt" or "md" or "epub" or "ipynb" => MediaCategory.Markup,
            "zip" or "7z" or "targz" or "tar" or "gz" or "rar" => MediaCategory.Archive,
            "srt" or "vtt" or "ass" => MediaCategory.Subtitle,
            "ttf" or "otf" or "woff" or "woff2" => MediaCategory.Font,
            "eps" or "ps" => MediaCategory.Postscript,
            "obj" or "stl" or "ply" or "dae" or "gltf" or "glb" or "fbx" => MediaCategory.Model3D,
            "mobi" or "azw3" or "fb2" => MediaCategory.Ebook,
            _ => MediaCategory.Unknown,
        };
    }

    /// <summary>Pandoc's name for a format.</summary>
    public static string? PandocName(string id, bool input) => id switch
    {
        "md" => "markdown",
        "txt" => input ? "markdown" : "plain",
        "html" => "html", "docx" => "docx", "rtf" => "rtf", "epub" => "epub",
        "ipynb" => input ? "ipynb" : null,
        _ => null,
    };

    // MARK: Routing

    /// <summary>Every way to convert a file: direct conversions first, then chains of up to three steps.</summary>
    public static List<Route> TargetsFor(DetectedFile source, Func<Engine, bool>? available = null) =>
        RoutesFrom(source.FormatId, source.Category, available ?? (_ => true));

    public static List<Route> RoutesFrom(string formatId, MediaCategory sourceCategory, Func<Engine, bool> available)
    {
        var found = new Dictionary<string, Route>();
        var order = new List<string>();
        var visited = new HashSet<string> { formatId };
        var frontier = new List<Route>();

        // Step one: the direct conversions, which are always the shortest route. A PDF may become a smaller PDF
        // and a picture may stay in its format, so the source's own format is allowed here.
        foreach (var output in DirectTargets(formatId, sourceCategory, available).Where(o => !visited.Contains(o.Id) || o.Id == formatId))
        {
            var step = new RouteStep(formatId, sourceCategory, output, OutputCategory(output.Id));
            var route = new Route([step]);
            // The text of a picture and the picture itself share an id only when the format is "txt", which no picture is.
            found[output.Id] = route;
            order.Add(output.Id);
            visited.Add(output.Id);
            frontier.Add(route);
        }

        // Chains of two and three steps, found breadth first, so each target gets its shortest route.
        //  - Code translation is only ever the final step, never an intermediate result.
        //  - A chain must end in a different kind of format from the source.
        for (int depth = 2; depth <= 3; depth++)
        {
            var next = new List<Route>();
            foreach (var route in frontier)
            {
                var node = route.Steps[^1];
                if (node.OutputCategory == MediaCategory.Code) continue;
                // Several page files cannot be the input of another step.
                if (node.ProducesPageImages) continue;
                foreach (var output in DirectTargets(node.Output.Id, node.OutputCategory, available))
                {
                    if (output.Engine == Engine.Ollama || visited.Contains(output.Id)) continue;
                    var category = OutputCategory(output.Id);
                    if (category == sourceCategory) continue;
                    var step = new RouteStep(node.Output.Id, node.OutputCategory, output, category);
                    var extended = new Route(route.Steps.Append(step));
                    found[output.Id] = extended;
                    order.Add(output.Id);
                    visited.Add(output.Id);
                    next.Add(extended);
                }
            }
            frontier = next;
        }
        return order.Select(id => found[id]).ToList();
    }
}
