import XCTest
import ConverterCore

final class PreflightTests: XCTestCase {

    func testLossyNotesWarnWhereQualityIsLost() {
        XCTAssertNotNil(Preflight.lossyNote(sourceCategory: .video, sourceID: "mp4", targetID: "gif"))
        XCTAssertNotNil(Preflight.lossyNote(sourceCategory: .audio, sourceID: "mp3", targetID: "ogg"))
        XCTAssertNotNil(Preflight.lossyNote(sourceCategory: .image, sourceID: "png", targetID: "jpg"))
        XCTAssertNotNil(Preflight.lossyNote(sourceCategory: .document, sourceID: "docx", targetID: "md"))
        XCTAssertNotNil(Preflight.lossyNote(sourceCategory: .spreadsheet, sourceID: "xlsx", targetID: "csv"))
    }

    func testNoNoteWhenNothingIsLost() {
        XCTAssertNil(Preflight.lossyNote(sourceCategory: .video, sourceID: "mp4", targetID: "mkv"))
        XCTAssertNil(Preflight.lossyNote(sourceCategory: .image, sourceID: "png", targetID: "webp"))
        XCTAssertNil(Preflight.lossyNote(sourceCategory: .font, sourceID: "ttf", targetID: "woff2"))
    }

    func testLowDiskSpaceIsCautioned() {
        let finding = Preflight.spaceFinding(fileSize: 100 * 1024 * 1024, freeBytes: 500 * 1024 * 1024)
        XCTAssertEqual(finding?.severity, .caution)
    }

    func testPlentyOfDiskSpaceGivesNoFinding() {
        XCTAssertNil(Preflight.spaceFinding(fileSize: 100 * 1024 * 1024, freeBytes: 200 * 1024 * 1024 * 1024))
        XCTAssertNil(Preflight.spaceFinding(fileSize: 100, freeBytes: nil))
    }

    func testLargeFilesGetAnInfoNote() {
        XCTAssertEqual(Preflight.sizeFinding(fileSize: 600 * 1024 * 1024)?.severity, .info)
        XCTAssertNil(Preflight.sizeFinding(fileSize: 10 * 1024 * 1024))
    }

    func testSyntaxCheckerNamesAreKnown() {
        XCTAssertEqual(Preflight.syntaxCheckerName(for: "python"), "Python 3.12")
        XCTAssertEqual(Preflight.syntaxCheckerName(for: "typescript"), "TypeScript (tsc)")
        XCTAssertNil(Preflight.syntaxCheckerName(for: "csharp"))
    }

    func testPlainNamesForFormats() {
        XCTAssertEqual(FormatCatalog.displayName(ofFormat: "docx"), "Word document")
        XCTAssertEqual(FormatCatalog.displayName(ofFormat: "png"), "PNG image")
        XCTAssertEqual(FormatCatalog.displayName(ofFormat: "python"), "Python source code")
        XCTAssertNil(FormatCatalog.displayName(ofFormat: "no-such-format"))
    }

    func testWrongFileNameIsCautioned() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fc-mismatch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("photo.jpg")
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]).write(to: file)

        let detected = try FileDetector().detect(url: file)
        XCTAssertTrue(detected.extensionMismatch)
        let route = try XCTUnwrap(FormatCatalog.targets(for: detected).first)
        let findings = Preflight.findings(for: detected, target: route, outputFolder: dir,
                                          tools: ToolLocator(), fontPython: nil)
        XCTAssertTrue(findings.contains { $0.severity == .caution && $0.message.contains("really PNG") })
    }

    func testEveryToolTheAppUsesIsListed() {
        let names = ToolLocator().statusOfAllTools().map(\.name)
        for expected in ["FFmpeg", "ImageMagick", "LibreOffice", "Pandoc", "7-Zip", "Poppler",
                         "Ghostscript", "Assimp", "Calibre", "Ollama"] {
            XCTAssertTrue(names.contains(expected), "\(expected) should be listed in Settings")
        }
    }

    func testFolderThatDoesNotExistYetIsAcceptedWhenItsParentIsWritable() {
        let future = FileManager.default.temporaryDirectory
            .appendingPathComponent("fc-not-created-\(UUID().uuidString)/results", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: future.path))
        XCTAssertTrue(Preflight.canWrite(toFolder: future))
    }

    func testReadOnlyLocationIsRefused() {
        XCTAssertFalse(Preflight.canWrite(toFolder: URL(fileURLWithPath: "/System/Library/not-allowed")))
    }

    func testEmptyFileIsBlocked() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fc-preflight-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let empty = dir.appendingPathComponent("empty.txt")
        FileManager.default.createFile(atPath: empty.path, contents: Data())

        let file = try FileDetector().detect(url: empty)
        let target = try XCTUnwrap(FormatCatalog.targets(for: file).first)
        let findings = Preflight.findings(for: file, target: target, outputFolder: dir,
                                          tools: ToolLocator(), fontPython: nil)
        XCTAssertTrue(findings.contains { $0.severity == .blocking && $0.message.contains("empty") })
    }
}
