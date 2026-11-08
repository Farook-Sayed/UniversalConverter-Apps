import XCTest
import ConverterCore

/// Formats that work on a fresh Mac, with no optional tools installed.
final class StandardFormatsTests: XCTestCase {

    private let builtinOnly: (Engine) -> Bool = { $0 == .builtin }

    private func detected(_ formatID: String, _ category: MediaCategory, ext: String) -> DetectedFile {
        DetectedFile(url: URL(fileURLWithPath: "/tmp/input.\(ext)"), category: category, formatID: formatID,
                     mimeType: "application/octet-stream", method: .magicBytes, extensionMismatch: false)
    }

    private func route(_ id: String, _ routes: [Route]) -> Route? {
        routes.first { $0.id == id }
    }

    // MARK: Which conversions macOS can do

    func testBuiltinSupportTable() {
        XCTAssertTrue(BuiltinEngine.supports(sourceID: "png", targetID: "jpg"))
        XCTAssertTrue(BuiltinEngine.supports(sourceID: "docx", targetID: "txt"))
        XCTAssertTrue(BuiltinEngine.supports(sourceID: "zip", targetID: "targz"))
        XCTAssertTrue(BuiltinEngine.supports(sourceID: "wav", targetID: "m4a"))
        XCTAssertFalse(BuiltinEngine.supports(sourceID: "png", targetID: "webp"))
        XCTAssertFalse(BuiltinEngine.supports(sourceID: "mp4", targetID: "mp3"))
        XCTAssertFalse(BuiltinEngine.supports(sourceID: "png", targetID: "png"))
    }

    func testImagesConvertWithoutImageMagick() {
        let routes = FormatCatalog.targets(for: detected("png", .image, ext: "png"), available: builtinOnly)
        XCTAssertEqual(route("jpg", routes)?.engine, .builtin)
        XCTAssertNil(route("webp", routes), "WebP needs ImageMagick")
        XCTAssertNil(route("pdf", routes), "PDF output needs ImageMagick")
    }

    func testWordDocumentsConvertWithoutLibreOffice() {
        let routes = FormatCatalog.targets(for: detected("docx", .document, ext: "docx"), available: builtinOnly)
        XCTAssertEqual(route("txt", routes)?.engine, .builtin)
        XCTAssertNil(route("pdf", routes), "PDF needs LibreOffice")
    }

    func testMarkdownNeedsPandoc() {
        XCTAssertTrue(FormatCatalog.targets(for: detected("md", .markup, ext: "md"), available: builtinOnly).isEmpty)
    }

    func testArchivesConvertWithoutSevenZip() {
        let routes = FormatCatalog.targets(for: detected("zip", .archive, ext: "zip"), available: builtinOnly)
        XCTAssertEqual(route("targz", routes)?.engine, .builtin)
        XCTAssertNil(route("7z", routes), "7z needs 7-Zip")
    }

    func testAudioConvertsWithoutFFmpeg() {
        let routes = FormatCatalog.targets(for: detected("wav", .audio, ext: "wav"), available: builtinOnly)
        XCTAssertEqual(route("m4a", routes)?.engine, .builtin)
        XCTAssertNil(route("mp3", routes), "MP3 needs FFmpeg")
    }

    func testRARNeedsSevenZipAndReadsToZip() {
        // RAR is only readable with 7-Zip. Without it, nothing is offered.
        XCTAssertTrue(FormatCatalog.targets(for: detected("rar", .archive, ext: "rar"), available: builtinOnly).isEmpty)
        let routes = FormatCatalog.targets(for: detected("rar", .archive, ext: "rar"))
        XCTAssertEqual(route("zip", routes)?.engine, .archiver)
        XCTAssertNil(route("rar", routes), "RAR cannot be written")
    }

    func testVideoNeedsFFmpeg() {
        XCTAssertTrue(FormatCatalog.targets(for: detected("mp4", .video, ext: "mp4"), available: builtinOnly).isEmpty)
    }

    func testEverythingAvailableGivesTheFullMenu() {
        let routes = FormatCatalog.targets(for: detected("png", .image, ext: "png"))
        XCTAssertNotNil(route("webp", routes))
        XCTAssertNotEqual(route("jpg", routes)?.engine, .builtin, "ImageMagick is preferred when it is installed")
    }

    // MARK: The conversions themselves, with the macOS tools

    private func workFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fc-standard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func builtinRoute(from source: DetectedFile, to id: String, ext: String, category: MediaCategory) -> Route {
        Route(steps: [RouteStep(inputFormatID: source.formatID, inputCategory: source.category,
                                output: OutputFormat(id: id, label: id.uppercased(), fileExtension: ext, engine: .builtin),
                                outputCategory: category)])
    }

    func testPNGToJPEGWithSips() async throws {
        let folder = try workFolder()
        // A one-pixel PNG.
        let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="))
        let input = folder.appendingPathComponent("dot.png")
        try png.write(to: input)
        let source = try FileDetector().detect(url: input)
        let result = try await Converter().convert(ConversionRequest(
            input: source, route: builtinRoute(from: source, to: "jpg", ext: "jpg", category: .image),
            outputDirectory: folder))
        XCTAssertEqual(try FileDetector().detect(url: result.outputURL).formatID, "jpg")
    }

    func testRTFToTextWithTextutil() async throws {
        let folder = try workFolder()
        let input = folder.appendingPathComponent("memo.rtf")
        try "{\\rtf1\\ansi Hello from a rich text file.}".write(to: input, atomically: true, encoding: .utf8)
        let source = try FileDetector().detect(url: input)
        XCTAssertEqual(source.formatID, "rtf")
        let result = try await Converter().convert(ConversionRequest(
            input: source, route: builtinRoute(from: source, to: "txt", ext: "txt", category: .markup),
            outputDirectory: folder))
        let text = try String(contentsOf: result.outputURL, encoding: .utf8)
        XCTAssertTrue(text.contains("Hello from a rich text file"))
    }

    func testZipToTarGzWithZipAndTar() async throws {
        let folder = try workFolder()
        let note = folder.appendingPathComponent("note.txt")
        try "hello".write(to: note, atomically: true, encoding: .utf8)
        let zip = folder.appendingPathComponent("bundle.zip")
        _ = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/zip"),
                                        arguments: ["-q", "-j", zip.path, note.path])
        let source = try FileDetector().detect(url: zip)
        let result = try await Converter().convert(ConversionRequest(
            input: source, route: builtinRoute(from: source, to: "targz", ext: "tar.gz", category: .archive),
            outputDirectory: folder))
        XCTAssertEqual(try FileDetector().detect(url: result.outputURL).formatID, "targz")
    }

    func testWAVToM4AWithAfconvert() async throws {
        let folder = try workFolder()
        let input = folder.appendingPathComponent("tone.wav")
        try silentWAV(seconds: 0.5).write(to: input)
        let source = try FileDetector().detect(url: input)
        XCTAssertEqual(source.formatID, "wav")
        let result = try await Converter().convert(ConversionRequest(
            input: source, route: builtinRoute(from: source, to: "m4a", ext: "m4a", category: .audio),
            outputDirectory: folder))
        XCTAssertEqual(try FileDetector().detect(url: result.outputURL).formatID, "m4a")
    }

    /// A short, silent, 16-bit mono WAV file.
    private func silentWAV(seconds: Double) -> Data {
        let rate: UInt32 = 44100
        let samples = Int(Double(rate) * seconds)
        var data = Data()
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8))
        append32(UInt32(36 + samples * 2))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append32(16)
        append16(1)            // PCM
        append16(1)            // mono
        append32(rate)
        append32(rate * 2)
        append16(2)
        append16(16)
        data.append(contentsOf: Array("data".utf8))
        append32(UInt32(samples * 2))
        data.append(Data(count: samples * 2))
        return data
    }
}
