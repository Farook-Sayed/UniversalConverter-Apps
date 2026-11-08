import Foundation

/// Something the user should know before or after a conversion.
public struct Finding: Equatable, Sendable, Identifiable {
    public enum Severity: String, Sendable {
        /// Good to know. Conversion goes ahead.
        case info
        /// The result may be worse than expected. Conversion goes ahead.
        case caution
        /// Conversion cannot succeed as set up. The user must fix something first.
        case blocking
    }

    public let severity: Severity
    public let message: String

    public var id: String { message }

    public init(severity: Severity, message: String) {
        self.severity = severity
        self.message = message
    }
}

/// Checks made before a conversion starts. Each rule is a small pure function so it can be tested.
public enum Preflight {

    /// Files at or above this size get a note that the conversion will take a while.
    public static let largeFileBytes: Int64 = 500 * 1024 * 1024

    /// All findings for one file and one target.
    public static func findings(for file: DetectedFile, target: Route, outputFolder: URL,
                                tools: ToolLocator, fontPython: URL?) -> [Finding] {
        var result: [Finding] = []
        let size = fileSize(file.url)

        if size == 0 {
            result.append(Finding(severity: .blocking, message: "\(file.url.lastPathComponent) is empty, so there is nothing to convert."))
        }
        if file.extensionMismatch {
            let name = file.url.pathExtension.isEmpty ? "the file name" : "the name ends in .\(file.url.pathExtension)"
            result.append(Finding(severity: .caution,
                                  message: "\(name.prefix(1).uppercased() + name.dropFirst()), but the file is really \(file.formatID.uppercased()). The contents were used."))
        }
        // Every tool the route uses must be installed, not only the last one.
        for step in target.steps {
            if let missing = missingToolFinding(for: step.output, file: file, tools: tools, fontPython: fontPython) {
                result.append(missing)
            }
        }
        if target.isMultiStep {
            let path = ([file.formatID.uppercased()] + target.steps.map { $0.output.fileExtension.uppercased() })
                .joined(separator: " → ")
            result.append(Finding(severity: .info,
                                  message: "This takes \(target.steps.count) steps, each with its own tool: \(path). Quality can drop a little at each step."))
        }
        if !canWrite(toFolder: outputFolder) {
            result.append(Finding(severity: .blocking,
                                  message: "Universal Converter cannot write to \(outputFolder.lastPathComponent). Choose another output folder in Settings."))
        }
        if let space = spaceFinding(fileSize: size, freeBytes: freeBytes(at: outputFolder)) {
            result.append(space)
        }
        if let large = sizeFinding(fileSize: size) {
            result.append(large)
        }
        if let lossy = lossyNote(sourceCategory: file.category, sourceID: file.formatID, targetID: target.id) {
            result.append(Finding(severity: .caution, message: lossy))
        }
        if file.category == .code, let checker = syntaxCheckerName(for: target.id), tools.locate(checkerBinaries(for: target.id)) == nil {
            result.append(Finding(severity: .info,
                                  message: "\(checker) is not installed, so the translated code will not be syntax-checked."))
        }
        return result
    }

    // MARK: Rules

    /// Lost quality or detail when converting this source to this target. Nil when nothing is lost.
    public static func lossyNote(sourceCategory: MediaCategory, sourceID: String, targetID: String) -> String? {
        let lossyAudio: Set<String> = ["mp3", "m4a", "ogg"]
        let lossyVideo: Set<String> = ["mp4", "mkv", "webm", "avi", "mov", "wmv", "flv", "3gp", "m2ts", "mpg", "vob"]

        if (sourceCategory == .ebook || sourceID == "epub") && (targetID == "pdf" || targetID == "txt") {
            return "Reflowable e-books lose their layout when saved as PDF or plain text."
        }
        if (sourceID == "pdf" || sourceCategory == .postscript) && (targetID == "png" || targetID == "jpg") {
            return "Only the first page is saved as an image."
        }
        if targetID == "gif" && sourceCategory == .video {
            return "GIF has no sound and only 256 colours, so expect lower quality."
        }
        if lossyAudio.contains(sourceID) && lossyAudio.contains(targetID) {
            return "Converting between lossy audio formats loses a little quality each time."
        }
        if lossyVideo.contains(sourceID) && (targetID == "mp4" || targetID == "webm") && sourceID != targetID {
            return "Video is re-encoded, which takes time and can lower quality slightly."
        }
        if sourceCategory == .image || sourceCategory == .vector {
            let transparent: Set<String> = ["png", "gif", "webp", "tiff", "svg", "avif", "heic"]
            if targetID == "jpg" && (transparent.contains(sourceID) || sourceCategory == .vector) {
                return "JPEG has no transparency, so transparent areas become solid."
            }
            if targetID == "gif" && sourceID != "gif" {
                return "GIF is limited to 256 colours, so photos and gradients will look banded."
            }
        }
        if sourceCategory == .document && targetID == "md" {
            return "Markdown keeps the text and basic structure, but loses layout, images and styling."
        }
        if sourceCategory == .markup && targetID == "pdf" {
            return "The PDF layout comes from the converter and can differ from a web browser."
        }
        if sourceCategory == .spreadsheet && targetID == "csv" {
            return "CSV keeps only the first sheet and drops all formatting and formulas."
        }
        if sourceCategory == .subtitle && targetID == "srt" && sourceID == "ass" {
            return "Subtitle styling and positioning are removed when saving as SRT."
        }
        if sourceCategory == .markup && sourceID == "ipynb" && targetID == "md" {
            return "Notebook outputs such as plots and tables are left out of the Markdown."
        }
        if sourceCategory == .code {
            return "The translation is checked for syntax only. Test the result before you rely on it."
        }
        return nil
    }

    /// A blocking finding when the tool that performs this conversion is not installed.
    public static func missingToolFinding(for target: OutputFormat, file: DetectedFile,
                                          tools: ToolLocator, fontPython: URL?) -> Finding? {
        switch target.engine {
        case .ffmpeg:
            return tools.locate(["ffmpeg"]) == nil ? Finding(severity: .blocking, message: "FFmpeg is not installed. Install it with: brew install ffmpeg") : nil
        case .imagemagick:
            return tools.locate(["magick", "convert"]) == nil ? Finding(severity: .blocking, message: "ImageMagick is not installed. Install it with: brew install imagemagick") : nil
        case .libreoffice:
            return tools.locate(["soffice"]) == nil ? Finding(severity: .blocking, message: "LibreOffice is not installed. Install it with: brew install --cask libreoffice") : nil
        case .pandoc:
            return tools.locate(["pandoc"]) == nil ? Finding(severity: .blocking, message: "Pandoc is not installed. Install it with: brew install pandoc") : nil
        case .archiver:
            let needsSevenZip = target.id == "zip" || target.id == "7z" || file.formatID == "zip" || file.formatID == "7z"
            return needsSevenZip && tools.locate(["7z", "7zz"]) == nil ? Finding(severity: .blocking, message: "7-Zip is not installed. Install it with: brew install p7zip") : nil
        case .ollama:
            return tools.locate(["ollama"]) == nil ? Finding(severity: .blocking, message: "Ollama is not installed. Install it with: brew install ollama") : nil
        case .poppler:
            return tools.locate(["pdftotext", "pdftoppm"]) == nil
                ? Finding(severity: .blocking, message: "Poppler is not installed. Install it with: brew install poppler") : nil
        case .ghostscript:
            return tools.locate(["gs"]) == nil
                ? Finding(severity: .blocking, message: "Ghostscript is not installed. Install it with: brew install ghostscript") : nil
        case .calibre:
            return tools.locate(["ebook-convert"]) == nil
                ? Finding(severity: .blocking, message: "Calibre is not installed. Install it with: brew install --cask calibre") : nil
        case .assimp:
            return tools.locate(["assimp"]) == nil
                ? Finding(severity: .blocking, message: "Assimp is not installed. Install it with: brew install assimp") : nil
        case .fonttools:
            return fontPython == nil ? Finding(severity: .blocking, message: "fontTools is not set up. See the user guide, section 2.") : nil
        }
    }

    /// A caution when the free space may not cover the output. A warning about size comes separately.
    public static func spaceFinding(fileSize: Int64, freeBytes: Int64?) -> Finding? {
        guard let free = freeBytes, fileSize > 0 else { return nil }
        let needed = fileSize * 3 + 1024 * 1024 * 1024
        if free < needed {
            return Finding(severity: .caution,
                           message: "Only \(bytesText(free)) is free. Conversions can need about three times the file's size.")
        }
        return nil
    }

    public static func sizeFinding(fileSize: Int64) -> Finding? {
        guard fileSize >= largeFileBytes else { return nil }
        return Finding(severity: .info, message: "This is a large file (\(bytesText(fileSize))). The conversion may take several minutes.")
    }

    /// The syntax checker's display name for a language, if one is set up.
    public static func syntaxCheckerName(for languageID: String) -> String? {
        switch languageID {
        case "python": return "Python 3.12"
        case "ruby": return "Ruby"
        case "c": return "clang (C)"
        case "cpp": return "clang (C++)"
        case "java": return "javac"
        case "rust": return "rustc"
        case "go": return "gofmt"
        case "javascript": return "Node.js"
        case "typescript": return "TypeScript (tsc)"
        default: return nil
        }
    }

    static func checkerBinaries(for languageID: String) -> [String] {
        switch languageID {
        case "python": return ["python3.12"]
        case "ruby": return ["ruby"]
        case "c", "cpp": return ["clang"]
        case "java": return ["javac"]
        case "rust": return ["rustc"]
        case "go": return ["gofmt"]
        case "javascript": return ["node"]
        case "typescript": return ["tsc"]
        default: return []
        }
    }

    // MARK: Helpers

    /// The folder itself, or the closest parent that exists. A results folder that has not been created
    /// yet is fine: the app creates it, as long as its parent can be written to.
    static func nearestExistingFolder(of folder: URL) -> URL {
        var candidate = folder
        while !FileManager.default.fileExists(atPath: candidate.path), candidate.pathComponents.count > 1 {
            candidate = candidate.deletingLastPathComponent()
        }
        return candidate
    }

    public static func canWrite(toFolder folder: URL) -> Bool {
        FileManager.default.isWritableFile(atPath: nearestExistingFolder(of: folder).path)
    }

    public static func fileSize(_ url: URL) -> Int64 {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
        return size ?? 0
    }

    public static func freeBytes(at folder: URL) -> Int64? {
        let values = try? nearestExistingFolder(of: folder)
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    public static func bytesText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
