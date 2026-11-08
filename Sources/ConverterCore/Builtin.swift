import Foundation

/// Conversions that use only what ships with macOS, so they work on a fresh install.
///
/// - Images: `sips` (PNG, JPEG, TIFF, GIF, BMP)
/// - Word and text: `textutil` (DOCX, DOC, RTF, HTML, TXT)
/// - Audio: `afconvert` (WAV, M4A)
/// - Archives: `zip`, `unzip` and `tar` (ZIP, TAR, TAR.GZ)
public enum BuiltinEngine {
    public static let rasterFormats: Set<String> = ["png", "jpg", "tiff", "gif", "bmp"]
    public static let wordFormats: Set<String> = ["docx", "doc", "rtf", "html", "txt"]
    public static let audioFormats: Set<String> = ["wav", "m4a"]
    public static let archiveFormats: Set<String> = ["zip", "tar", "targz"]

    /// Whether macOS can make this conversion by itself.
    public static func supports(sourceID: String, targetID: String) -> Bool {
        guard sourceID != targetID else { return false }
        return [rasterFormats, wordFormats, audioFormats, archiveFormats].contains {
            $0.contains(sourceID) && $0.contains(targetID)
        }
    }
}

extension Converter {
    /// Runs one built-in conversion. Each macOS tool writes `out.<ext>` into the work folder.
    func runBuiltin(input: DetectedFile, target: OutputFormat, workDir: URL, log: inout [String]) async throws -> URL {
        let source = input.formatID
        let output = workDir.appendingPathComponent("out.\(target.fileExtension)")
        if BuiltinEngine.rasterFormats.contains(source) {
            let format = target.id == "jpg" ? "jpeg" : target.id
            try await execute("sips", systemTool("sips"),
                              ["-s", "format", format, input.url.path, "--out", output.path], log: &log)
        } else if BuiltinEngine.wordFormats.contains(source) {
            try await execute("textutil", systemTool("textutil"),
                              ["-convert", target.id, "-output", output.path, input.url.path], log: &log)
        } else if BuiltinEngine.audioFormats.contains(source) {
            let settings = target.id == "m4a" ? ["-f", "m4af", "-d", "aac", "-b", "192000"] : ["-f", "WAVE", "-d", "LEI16"]
            try await execute("afconvert", systemTool("afconvert"), settings + [input.url.path, output.path], log: &log)
        } else {
            try await builtinArchive(input: input, target: target, output: output, workDir: workDir, log: &log)
        }
        return try requireOutput(output, tool: "macOS")
    }

    private func systemTool(_ name: String) -> URL {
        URL(fileURLWithPath: "/usr/bin/\(name)")
    }

    private func builtinArchive(input: DetectedFile, target: OutputFormat, output: URL, workDir: URL,
                                log: inout [String]) async throws {
        let extracted = workDir.appendingPathComponent("extracted", isDirectory: true)
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
        if input.formatID == "zip" {
            try await execute("unzip", systemTool("unzip"), ["-q", input.url.path, "-d", extracted.path], log: &log)
        } else {
            try await execute("tar", systemTool("tar"), ["-xf", input.url.path, "-C", extracted.path], log: &log)
        }
        let items = try FileManager.default.contentsOfDirectory(atPath: extracted.path).sorted()
        guard !items.isEmpty else {
            throw ConversionError.unsupported("The archive is empty, so there is nothing to convert.")
        }
        switch target.id {
        case "zip":
            try await execute("zip", systemTool("zip"), ["-q", "-r", output.path] + items, cwd: extracted, log: &log)
        case "targz":
            try await execute("tar", systemTool("tar"), ["-czf", output.path, "-C", extracted.path] + items, log: &log)
        default:
            try await execute("tar", systemTool("tar"), ["-cf", output.path, "-C", extracted.path] + items, log: &log)
        }
    }
}
