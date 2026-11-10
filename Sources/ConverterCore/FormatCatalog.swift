import Foundation

/// Which program does the actual conversion.
public enum Engine: String, Sendable, CaseIterable {
    case ffmpeg, imagemagick, libreoffice, pandoc, ollama, archiver, fonttools, poppler, ghostscript, assimp, calibre
    /// macOS's own tools. Used when the optional tool for a conversion is not installed.
    case builtin
    /// ImageIO, the image framework in macOS. It reads HEIC and camera RAW and does the image adjustments.
    case imageio
}

/// A format the user can convert a file into.
public struct OutputFormat: Hashable, Sendable, Identifiable {
    public let id: String
    public let label: String
    public let fileExtension: String
    public let engine: Engine

    public init(id: String, label: String, fileExtension: String, engine: Engine) {
        self.id = id
        self.label = label
        self.fileExtension = fileExtension
        self.engine = engine
    }
}

/// A programming language that the Ollama code branch can translate to or from.
public struct CodeLanguage: Hashable, Sendable {
    public let id: String
    public let label: String
    public let extensions: [String]
}

/// The routing table: which formats exist, which engine handles each conversion, and what each
/// input can be converted into.
public enum FormatCatalog {

    // MARK: Code languages

    public static let codeLanguages: [CodeLanguage] = [
        CodeLanguage(id: "python", label: "Python", extensions: ["py"]),
        CodeLanguage(id: "java", label: "Java", extensions: ["java"]),
        CodeLanguage(id: "c", label: "C", extensions: ["c", "h"]),
        CodeLanguage(id: "cpp", label: "C++", extensions: ["cpp", "cc", "cxx", "hpp"]),
        CodeLanguage(id: "rust", label: "Rust", extensions: ["rs"]),
        CodeLanguage(id: "javascript", label: "JavaScript", extensions: ["js"]),
        CodeLanguage(id: "typescript", label: "TypeScript", extensions: ["ts"]),
        CodeLanguage(id: "ruby", label: "Ruby", extensions: ["rb"]),
        CodeLanguage(id: "go", label: "Go", extensions: ["go"]),
        CodeLanguage(id: "csharp", label: "C#", extensions: ["cs"]),
    ]

    public static func codeLanguage(forExtension ext: String) -> CodeLanguage? {
        codeLanguages.first { $0.extensions.contains(ext) }
    }

    public static func codeLanguage(forID id: String) -> CodeLanguage? {
        codeLanguages.first { $0.id == id }
    }

    private static let javaKeywords: Set<String> = [
        "abstract", "assert", "boolean", "break", "byte", "case", "catch", "char", "class", "const",
        "continue", "default", "do", "double", "else", "enum", "extends", "final", "finally", "float",
        "for", "goto", "if", "implements", "import", "instanceof", "int", "interface", "long", "native",
        "new", "package", "private", "protected", "public", "return", "short", "static", "strictfp",
        "super", "switch", "synchronized", "this", "throw", "throws", "transient", "try", "void",
        "volatile", "while", "true", "false", "null",
    ]

    /// A legal Java class name built from a file name. Java requires the public class to match the
    /// file name, so names with dashes or spaces are changed to underscores.
    public static func javaClassName(from stem: String) -> String {
        var name = String(stem.map { character -> Character in
            let legal = character.isASCII && (character.isLetter || character.isNumber) || character == "_"
            return legal ? character : "_"
        })
        if name.isEmpty { return "Main" }
        if let first = name.first, first.isASCII, first.isNumber { name = "_" + name }
        if javaKeywords.contains(name) { name += "_" }
        return name
    }

    // MARK: Known formats

    /// Every format this app can read or write, with the extensions that identify it.
    private static let formatExtensions: [String: [String]] = [
        "mp4": ["mp4", "m4v"], "mkv": ["mkv"], "webm": ["webm"], "avi": ["avi"], "mov": ["mov"], "gif": ["gif"],
        "mp3": ["mp3"], "wav": ["wav"], "flac": ["flac"], "m4a": ["m4a", "m4b"], "ogg": ["ogg", "oga"],
        "png": ["png"], "jpg": ["jpg", "jpeg"], "webp": ["webp"], "bmp": ["bmp"], "tiff": ["tif", "tiff"],
        "avif": ["avif"], "heic": ["heic", "heif"], "svg": ["svg"],
        "pdf": ["pdf", "ai"], "docx": ["docx"],
        "mobi": ["mobi", "prc"], "azw3": ["azw3", "azw"], "fb2": ["fb2"],
        "eps": ["eps"], "ps": ["ps"], "obj": ["obj"], "stl": ["stl"], "ply": ["ply"], "dae": ["dae"],
        "gltf": ["gltf"], "glb": ["glb"], "fbx": ["fbx"], "doc": ["doc"], "odt": ["odt"], "rtf": ["rtf"],
        "html": ["html", "htm"], "txt": ["txt"], "md": ["md", "markdown"], "epub": ["epub"],
        "xlsx": ["xlsx"], "xls": ["xls"], "ods": ["ods"], "csv": ["csv"],
        "pptx": ["pptx"], "ppt": ["ppt"], "odp": ["odp"],
        "wmv": ["wmv"], "flv": ["flv"], "3gp": ["3gp", "3g2"], "m2ts": ["m2ts", "mts"], "vob": ["vob"],
        "mpg": ["mpg", "mpeg"], "srt": ["srt"], "vtt": ["vtt"], "ass": ["ass", "ssa"], "ipynb": ["ipynb"],
        "ttf": ["ttf"], "otf": ["otf"], "woff": ["woff"], "woff2": ["woff2"],
        "zip": ["zip"], "7z": ["7z"], "gz": ["gz"], "targz": ["tar.gz", "tgz"], "tar": ["tar"], "rar": ["rar"],
        "cr2": ["cr2"], "cr3": ["cr3"], "nef": ["nef", "nrw"], "arw": ["arw", "srf"], "dng": ["dng"],
        "raf": ["raf"], "orf": ["orf"], "rw2": ["rw2"],
    ]

    /// Camera RAW formats. Each is read as a picture, and ImageIO decodes the brands macOS supports.
    public static let rawFormats: Set<String> = ["cr2", "cr3", "nef", "arw", "dng", "raf", "orf", "rw2"]

    /// The camera RAW format with this extension, including its less common names such as .nrw.
    public static func rawFormat(forExtension ext: String) -> String? {
        rawFormats.first { extensions(forFormat: $0).contains(ext) }
    }

    /// Picture formats that the built-in image engine writes. Other picture formats go through ImageMagick.
    public static let imageIOTargets: Set<String> = ["png", "jpg", "heic", "tiff", "gif", "bmp"]

    public static func extensions(forFormat id: String) -> [String] {
        if let known = formatExtensions[id] { return known }
        if let code = codeLanguage(forID: id) { return code.extensions }
        return []
    }

    // MARK: Target groups

    private static let videoTargets = ["mp4", "mkv", "webm", "avi", "mov", "wmv", "flv", "3gp", "gif", "mp3", "wav"]
    private static let audioTargets = ["mp3", "wav", "flac", "m4a", "ogg"]
    private static let rasterTargets = ["png", "jpg", "webp", "gif", "bmp", "tiff", "avif", "heic", "pdf"]
    private static let vectorTargets = ["png", "jpg", "pdf"]
    private static let wordTargets = ["pdf", "docx", "odt", "rtf", "html", "txt", "md"]
    private static let sheetTargets = ["pdf", "xlsx", "ods", "csv"]
    private static let slideTargets = ["pdf", "pptx", "odp"]
    private static let markupTargets = ["docx", "html", "rtf", "txt", "md", "epub"]
    private static let archiveTargets = ["zip", "7z", "targz", "tar"]
    private static let subtitleTargets = ["srt", "vtt", "ass"]
    private static let postscriptTargets = ["pdf", "png", "jpg"]
    /// E-book targets. Calibre writes every one of them from any e-book source.
    /// HTML is not written by Calibre directly, so it is reached in two steps: EPUB first, then Pandoc.
    private static let ebookTargets = ["epub", "mobi", "azw3", "fb2", "pdf", "docx", "txt"]
    /// Kindle and FictionBook targets for EPUB, which Pandoc cannot write.
    private static let calibreMarkupTargets = ["mobi", "azw3", "fb2"]
    private static let modelTargets = ["obj", "stl", "ply", "dae", "gltf", "glb"]
    /// What a PDF can become. Text and images come from Poppler, documents from LibreOffice.
    private static let pdfTargets = ["txt", "png", "jpg", "docx", "odt", "html"]

    /// Human-readable names for the output choices.
    private static let labels: [String: String] = [
        "mp4": "MP4 video", "mkv": "Matroska video", "webm": "WebM video", "avi": "AVI video",
        "mov": "QuickTime movie", "gif": "Animated GIF", "mp3": "MP3 audio", "wav": "WAV audio",
        "flac": "FLAC audio", "m4a": "M4A audio", "ogg": "Ogg Vorbis audio", "png": "PNG image",
        "jpg": "JPEG image", "webp": "WebP image", "bmp": "BMP image", "tiff": "TIFF image",
        "pdf": "PDF document", "docx": "Word document (.docx)", "odt": "OpenDocument text (.odt)",
        "rtf": "Rich Text (.rtf)", "html": "Web page (.html)", "txt": "Plain text (.txt)",
        "md": "Markdown (.md)", "epub": "EPUB book", "xlsx": "Excel workbook (.xlsx)",
        "ods": "OpenDocument spreadsheet (.ods)", "csv": "CSV spreadsheet", "pptx": "PowerPoint (.pptx)",
        "odp": "OpenDocument presentation (.odp)",
        "zip": "ZIP archive", "7z": "7-Zip archive", "targz": "Compressed tar (.tar.gz)", "tar": "Tar archive (.tar)",
        "avif": "AVIF image", "heic": "HEIC image",
        "cr2": "Canon RAW (CR2)", "cr3": "Canon RAW (CR3)", "nef": "Nikon RAW (NEF)", "arw": "Sony RAW (ARW)",
        "dng": "Adobe DNG raw", "raf": "Fujifilm RAW (RAF)", "orf": "Olympus RAW (ORF)", "rw2": "Panasonic RAW (RW2)",
        "wmv": "Windows Media video", "flv": "Flash video", "3gp": "3GP mobile video",
        "srt": "SubRip subtitles (.srt)", "vtt": "WebVTT subtitles (.vtt)", "ass": "SubStation Alpha subtitles (.ass)",
        "ttf": "TrueType font (.ttf)", "otf": "OpenType font (.otf)", "woff": "WOFF web font", "woff2": "WOFF2 web font",
        "ipynb": "Jupyter notebook (.ipynb)",
        "mobi": "Kindle book (.mobi)", "azw3": "Kindle book (.azw3)", "fb2": "FictionBook e-book (.fb2)",
        "eps": "Encapsulated PostScript (.eps)", "ps": "PostScript (.ps)",
        "obj": "Wavefront OBJ model (.obj)", "stl": "STL model (.stl)", "ply": "PLY model (.ply)",
        "dae": "COLLADA model (.dae)", "gltf": "glTF model (.gltf)", "glb": "glTF binary model (.glb)",
    ]

    /// The file extension to write for each target id.
    private static func extensionFor(_ target: String) -> String {
        if let code = codeLanguage(forID: target) { return code.extensions[0] }
        if target == "targz" { return "tar.gz" }
        return target
    }

    /// Engine for a given input category and target.
    private static func engine(formatID: String, category: MediaCategory, target: String) -> Engine? {
        switch category {
        case .video, .audio:
            return .ffmpeg
        case .image, .vector:
            // macOS reads HEIC and camera RAW, and writes the common picture formats, with nothing to install.
            if category == .image, imageIOTargets.contains(target) { return .imageio }
            return .imagemagick
        case .document:
            // PDF files: text and images come from Poppler, and documents from LibreOffice.
            if formatID == "pdf" {
                return ["txt", "png", "jpg"].contains(target) ? .poppler : .libreoffice
            }
            // Pandoc reads .docx but not .doc, .odt or .rtf, so Markdown only comes from .docx.
            if target == "md" { return formatID == "docx" ? .pandoc : nil }
            return .libreoffice
        case .spreadsheet, .presentation:
            return .libreoffice
        case .markup:
            if calibreMarkupTargets.contains(target) { return .calibre }
            // HTML to PDF is a LibreOffice job. Pandoc would need a LaTeX install for PDF.
            if target == "pdf" {
                if formatID == "epub" { return .calibre }
                return formatID == "html" ? .libreoffice : nil
            }
            return .pandoc
        case .ebook:
            return .calibre
        case .code:
            return .ollama
        case .archive:
            return .archiver
        case .postscript:
            return .ghostscript
        case .model3d:
            return .assimp
        case .subtitle:
            return .ffmpeg
        case .font:
            return .fonttools
        case .unknown:
            return nil
        }
    }

    /// A short, plain name for a format, such as "Word document" or "PNG image". Nil when there is none.
    public static func displayName(ofFormat id: String) -> String? {
        if let code = codeLanguage(forID: id) { return "\(code.label) source code" }
        guard let label = labels[id] else { return nil }
        if let paren = label.range(of: " (") { return String(label[..<paren.lowerBound]) }
        return label
    }

    /// Single-step conversions from one format, in the order the tables list them.
    /// Multi-step routes are built on top of these in Routing.swift.
    public static func directTargets(formatID: String, category: MediaCategory,
                                     available: (Engine) -> Bool = { _ in true }) -> [OutputFormat] {
        let candidates: [String]
        switch category {
        case .video: candidates = videoTargets
        case .audio: candidates = audioTargets
        case .image: candidates = rasterTargets
        case .vector: candidates = vectorTargets
        case .document: candidates = formatID == "pdf" ? pdfTargets : wordTargets
        case .postscript: candidates = postscriptTargets
        case .model3d: candidates = modelTargets
        case .spreadsheet: candidates = sheetTargets
        case .presentation: candidates = slideTargets
        case .markup:
            var extra: [String] = []
            if formatID == "html" || formatID == "epub" { extra.append("pdf") }
            if formatID == "epub" { extra += calibreMarkupTargets }
            candidates = markupTargets + extra
        case .ebook: candidates = ebookTargets
        case .code: candidates = codeLanguages.map(\.id)
        case .archive:
            // Only the formats the app can unpack. A plain .gz or .rar is detected but not converted.
            let readable = ["zip", "7z", "rar", "targz", "tar"]
            candidates = readable.contains(formatID) ? archiveTargets : []
        case .subtitle: candidates = subtitleTargets
        case .font:
            // A TrueType or OpenType font becomes a web font. A web font goes back to TrueType or OpenType.
            let webFont = formatID == "woff" || formatID == "woff2"
            candidates = webFont ? ["ttf", "otf"] : ["woff", "woff2"]
        case .unknown: candidates = []
        }

        var results = candidates.compactMap { target -> OutputFormat? in
            guard target != formatID else { return nil }
            guard var engine = engine(formatID: formatID, category: category, target: target) else { return nil }
            if !available(engine) {
                // Use macOS's own tool where it can do the job. Otherwise leave this option out.
                guard BuiltinEngine.supports(sourceID: formatID, targetID: target) else { return nil }
                engine = .builtin
            }
            let label: String
            if let code = codeLanguage(forID: target) {
                label = code.label
            } else {
                label = labels[target] ?? target.uppercased()
            }
            return OutputFormat(id: target, label: label, fileExtension: extensionFor(target), engine: engine)
        }
        // A PDF can be made smaller. That is a conversion to PDF with a compression level.
        if formatID == "pdf", category == .document, available(.ghostscript) {
            results.append(OutputFormat(id: "pdf", label: "PDF, smaller file", fileExtension: "pdf",
                                        engine: .ghostscript))
        }
        // A picture can be read as text. Vision does the reading, so this needs nothing to install.
        if category == .image, available(.imageio) {
            results.append(OutputFormat(id: "txt", label: "Text (OCR)", fileExtension: "txt", engine: .imageio))
        }
        // A picture can stay in its format and still be resized, cropped or compressed. GIF is left out,
        // because saving it again would keep only the first frame of an animation.
        if category == .image, formatID != "gif", imageIOTargets.contains(formatID), available(.imageio) {
            results.append(OutputFormat(id: formatID, label: "\(labels[formatID] ?? formatID.uppercased()), adjusted",
                                        fileExtension: extensionFor(formatID), engine: .imageio))
        }
        return results
    }

    /// Pandoc's name for a format.
    static func pandocName(_ id: String, input: Bool) -> String? {
        switch id {
        case "md": return "markdown"
        case "txt": return input ? "markdown" : "plain"
        case "html": return "html"
        case "docx": return "docx"
        case "odt": return "odt"
        case "rtf": return "rtf"
        case "epub": return "epub"
        case "ipynb": return input ? "ipynb" : nil
        default: return nil
        }
    }
}
