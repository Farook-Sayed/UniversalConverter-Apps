import XCTest
import ConverterCore

/// Checks that every file produced by scripts/make-test-files.sh is identified correctly.
/// Skips when TestFiles/ has not been generated yet.
final class SampleFilesTests: XCTestCase {

    private struct Expectation {
        let path: String
        let formatID: String
        let category: MediaCategory
        let mismatch: Bool
    }

    private static let expectations: [Expectation] = [
        // Video
        .init(path: "video/sample.mp4", formatID: "mp4", category: .video, mismatch: false),
        .init(path: "video/sample.mkv", formatID: "mkv", category: .video, mismatch: false),
        .init(path: "video/sample.webm", formatID: "webm", category: .video, mismatch: false),
        .init(path: "video/sample.avi", formatID: "avi", category: .video, mismatch: false),
        .init(path: "video/sample.mov", formatID: "mov", category: .video, mismatch: false),
        .init(path: "video/silent.mp4", formatID: "mp4", category: .video, mismatch: false),
        .init(path: "video/sample.wmv", formatID: "wmv", category: .video, mismatch: false),
        .init(path: "video/sample.flv", formatID: "flv", category: .video, mismatch: false),
        .init(path: "video/sample.3gp", formatID: "3gp", category: .video, mismatch: false),
        .init(path: "video/sample.m2ts", formatID: "m2ts", category: .video, mismatch: false),
        .init(path: "video/sample.mpg", formatID: "mpg", category: .video, mismatch: false),
        .init(path: "video/sample.vob", formatID: "vob", category: .video, mismatch: false),
        // Subtitles
        .init(path: "subtitles/sample.srt", formatID: "srt", category: .subtitle, mismatch: false),
        .init(path: "subtitles/sample.vtt", formatID: "vtt", category: .subtitle, mismatch: false),
        .init(path: "subtitles/sample.ass", formatID: "ass", category: .subtitle, mismatch: false),
        // Notebooks
        .init(path: "notebooks/sample.ipynb", formatID: "ipynb", category: .markup, mismatch: false),
        // E-books made with Calibre (optional: they need Calibre to be installed)
        .init(path: "ebooks/sample.mobi", formatID: "mobi", category: .ebook, mismatch: false),
        .init(path: "ebooks/sample.azw3", formatID: "azw3", category: .ebook, mismatch: false),
        .init(path: "ebooks/sample.fb2", formatID: "fb2", category: .ebook, mismatch: false),
        // PostScript and EPS
        .init(path: "postscript/sample.ps", formatID: "ps", category: .postscript, mismatch: false),
        .init(path: "postscript/sample.eps", formatID: "eps", category: .postscript, mismatch: false),
        // 3D models
        .init(path: "models/sample.obj", formatID: "obj", category: .model3d, mismatch: false),
        .init(path: "models/sample.stl", formatID: "stl", category: .model3d, mismatch: false),
        .init(path: "models/sample.ply", formatID: "ply", category: .model3d, mismatch: false),
        .init(path: "models/sample.dae", formatID: "dae", category: .model3d, mismatch: false),
        .init(path: "models/sample.gltf", formatID: "gltf", category: .model3d, mismatch: false),
        .init(path: "models/sample.glb", formatID: "glb", category: .model3d, mismatch: false),
        // Fonts (generated from the Mac's own Arial, so these are optional)
        .init(path: "fonts/sample.ttf", formatID: "ttf", category: .font, mismatch: false),
        .init(path: "fonts/sample.woff", formatID: "woff", category: .font, mismatch: false),
        .init(path: "fonts/sample.woff2", formatID: "woff2", category: .font, mismatch: false),
        // Audio
        .init(path: "audio/sample.mp3", formatID: "mp3", category: .audio, mismatch: false),
        .init(path: "audio/sample.wav", formatID: "wav", category: .audio, mismatch: false),
        .init(path: "audio/sample.flac", formatID: "flac", category: .audio, mismatch: false),
        .init(path: "audio/sample.m4a", formatID: "m4a", category: .audio, mismatch: false),
        .init(path: "audio/sample.ogg", formatID: "ogg", category: .audio, mismatch: false),
        // Images
        .init(path: "images/sample.png", formatID: "png", category: .image, mismatch: false),
        .init(path: "images/sample.jpg", formatID: "jpg", category: .image, mismatch: false),
        .init(path: "images/sample.gif", formatID: "gif", category: .image, mismatch: false),
        .init(path: "images/animated.gif", formatID: "gif", category: .image, mismatch: false),
        .init(path: "images/sample.webp", formatID: "webp", category: .image, mismatch: false),
        .init(path: "images/sample.bmp", formatID: "bmp", category: .image, mismatch: false),
        .init(path: "images/sample.tiff", formatID: "tiff", category: .image, mismatch: false),
        .init(path: "images/sample.avif", formatID: "avif", category: .image, mismatch: false),
        // Vector
        .init(path: "vector/sample.svg", formatID: "svg", category: .vector, mismatch: false),
        // Documents
        .init(path: "documents/sample.docx", formatID: "docx", category: .document, mismatch: false),
        .init(path: "documents/sample.doc", formatID: "doc", category: .document, mismatch: false),
        .init(path: "documents/sample.odt", formatID: "odt", category: .document, mismatch: false),
        .init(path: "documents/sample.rtf", formatID: "rtf", category: .document, mismatch: false),
        .init(path: "documents/sample.pdf", formatID: "pdf", category: .document, mismatch: false),
        // Spreadsheets
        .init(path: "spreadsheets/sample.xlsx", formatID: "xlsx", category: .spreadsheet, mismatch: false),
        .init(path: "spreadsheets/sample.xls", formatID: "xls", category: .spreadsheet, mismatch: false),
        .init(path: "spreadsheets/sample.ods", formatID: "ods", category: .spreadsheet, mismatch: false),
        .init(path: "spreadsheets/sample.csv", formatID: "csv", category: .spreadsheet, mismatch: false),
        // Presentations
        .init(path: "presentations/sample.pptx", formatID: "pptx", category: .presentation, mismatch: false),
        .init(path: "presentations/sample.ppt", formatID: "ppt", category: .presentation, mismatch: false),
        .init(path: "presentations/sample.odp", formatID: "odp", category: .presentation, mismatch: false),
        // Markup
        .init(path: "markup/sample.md", formatID: "md", category: .markup, mismatch: false),
        .init(path: "markup/sample.html", formatID: "html", category: .markup, mismatch: false),
        .init(path: "markup/sample.txt", formatID: "txt", category: .markup, mismatch: false),
        .init(path: "markup/sample.epub", formatID: "epub", category: .markup, mismatch: false),
        // Code
        .init(path: "code/hello.py", formatID: "python", category: .code, mismatch: false),
        .init(path: "code/big_script.py", formatID: "python", category: .code, mismatch: false),
        .init(path: "code/Hello.java", formatID: "java", category: .code, mismatch: false),
        .init(path: "code/hello.c", formatID: "c", category: .code, mismatch: false),
        .init(path: "code/hello.cpp", formatID: "cpp", category: .code, mismatch: false),
        .init(path: "code/hello.rs", formatID: "rust", category: .code, mismatch: false),
        .init(path: "code/hello.js", formatID: "javascript", category: .code, mismatch: false),
        .init(path: "code/hello.ts", formatID: "typescript", category: .code, mismatch: false),
        .init(path: "code/hello.rb", formatID: "ruby", category: .code, mismatch: false),
        .init(path: "code/hello.go", formatID: "go", category: .code, mismatch: false),
        .init(path: "code/hello.cs", formatID: "csharp", category: .code, mismatch: false),
        // Archives: detected, and converted to the other archive formats
        .init(path: "archives/sample.zip", formatID: "zip", category: .archive, mismatch: false),
        .init(path: "archives/sample.7z", formatID: "7z", category: .archive, mismatch: false),
        .init(path: "archives/sample.tar.gz", formatID: "targz", category: .archive, mismatch: false),
        // Unknown
        .init(path: "unknown/mystery.xyz", formatID: "xyz", category: .unknown, mismatch: false),
        // Mislabelled: the content wins and the mismatch is flagged
        .init(path: "mislabelled/photo-that-is-really-png.jpg", formatID: "png", category: .image, mismatch: true),
        .init(path: "mislabelled/report-that-is-really-docx.pdf", formatID: "docx", category: .document, mismatch: true),
        // Edge cases
        .init(path: "edge-cases/empty.txt", formatID: "txt", category: .markup, mismatch: false),
        .init(path: "edge-cases/hello-copy.py", formatID: "python", category: .code, mismatch: false),
        .init(path: "edge-cases/hello with spaces & symbols.py", formatID: "python", category: .code, mismatch: false),
    ]

    /// The TestFiles folder sits in the project root, three levels above this file.
    private var sampleRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // ConverterCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // project root
            .appendingPathComponent("TestFiles", isDirectory: true)
    }

    func testEverySampleFileIsDetectedCorrectly() throws {
        guard FileManager.default.fileExists(atPath: sampleRoot.path) else {
            throw XCTSkip("Run scripts/make-test-files.sh first.")
        }
        let detector = FileDetector()
        for expected in Self.expectations {
            let url = sampleRoot.appendingPathComponent(expected.path)
            guard FileManager.default.fileExists(atPath: url.path) else {
                // Font samples depend on fonts that exist on some Macs and not others.
                if !expected.path.hasPrefix("fonts/") && !expected.path.hasPrefix("ebooks/") {
                    XCTFail("Missing sample file: \(expected.path)")
                }
                continue
            }
            let detected = try detector.detect(url: url)
            XCTAssertEqual(detected.formatID, expected.formatID, expected.path)
            XCTAssertEqual(detected.category, expected.category, expected.path)
            XCTAssertEqual(detected.extensionMismatch, expected.mismatch, expected.path)
        }
    }

    func testArchivesOfferConversionsAndUnknownFilesDoNot() throws {
        guard FileManager.default.fileExists(atPath: sampleRoot.path) else {
            throw XCTSkip("Run scripts/make-test-files.sh first.")
        }
        let detector = FileDetector()
        for path in ["archives/sample.zip", "archives/sample.7z", "archives/sample.tar.gz", "documents/sample.pdf"] {
            let detected = try detector.detect(url: sampleRoot.appendingPathComponent(path))
            XCTAssertFalse(FormatCatalog.targets(for: detected).isEmpty, "\(path) should offer conversions")
        }
        for path in ["unknown/mystery.xyz"] {
            let detected = try detector.detect(url: sampleRoot.appendingPathComponent(path))
            XCTAssertTrue(FormatCatalog.targets(for: detected).isEmpty, "\(path) should offer no conversions")
        }
    }
}
