using System.Text;

namespace UniversalConverter.Core;

/// <summary>File-name helpers for double extensions such as .tar.gz.</summary>
public static class FileNames
{
    public static string EffectiveExtension(string path)
    {
        var name = System.IO.Path.GetFileName(path).ToLowerInvariant();
        if (name.EndsWith(".tar.gz")) return "tar.gz";
        return System.IO.Path.GetExtension(name).TrimStart('.');
    }

    /// <summary>The name without its extension(s): "report.tar.gz" becomes "report".</summary>
    public static string Stem(string path)
    {
        var name = System.IO.Path.GetFileName(path);
        return name.ToLowerInvariant().EndsWith(".tar.gz") ? name[..^7] : System.IO.Path.GetFileNameWithoutExtension(name);
    }
}

/// <summary>Identifies a file from its content first and its extension second.</summary>
public sealed class FileDetector
{
    /// <summary>Reads only the first 4 KB of the file.</summary>
    public DetectedFile Detect(string path)
    {
        using var stream = File.OpenRead(path);
        var buffer = new byte[4096];
        int read = stream.Read(buffer, 0, buffer.Length);
        return Detect(buffer.AsSpan(0, read).ToArray(), path);
    }

    /// <summary>Pure function over the file's first bytes, so it can be unit tested.</summary>
    public DetectedFile Detect(byte[] head, string path)
    {
        var ext = FileNames.EffectiveExtension(path);

        var sig = Signatures.Match(head);
        if (sig is not null)
        {
            var (formatId, category, mime) = sig.Value;
            if (formatId == "zip" && Signatures.ZipContainer(head) is { } inner) (formatId, category, mime) = inner;
            if (formatId == "mobi" && ext is "azw3" or "azw") formatId = "azw3";
            if (formatId == "vob" && ext is "mpg" or "mpeg") formatId = "mpg";
            if (formatId == "gz" && ext is "tar.gz" or "tgz") { formatId = "targz"; mime = "application/x-compressed-tar"; }
            // TIFF-based camera RAW files (CR2, NEF, ARW, DNG) share the TIFF signature. The extension names the brand.
            if (formatId == "tiff" && FormatCatalog.RawFormatForExtension(ext) is { } raw) { formatId = raw; mime = "image/x-raw"; }
            // Legacy Office files are OLE containers. The extension is the only clue left.
            if (formatId == "ole" && Signatures.LegacyOffice(ext) is { } legacy) (formatId, category, mime) = legacy;
            return new DetectedFile(path, category, formatId, mime, DetectionMethod.MagicBytes, IsMismatch(ext, formatId));
        }

        // No binary signature. Accept it as text only if it decodes as UTF-8 with no NUL bytes.
        bool looksLikeText = !head.Contains((byte)0) && DecodesAsUtf8(head);
        if (looksLikeText)
        {
            var text = Encoding.UTF8.GetString(head, 0, Math.Min(head.Length, 512)).ToLowerInvariant();
            if (text.StartsWith("%!ps"))
            {
                var id = ext == "eps" ? "eps" : "ps";
                return new DetectedFile(path, MediaCategory.Postscript, id, "application/postscript", DetectionMethod.MagicBytes, IsMismatch(ext, id));
            }
            if (text.Contains("<svg") && (ext == "svg" || Signatures.TextFormat(ext) is null))
                return new DetectedFile(path, MediaCategory.Vector, "svg", "image/svg+xml", DetectionMethod.MagicBytes, IsMismatch(ext, "svg"));
            if (Signatures.TextFormat(ext) is { } tf)
                return new DetectedFile(path, tf.Category, tf.FormatId, tf.Mime, DetectionMethod.TextWithExtension, false);
            return new DetectedFile(path, MediaCategory.Unknown, "text", "text/plain", DetectionMethod.TextWithExtension, false);
        }

        // Unknown binary. Some formats have no signature (M2TS, for example), so the extension decides.
        if (Signatures.BinaryFormat(ext) is { } bf)
            return new DetectedFile(path, bf.Category, bf.FormatId, bf.Mime, DetectionMethod.ExtensionOnly, false);
        if (Signatures.TextFormat(ext) is { } tf2)
            return new DetectedFile(path, tf2.Category, tf2.FormatId, tf2.Mime, DetectionMethod.ExtensionOnly, false);
        return new DetectedFile(path, MediaCategory.Unknown, ext.Length == 0 ? "unknown" : ext,
                                "application/octet-stream", DetectionMethod.ExtensionOnly, false);
    }

    /// <summary>True when the bytes are UTF-8 text. A 4 KB read can cut the last character in half.</summary>
    private static bool DecodesAsUtf8(byte[] data)
    {
        var strict = new UTF8Encoding(false, true);
        bool Try(int count) { try { strict.GetString(data, 0, count); return true; } catch { return false; } }
        if (Try(data.Length)) return true;
        if (data.Length < 4096) return false;
        return Enumerable.Range(1, 3).Any(n => Try(data.Length - n));
    }

    private static bool IsMismatch(string ext, string formatId)
    {
        if (ext.Length == 0) return false;
        var aliases = FormatCatalog.ExtensionsForFormat(formatId);
        return aliases.Length > 0 && !aliases.Contains(ext);
    }
}

/// <summary>Binary signatures and extension-based text formats.</summary>
internal static class Signatures
{
    public readonly record struct Hit(string FormatId, MediaCategory Category, string Mime)
    {
        public void Deconstruct(out string f, out MediaCategory c, out string m) { f = FormatId; c = Category; m = Mime; }
    }

    private static bool At(byte[] b, byte[] sig, int offset = 0) =>
        b.Length >= offset + sig.Length && b.AsSpan(offset, sig.Length).SequenceEqual(sig);

    private static bool Ascii(byte[] b, string s, int offset = 0) => At(b, Encoding.ASCII.GetBytes(s), offset);

    public static Hit? Match(byte[] b)
    {
        if (At(b, [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) return new("png", MediaCategory.Image, "image/png");
        if (At(b, [0xFF, 0xD8, 0xFF])) return new("jpg", MediaCategory.Image, "image/jpeg");
        if (Ascii(b, "GIF87a") || Ascii(b, "GIF89a")) return new("gif", MediaCategory.Image, "image/gif");
        if (Ascii(b, "RIFF") && Ascii(b, "WEBP", 8)) return new("webp", MediaCategory.Image, "image/webp");
        if (Ascii(b, "RIFF") && Ascii(b, "WAVE", 8)) return new("wav", MediaCategory.Audio, "audio/wav");
        if (Ascii(b, "RIFF") && Ascii(b, "AVI ", 8)) return new("avi", MediaCategory.Video, "video/x-msvideo");
        if (Ascii(b, "FUJIFILMCCD-RAW")) return new("raf", MediaCategory.Image, "image/x-fuji-raf");
        if (Ascii(b, "IIRO") || Ascii(b, "IIRS")) return new("orf", MediaCategory.Image, "image/x-olympus-orf");
        if (At(b, [0x49, 0x49, 0x55, 0x00])) return new("rw2", MediaCategory.Image, "image/x-panasonic-rw2");
        if (At(b, [0x49, 0x49, 0x2A, 0x00]) || At(b, [0x4D, 0x4D, 0x00, 0x2A])) return new("tiff", MediaCategory.Image, "image/tiff");
        // BMP: "BM", a 4-byte size, then four reserved bytes that are always zero.
        if (Ascii(b, "BM") && b.Length >= 14 && At(b, [0, 0, 0, 0], 6)) return new("bmp", MediaCategory.Image, "image/bmp");
        if (At(b, [0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11])) return new("wmv", MediaCategory.Video, "video/x-ms-asf");
        if (At(b, [0x46, 0x4C, 0x56, 0x01])) return new("flv", MediaCategory.Video, "video/x-flv");
        if (At(b, [0x00, 0x00, 0x01, 0xBA])) return new("vob", MediaCategory.Video, "video/mpeg");
        if (At(b, [0x00, 0x01, 0x00, 0x00])) return new("ttf", MediaCategory.Font, "font/ttf");
        if (Ascii(b, "OTTO")) return new("otf", MediaCategory.Font, "font/otf");
        if (Ascii(b, "wOFF")) return new("woff", MediaCategory.Font, "font/woff");
        if (Ascii(b, "wOF2")) return new("woff2", MediaCategory.Font, "font/woff2");
        if (b.Length >= 68 && Ascii(b, "BOOKMOBI", 60)) return new("mobi", MediaCategory.Ebook, "application/x-mobipocket-ebook");
        if (At(b, [0xC5, 0xD0, 0xD3, 0xC6])) return new("eps", MediaCategory.Postscript, "application/postscript");
        if (Ascii(b, "glTF")) return new("glb", MediaCategory.Model3D, "model/gltf-binary");
        if (Ascii(b, "Kaydara FBX Binary")) return new("fbx", MediaCategory.Model3D, "model/fbx");
        if (Ascii(b, "%PDF")) return new("pdf", MediaCategory.Document, "application/pdf");
        if (At(b, [0x1A, 0x45, 0xDF, 0xA3]))
        {
            var head = Encoding.UTF8.GetString(b, 0, Math.Min(64, b.Length));
            return head.Contains("webm") ? new("webm", MediaCategory.Video, "video/webm") : new("mkv", MediaCategory.Video, "video/x-matroska");
        }
        if (Ascii(b, "ID3") || At(b, [0xFF, 0xFB]) || At(b, [0xFF, 0xF3]) || At(b, [0xFF, 0xF2])) return new("mp3", MediaCategory.Audio, "audio/mpeg");
        if (Ascii(b, "fLaC")) return new("flac", MediaCategory.Audio, "audio/flac");
        if (Ascii(b, "OggS")) return new("ogg", MediaCategory.Audio, "audio/ogg");
        if (Ascii(b, "ftyp", 4))
        {
            var brand = b.Length >= 12 ? Encoding.ASCII.GetString(b, 8, 4) : "";
            return brand switch
            {
                "avif" or "avis" => new("avif", MediaCategory.Image, "image/avif"),
                "heic" or "heix" or "heim" or "heis" or "hevc" or "hevx" or "mif1" or "msf1" => new("heic", MediaCategory.Image, "image/heic"),
                "M4A " or "M4B " => new("m4a", MediaCategory.Audio, "audio/mp4"),
                "qt  " => new("mov", MediaCategory.Video, "video/quicktime"),
                "3gp4" or "3gp5" or "3gp6" or "3gp7" or "3g2a" => new("3gp", MediaCategory.Video, "video/3gpp"),
                "crx " => new("cr3", MediaCategory.Image, "image/x-canon-cr3"),
                _ => new("mp4", MediaCategory.Video, "video/mp4"),
            };
        }
        if (At(b, [0x50, 0x4B, 0x03, 0x04]) || At(b, [0x50, 0x4B, 0x05, 0x06])) return new("zip", MediaCategory.Archive, "application/zip");
        if (At(b, [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C])) return new("7z", MediaCategory.Archive, "application/x-7z-compressed");
        if (At(b, [0x1F, 0x8B])) return new("gz", MediaCategory.Archive, "application/gzip");
        if (Ascii(b, "Rar!")) return new("rar", MediaCategory.Archive, "application/vnd.rar");
        if (b.Length >= 262 && Ascii(b, "ustar", 257)) return new("tar", MediaCategory.Archive, "application/x-tar");
        if (At(b, [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1])) return new("ole", MediaCategory.Document, "application/x-ole-storage");
        if (Ascii(b, "{\\rtf")) return new("rtf", MediaCategory.Document, "application/rtf");
        return null;
    }

    /// <summary>Looks inside a ZIP container for Office, OpenDocument and EPUB markers.</summary>
    public static Hit? ZipContainer(byte[] b)
    {
        if (b.Length > 38 && Ascii(b, "mimetype", 30))
        {
            var type = Encoding.UTF8.GetString(b, 38, Math.Min(96, b.Length - 38));
            if (type.Contains("application/epub+zip")) return new("epub", MediaCategory.Markup, "application/epub+zip");
            if (type.Contains("application/vnd.oasis.opendocument.text")) return new("odt", MediaCategory.Document, "application/vnd.oasis.opendocument.text");
            if (type.Contains("application/vnd.oasis.opendocument.spreadsheet")) return new("ods", MediaCategory.Spreadsheet, "application/vnd.oasis.opendocument.spreadsheet");
            if (type.Contains("application/vnd.oasis.opendocument.presentation")) return new("odp", MediaCategory.Presentation, "application/vnd.oasis.opendocument.presentation");
        }
        // The byte before an entry name is part of the header, never a letter, so a longer path does not count.
        bool HasEntry(string folder)
        {
            var needle = Encoding.ASCII.GetBytes(folder);
            for (int start = 1; start + needle.Length <= b.Length; start++)
                if (b[start - 1] < 0x20 && b.AsSpan(start, needle.Length).SequenceEqual(needle)) return true;
            return false;
        }
        if (HasEntry("word/")) return new("docx", MediaCategory.Document, "application/vnd.openxmlformats-officedocument.wordprocessingml.document");
        if (HasEntry("xl/")) return new("xlsx", MediaCategory.Spreadsheet, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet");
        if (HasEntry("ppt/")) return new("pptx", MediaCategory.Presentation, "application/vnd.openxmlformats-officedocument.presentationml.presentation");
        return null;
    }

    public static Hit? LegacyOffice(string ext) => ext switch
    {
        "doc" => new("doc", MediaCategory.Document, "application/msword"),
        "xls" => new("xls", MediaCategory.Spreadsheet, "application/vnd.ms-excel"),
        "ppt" => new("ppt", MediaCategory.Presentation, "application/vnd.ms-powerpoint"),
        _ => null,
    };

    /// <summary>Binary formats with no reliable signature. These are recognised by extension only.</summary>
    public static Hit? BinaryFormat(string ext) => ext switch
    {
        "m2ts" or "mts" => new("m2ts", MediaCategory.Video, "video/mp2t"),
        "mpg" or "mpeg" => new("mpg", MediaCategory.Video, "video/mpeg"),
        "vob" => new("vob", MediaCategory.Video, "video/dvd"),
        _ => null,
    };

    /// <summary>Plain-text formats, recognised by extension.</summary>
    public static Hit? TextFormat(string ext)
    {
        if (FormatCatalog.CodeLanguageForExtension(ext) is { } code) return new(code.Id, MediaCategory.Code, "text/plain");
        return ext switch
        {
            "md" or "markdown" => new("md", MediaCategory.Markup, "text/markdown"),
            "html" or "htm" => new("html", MediaCategory.Markup, "text/html"),
            "txt" => new("txt", MediaCategory.Markup, "text/plain"),
            "csv" => new("csv", MediaCategory.Spreadsheet, "text/csv"),
            "svg" => new("svg", MediaCategory.Vector, "image/svg+xml"),
            "srt" => new("srt", MediaCategory.Subtitle, "application/x-subrip"),
            "vtt" => new("vtt", MediaCategory.Subtitle, "text/vtt"),
            "ass" or "ssa" => new("ass", MediaCategory.Subtitle, "text/x-ssa"),
            "ipynb" => new("ipynb", MediaCategory.Markup, "application/x-ipynb+json"),
            "obj" => new("obj", MediaCategory.Model3D, "model/obj"),
            "stl" => new("stl", MediaCategory.Model3D, "model/stl"),
            "ply" => new("ply", MediaCategory.Model3D, "model/ply"),
            "dae" => new("dae", MediaCategory.Model3D, "model/vnd.collada+xml"),
            "gltf" => new("gltf", MediaCategory.Model3D, "model/gltf+json"),
            "ps" or "eps" => new(ext, MediaCategory.Postscript, "application/postscript"),
            "fb2" => new("fb2", MediaCategory.Ebook, "application/x-fictionbook+xml"),
            _ => null,
        };
    }
}
