import XCTest
import ConverterCore

final class ToolingTests: XCTestCase {

    func testOutputNamingNeverOverwrites() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fc-naming-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let first = OutputNaming.uniqueURL(stem: "report", ext: "pdf", in: dir)
        XCTAssertEqual(first.lastPathComponent, "report.pdf")
        FileManager.default.createFile(atPath: first.path, contents: Data())

        let second = OutputNaming.uniqueURL(stem: "report", ext: "pdf", in: dir)
        XCTAssertEqual(second.lastPathComponent, "report (2).pdf")
    }

    func testJavaClassNamesAreLegal() {
        XCTAssertEqual(FormatCatalog.javaClassName(from: "hello-copy"), "hello_copy")
        XCTAssertEqual(FormatCatalog.javaClassName(from: "1st file"), "_1st_file")
        XCTAssertEqual(FormatCatalog.javaClassName(from: "class"), "class_")
        XCTAssertEqual(FormatCatalog.javaClassName(from: ""), "Main")
        XCTAssertEqual(FormatCatalog.javaClassName(from: "Hello"), "Hello")
    }

    func testCodeCleanerRemovesFences() {
        let raw = "```python\nprint('hi')\n```\n"
        XCTAssertEqual(CodeOutputCleaner.clean(raw), "print('hi')\n")
    }

    func testCodeCleanerKeepsPlainCode() {
        XCTAssertEqual(CodeOutputCleaner.clean("int x = 1;"), "int x = 1;\n")
    }

    func testCodeCleanerReturnsEmptyForBlankReply() {
        XCTAssertEqual(CodeOutputCleaner.clean("\n  \n"), "")
    }

    func testJavaPromptRequiresMatchingClassName() {
        let py = FormatCatalog.codeLanguage(forID: "python")!
        let java = FormatCatalog.codeLanguage(forID: "java")!
        let prompt = CodePrompt.make(source: py, target: java, code: "print(1)", className: "App")
        XCTAssertTrue(prompt.contains("The public class must be named App."))
        XCTAssertTrue(prompt.contains("print(1)"))
    }

    func testFFmpegAudioTargetsDropVideo() {
        for target in ["mp3", "wav", "flac", "m4a", "ogg"] {
            XCTAssertTrue(Converter.ffmpegOptions(for: target).contains("-vn"), "\(target) should drop video")
        }
    }

    func testFFmpegGIFDropsAudio() {
        XCTAssertTrue(Converter.ffmpegOptions(for: "gif").contains("-an"))
    }

    func testToolLocatorFindsStandardBinary() {
        XCTAssertNotNil(ToolLocator().locate(["sh"]))
    }

    func testToolLocatorReportsMissingBinary() {
        XCTAssertNil(ToolLocator().locate(["definitely-not-a-real-tool-xyz"]))
    }

    func testOllamaPromptIsSentToGenerateEndpointFormat() {
        // The client must not be able to reach a different host by accident.
        let client = OllamaClient()
        XCTAssertEqual(client.baseURL.host, "localhost")
        XCTAssertEqual(client.baseURL.port, 11434)
    }
}
