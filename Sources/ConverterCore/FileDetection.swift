import Foundation

/// The broad family a file belongs to.
public enum MediaCategory: String, Sendable, CaseIterable {
    case video, audio, image, vector, document, spreadsheet, presentation, markup, code, archive, subtitle, font
    case postscript, model3d, ebook, unknown
}

/// How the format was identified.
public enum DetectionMethod: String, Sendable {
    /// Matched a binary signature in the file's first bytes. Most reliable.
    case magicBytes
    /// No binary signature; the bytes are valid UTF-8 text and the extension decided the format.
    case textWithExtension
    /// Nothing matched; the extension is the only clue.
    case extensionOnly
}

/// The result of looking at a file.
public struct DetectedFile: Equatable, Sendable {
    public let url: URL
    public let category: MediaCategory
    /// Canonical lowercase id, e.g. "png", "pdf", "docx", "python".
    public let formatID: String
    public let mimeType: String
    public let method: DetectionMethod
    /// True when the content looks like one format but the file name says another.
    public let extensionMismatch: Bool

    public init(url: URL, category: MediaCategory, formatID: String, mimeType: String,
                method: DetectionMethod, extensionMismatch: Bool) {
        self.url = url
        self.category = category
        self.formatID = formatID
        self.mimeType = mimeType
        self.method = method
        self.extensionMismatch = extensionMismatch
    }
}

/// Identifies a file from its content first and its extension second.
public struct FileDetector: Sendable {
    public init() {}

    /// Reads only the first 4 KB of the file.
    public func detect(url: URL) throws -> DetectedFile {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let head = try handle.read(upToCount: 4096) ?? Data()
        return detect(head: head, url: url)
    }

    /// Pure function over the file's first bytes, so it can be unit tested.
    public func detect(head: Data, url: URL) -> DetectedFile {
        let ext = FileNames.effectiveExtension(url)
        let bytes = [UInt8](head)

        // 1. Binary signatures.
        if let sig = Signatures.match(bytes) {
            var formatID = sig.formatID
            var category = sig.category
            var mime = sig.mime

            // Office/ODF/EPUB files are ZIP containers. Look inside to tell them apart.
            if formatID == "zip", let inner = Signatures.zipContainer(head: bytes) {
                formatID = inner.formatID
                category = inner.category
                mime = inner.mime
            }
            // Kindle files with the .azw3 or .azw name are AZW3. The container is the same as MOBI.
            if formatID == "mobi", ext == "azw3" || ext == "azw" {
                formatID = "azw3"
            }
            // MPEG program streams are .vob for DVD video. Keep .mpg and .mpeg files as MPG.
            if formatID == "vob", ext == "mpg" || ext == "mpeg" {
                formatID = "mpg"
            }
            // A gzip file named .tar.gz (or .tgz) is a compressed tar archive, not a single gzip file.
            if formatID == "gz", ext == "tar.gz" || ext == "tgz" {
                formatID = "targz"
                mime = "application/x-compressed-tar"
            }
            // Legacy Office files are OLE containers. The extension is the only clue left.
            if formatID == "ole", let legacy = Signatures.legacyOffice(forExtension: ext) {
                formatID = legacy.formatID
                category = legacy.category
                mime = legacy.mime
            }
            return DetectedFile(url: url, category: category, formatID: formatID, mimeType: mime,
                                method: .magicBytes,
                                extensionMismatch: isMismatch(ext: ext, formatID: formatID))
        }

        // 2. No binary signature. Accept it as text only if it decodes as UTF-8 with no NUL bytes.
        let looksLikeText = !bytes.contains(0) && String(data: head, encoding: .utf8) != nil
        if looksLikeText {
            let text = String(decoding: head.prefix(512), as: UTF8.self).lowercased()
            // PostScript and EPS are plain text that starts with %!PS.
            if text.hasPrefix("%!ps") {
                let formatID = ext == "eps" ? "eps" : "ps"
                return DetectedFile(url: url, category: .postscript, formatID: formatID,
                                    mimeType: "application/postscript", method: .magicBytes,
                                    extensionMismatch: isMismatch(ext: ext, formatID: formatID))
            }
            // Text that mentions <svg> is an SVG file only if its name does not say it is something else.
            // A Markdown file can contain an inline SVG cover image and is still Markdown.
            if text.contains("<svg"), ext == "svg" || Signatures.textFormat(forExtension: ext) == nil {
                return DetectedFile(url: url, category: .vector, formatID: "svg", mimeType: "image/svg+xml",
                                    method: .magicBytes, extensionMismatch: isMismatch(ext: ext, formatID: "svg"))
            }
            if let textFormat = Signatures.textFormat(forExtension: ext) {
                return DetectedFile(url: url, category: textFormat.category, formatID: textFormat.formatID,
                                    mimeType: textFormat.mime, method: .textWithExtension,
                                    extensionMismatch: false)
            }
            return DetectedFile(url: url, category: .unknown, formatID: "text", mimeType: "text/plain",
                                method: .textWithExtension, extensionMismatch: false)
        }

        // 3. Unknown binary. Some formats have no signature (M2TS, for example), so the extension decides.
        if let binary = Signatures.binaryFormat(forExtension: ext) {
            return DetectedFile(url: url, category: binary.category, formatID: binary.formatID,
                                mimeType: binary.mime, method: .extensionOnly, extensionMismatch: false)
        }
        if let textFormat = Signatures.textFormat(forExtension: ext) {
            return DetectedFile(url: url, category: textFormat.category, formatID: textFormat.formatID,
                                mimeType: textFormat.mime, method: .extensionOnly, extensionMismatch: false)
        }
        return DetectedFile(url: url, category: .unknown, formatID: ext.isEmpty ? "unknown" : ext,
                            mimeType: "application/octet-stream", method: .extensionOnly,
                            extensionMismatch: false)
    }

    private func isMismatch(ext: String, formatID: String) -> Bool {
        guard !ext.isEmpty else { return false }
        let aliases = FormatCatalog.extensions(forFormat: formatID)
        return !aliases.isEmpty && !aliases.contains(ext)
    }
}

/// File-name helpers for double extensions such as .tar.gz.
public enum FileNames {
    /// The extension, with "tar.gz" kept together.
    public static func effectiveExtension(_ url: URL) -> String {
        if url.lastPathComponent.lowercased().hasSuffix(".tar.gz") { return "tar.gz" }
        return url.pathExtension.lowercased()
    }

    /// The name without its extension(s): "report.tar.gz" becomes "report".
    public static func stem(_ url: URL) -> String {
        let name = url.lastPathComponent
        if name.lowercased().hasSuffix(".tar.gz") { return String(name.dropLast(7)) }
        return url.deletingPathExtension().lastPathComponent
    }
}

/// Binary signatures and extension-based text formats.
enum Signatures {
    struct Match {
        let formatID: String
        let category: MediaCategory
        let mime: String
    }

    static func match(_ b: [UInt8]) -> Match? {
        func at(_ sig: [UInt8], _ offset: Int = 0) -> Bool {
            guard b.count >= offset + sig.count else { return false }
            return Array(b[offset..<offset + sig.count]) == sig
        }
        func ascii(_ s: String, _ offset: Int = 0) -> Bool { at(Array(s.utf8), offset) }

        if at([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return .init(formatID: "png", category: .image, mime: "image/png") }
        if at([0xFF, 0xD8, 0xFF]) { return .init(formatID: "jpg", category: .image, mime: "image/jpeg") }
        if ascii("GIF87a") || ascii("GIF89a") { return .init(formatID: "gif", category: .image, mime: "image/gif") }
        if ascii("RIFF") && ascii("WEBP", 8) { return .init(formatID: "webp", category: .image, mime: "image/webp") }
        if ascii("RIFF") && ascii("WAVE", 8) { return .init(formatID: "wav", category: .audio, mime: "audio/wav") }
        if ascii("RIFF") && ascii("AVI ", 8) { return .init(formatID: "avi", category: .video, mime: "video/x-msvideo") }
        if at([0x49, 0x49, 0x2A, 0x00]) || at([0x4D, 0x4D, 0x00, 0x2A]) { return .init(formatID: "tiff", category: .image, mime: "image/tiff") }
        // BMP: "BM", then a 4-byte file size, then four reserved bytes that are always zero.
        // Checking the zeros keeps ordinary text that starts with "BM" from matching.
        if ascii("BM") && b.count >= 14 && at([0, 0, 0, 0], 6) {
            return .init(formatID: "bmp", category: .image, mime: "image/bmp")
        }
        if at([0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11]) {
            return .init(formatID: "wmv", category: .video, mime: "video/x-ms-asf")
        }
        if at([0x46, 0x4C, 0x56, 0x01]) { return .init(formatID: "flv", category: .video, mime: "video/x-flv") }
        if at([0x00, 0x00, 0x01, 0xBA]) { return .init(formatID: "vob", category: .video, mime: "video/mpeg") }
        if at([0x00, 0x01, 0x00, 0x00]) { return .init(formatID: "ttf", category: .font, mime: "font/ttf") }
        if ascii("OTTO") { return .init(formatID: "otf", category: .font, mime: "font/otf") }
        if ascii("wOFF") { return .init(formatID: "woff", category: .font, mime: "font/woff") }
        if ascii("wOF2") { return .init(formatID: "woff2", category: .font, mime: "font/woff2") }
        // Kindle files (MOBI, AZW3) keep "BOOKMOBI" at byte 60 of the first record.
        if b.count >= 68 && ascii("BOOKMOBI", 60) {
            return .init(formatID: "mobi", category: .ebook, mime: "application/x-mobipocket-ebook")
        }
        if at([0xC5, 0xD0, 0xD3, 0xC6]) { return .init(formatID: "eps", category: .postscript, mime: "application/postscript") }
        if ascii("glTF") { return .init(formatID: "glb", category: .model3d, mime: "model/gltf-binary") }
        if ascii("Kaydara FBX Binary") { return .init(formatID: "fbx", category: .model3d, mime: "model/fbx") }
        if ascii("%PDF") { return .init(formatID: "pdf", category: .document, mime: "application/pdf") }
        if at([0x1A, 0x45, 0xDF, 0xA3]) {
            let head = String(decoding: b.prefix(64), as: UTF8.self)
            return head.contains("webm")
                ? .init(formatID: "webm", category: .video, mime: "video/webm")
                : .init(formatID: "mkv", category: .video, mime: "video/x-matroska")
        }
        if ascii("ID3") || at([0xFF, 0xFB]) || at([0xFF, 0xF3]) || at([0xFF, 0xF2]) {
            return .init(formatID: "mp3", category: .audio, mime: "audio/mpeg")
        }
        if ascii("fLaC") { return .init(formatID: "flac", category: .audio, mime: "audio/flac") }
        if ascii("OggS") { return .init(formatID: "ogg", category: .audio, mime: "audio/ogg") }
        if ascii("ftyp", 4) {
            let brand = String(decoding: b.dropFirst(8).prefix(4), as: UTF8.self)
            switch brand {
            case "avif", "avis": return .init(formatID: "avif", category: .image, mime: "image/avif")
            case "heic", "heix", "mif1": return .init(formatID: "heic", category: .image, mime: "image/heic")
            case "M4A ", "M4B ": return .init(formatID: "m4a", category: .audio, mime: "audio/mp4")
            case "qt  ": return .init(formatID: "mov", category: .video, mime: "video/quicktime")
            case "3gp4", "3gp5", "3gp6", "3gp7", "3g2a": return .init(formatID: "3gp", category: .video, mime: "video/3gpp")
            default: return .init(formatID: "mp4", category: .video, mime: "video/mp4")
            }
        }
        if at([0x50, 0x4B, 0x03, 0x04]) || at([0x50, 0x4B, 0x05, 0x06]) {
            return .init(formatID: "zip", category: .archive, mime: "application/zip")
        }
        if at([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]) { return .init(formatID: "7z", category: .archive, mime: "application/x-7z-compressed") }
        if at([0x1F, 0x8B]) { return .init(formatID: "gz", category: .archive, mime: "application/gzip") }
        if ascii("Rar!") { return .init(formatID: "rar", category: .archive, mime: "application/vnd.rar") }
        if b.count >= 262 && ascii("ustar", 257) { return .init(formatID: "tar", category: .archive, mime: "application/x-tar") }
        if at([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]) { return .init(formatID: "ole", category: .document, mime: "application/x-ole-storage") }
        if ascii("{\\rtf") { return .init(formatID: "rtf", category: .document, mime: "application/rtf") }
        return nil
    }

    /// Looks inside a ZIP container for Office, OpenDocument and EPUB markers.
    static func zipContainer(head b: [UInt8]) -> Match? {
        let text = String(decoding: b, as: UTF8.self)
        if text.contains("application/epub+zip") {
            return .init(formatID: "epub", category: .markup, mime: "application/epub+zip")
        }
        if text.contains("application/vnd.oasis.opendocument.text") {
            return .init(formatID: "odt", category: .document, mime: "application/vnd.oasis.opendocument.text")
        }
        if text.contains("application/vnd.oasis.opendocument.spreadsheet") {
            return .init(formatID: "ods", category: .spreadsheet, mime: "application/vnd.oasis.opendocument.spreadsheet")
        }
        if text.contains("application/vnd.oasis.opendocument.presentation") {
            return .init(formatID: "odp", category: .presentation, mime: "application/vnd.oasis.opendocument.presentation")
        }
        if text.contains("word/") {
            return .init(formatID: "docx", category: .document, mime: "application/vnd.openxmlformats-officedocument.wordprocessingml.document")
        }
        if text.contains("xl/") {
            return .init(formatID: "xlsx", category: .spreadsheet, mime: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
        }
        if text.contains("ppt/") {
            return .init(formatID: "pptx", category: .presentation, mime: "application/vnd.openxmlformats-officedocument.presentationml.presentation")
        }
        return nil
    }

    /// Old Office files (.doc, .xls, .ppt) share one OLE signature. Use the extension to tell them apart.
    static func legacyOffice(forExtension ext: String) -> Match? {
        switch ext {
        case "doc": return .init(formatID: "doc", category: .document, mime: "application/msword")
        case "xls": return .init(formatID: "xls", category: .spreadsheet, mime: "application/vnd.ms-excel")
        case "ppt": return .init(formatID: "ppt", category: .presentation, mime: "application/vnd.ms-powerpoint")
        default: return nil
        }
    }

    /// Binary formats with no reliable signature. These are recognised by extension only.
    static func binaryFormat(forExtension ext: String) -> Match? {
        switch ext {
        case "m2ts", "mts": return .init(formatID: "m2ts", category: .video, mime: "video/mp2t")
        case "mpg", "mpeg": return .init(formatID: "mpg", category: .video, mime: "video/mpeg")
        case "vob": return .init(formatID: "vob", category: .video, mime: "video/dvd")
        default: return nil
        }
    }

    /// Plain-text formats, recognised by extension.
    static func textFormat(forExtension ext: String) -> Match? {
        if let code = FormatCatalog.codeLanguage(forExtension: ext) {
            return .init(formatID: code.id, category: .code, mime: "text/plain")
        }
        switch ext {
        case "md", "markdown": return .init(formatID: "md", category: .markup, mime: "text/markdown")
        case "html", "htm": return .init(formatID: "html", category: .markup, mime: "text/html")
        case "txt": return .init(formatID: "txt", category: .markup, mime: "text/plain")
        case "csv": return .init(formatID: "csv", category: .spreadsheet, mime: "text/csv")
        case "svg": return .init(formatID: "svg", category: .vector, mime: "image/svg+xml")
        case "srt": return .init(formatID: "srt", category: .subtitle, mime: "application/x-subrip")
        case "vtt": return .init(formatID: "vtt", category: .subtitle, mime: "text/vtt")
        case "ass", "ssa": return .init(formatID: "ass", category: .subtitle, mime: "text/x-ssa")
        case "ipynb": return .init(formatID: "ipynb", category: .markup, mime: "application/x-ipynb+json")
        // 3D models. Binary STL and PLY files have no signature, so the extension identifies them.
        case "obj": return .init(formatID: "obj", category: .model3d, mime: "model/obj")
        case "stl": return .init(formatID: "stl", category: .model3d, mime: "model/stl")
        case "ply": return .init(formatID: "ply", category: .model3d, mime: "model/ply")
        case "dae": return .init(formatID: "dae", category: .model3d, mime: "model/vnd.collada+xml")
        case "gltf": return .init(formatID: "gltf", category: .model3d, mime: "model/gltf+json")
        case "ps", "eps": return .init(formatID: ext, category: .postscript, mime: "application/postscript")
        case "fb2": return .init(formatID: "fb2", category: .ebook, mime: "application/x-fictionbook+xml")
        default: return nil
        }
    }
}
