import XCTest
import ConverterCore

/// These tests run the real tools installed on this Mac. A test is skipped when its tool is missing.
final class ConversionIntegrationTests: XCTestCase {

    private var workDir: URL!
    private let tools = ToolLocator()
    private let detector = FileDetector()

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fc-itest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    /// Runs a tool and fails the test if it exits non-zero.
    private func run(_ names: [String], _ arguments: [String]) async throws {
        guard let tool = tools.locate(names) else {
            throw XCTSkip("\(names[0]) is not installed")
        }
        let result = try await ProcessRunner.run(tool, arguments: arguments)
        XCTAssertEqual(result.exitCode, 0, "\(names[0]) failed: \(result.stderr)")
    }

    private func convert(_ input: URL, to targetID: String) async throws -> ConversionResult {
        let detected = try detector.detect(url: input)
        guard let target = FormatCatalog.targets(for: detected).first(where: { $0.id == targetID }) else {
            XCTFail("No route from \(detected.formatID) to \(targetID)")
            throw ConversionError.unsupported("no route")
        }
        let converter = Converter()
        do {
            return try await converter.convert(ConversionRequest(input: detected, route: target,
                                                                 outputDirectory: workDir))
        } catch ConversionError.toolNotFound(let tool) {
            // These tests run the real tools. On a machine without one of them, the test is skipped.
            throw XCTSkip("\(tool) is not installed")
        }
    }

    func testPNGToJPEG() async throws {
        let png = workDir.appendingPathComponent("red.png")
        try await run(["magick", "convert"], ["-size", "32x32", "xc:red", png.path])

        let result = try await convert(png, to: "jpg")
        XCTAssertEqual(result.outputURL.pathExtension, "jpg")
        XCTAssertEqual(try detector.detect(url: result.outputURL).formatID, "jpg")
    }

    func testOutputNeverOverwritesTheInput() async throws {
        let png = workDir.appendingPathComponent("blue.png")
        try await run(["magick", "convert"], ["-size", "16x16", "xc:blue", png.path])

        let first = try await convert(png, to: "jpg")
        let second = try await convert(png, to: "jpg")
        XCTAssertNotEqual(first.outputURL, second.outputURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.outputURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.outputURL.path))
    }

    func testVideoToMP3() async throws {
        let mp4 = workDir.appendingPathComponent("clip.mp4")
        try await run(["ffmpeg"], ["-hide_banner", "-loglevel", "error", "-f", "lavfi",
                                   "-i", "testsrc=duration=1:size=64x64:rate=5",
                                   "-f", "lavfi", "-i", "sine=frequency=440:duration=1",
                                   "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac",
                                   "-shortest", "-y", mp4.path])

        let result = try await convert(mp4, to: "mp3")
        XCTAssertEqual(try detector.detect(url: result.outputURL).formatID, "mp3")
    }

    func testSilentVideoToMP3ExplainsTheProblem() async throws {
        let silent = workDir.appendingPathComponent("silent.mp4")
        try await run(["ffmpeg"], ["-hide_banner", "-loglevel", "error", "-f", "lavfi",
                                   "-i", "testsrc=duration=1:size=64x64:rate=5",
                                   "-c:v", "libx264", "-pix_fmt", "yuv420p", "-y", silent.path])
        do {
            _ = try await convert(silent, to: "mp3")
            XCTFail("a video with no sound should not convert to MP3")
        } catch let error as ConversionError {
            XCTAssertTrue(error.localizedDescription.contains("no sound track"), error.localizedDescription)
        }
    }

    func testAudioToOgg() async throws {
        let mp3 = workDir.appendingPathComponent("tone.mp3")
        try await run(["ffmpeg"], ["-hide_banner", "-loglevel", "error", "-f", "lavfi",
                                   "-i", "sine=frequency=440:duration=1", "-c:a", "libmp3lame", "-y", mp3.path])

        let result = try await convert(mp3, to: "ogg")
        XCTAssertEqual(try detector.detect(url: result.outputURL).formatID, "ogg")
    }

    /// Lists the entries of a tar.gz archive, using the system tar.
    private func tarGzEntries(_ url: URL) async throws -> String {
        guard let tar = tools.locate(["tar"]) else { throw XCTSkip("tar is not installed") }
        let result = try await ProcessRunner.run(tar, arguments: ["-tzf", url.path])
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        return result.stdout
    }

    func testZipToTarGzKeepsEveryFile() async throws {
        let a = workDir.appendingPathComponent("alpha.txt")
        let b = workDir.appendingPathComponent("beta.txt")
        try "alpha".write(to: a, atomically: true, encoding: .utf8)
        try "beta".write(to: b, atomically: true, encoding: .utf8)
        let zip = workDir.appendingPathComponent("bundle.zip")
        try await run(["zip"], ["-q", "-j", zip.path, a.path, b.path])

        let result = try await convert(zip, to: "targz")
        XCTAssertEqual(result.outputURL.lastPathComponent, "bundle.tar.gz")
        XCTAssertEqual(try detector.detect(url: result.outputURL).formatID, "targz")
        let entries = try await tarGzEntries(result.outputURL)
        XCTAssertTrue(entries.contains("alpha.txt"))
        XCTAssertTrue(entries.contains("beta.txt"))
    }

    func testTarGzToSevenZip() async throws {
        let note = workDir.appendingPathComponent("note.txt")
        try "hello".write(to: note, atomically: true, encoding: .utf8)
        let tgz = workDir.appendingPathComponent("pack.tar.gz")
        try await run(["tar"], ["-czf", tgz.path, "-C", workDir.path, "note.txt"])

        let result = try await convert(tgz, to: "7z")
        XCTAssertEqual(result.outputURL.lastPathComponent, "pack.7z")
        XCTAssertEqual(try detector.detect(url: result.outputURL).formatID, "7z")
    }

    func testOllamaStartsOnDemand() async throws {
        guard ToolLocator().locate(["ollama"]) != nil else { throw XCTSkip("ollama is not installed") }
        let started = await OllamaClient().ensureRunning(tools: ToolLocator())
        XCTAssertTrue(started, "the app should start Ollama when a code conversion needs it")
    }

    func testEPUBToKindleWithCalibre() async throws {
        let calibre = URL(fileURLWithPath: "/Applications/calibre.app/Contents/MacOS/ebook-convert")
        guard FileManager.default.isExecutableFile(atPath: calibre.path) else {
            throw XCTSkip("Calibre is not installed")
        }
        let md = workDir.appendingPathComponent("story.md")
        try "# Chapter one\n\nIt was a dark and stormy night.\n".write(to: md, atomically: true, encoding: .utf8)
        let epub = workDir.appendingPathComponent("story.epub")
        try await run(["pandoc"], [md.path, "-o", epub.path])
        let result = try await convert(epub, to: "mobi")
        XCTAssertEqual(try detector.detect(url: result.outputURL).formatID, "mobi")
    }

    func testMarkdownToPDFInTwoSteps() async throws {
        let md = workDir.appendingPathComponent("plan.md")
        try "# Plan\n\nA short plan.\n".write(to: md, atomically: true, encoding: .utf8)
        let result = try await convert(md, to: "pdf")
        XCTAssertEqual(try detector.detect(url: result.outputURL).formatID, "pdf")
        XCTAssertTrue(result.log.contains { $0.hasPrefix("step 1 of 2") }, "the log should show both steps")
        XCTAssertTrue(result.log.contains { $0.hasPrefix("step 2 of 2") })
    }

    func testMarkdownToRTFIsRecognised() async throws {
        let md = workDir.appendingPathComponent("memo.md")
        try "# Memo\n\nSome text.\n".write(to: md, atomically: true, encoding: .utf8)
        let result = try await convert(md, to: "rtf")
        XCTAssertEqual(try detector.detect(url: result.outputURL).formatID, "rtf")
    }

    func testSVGWithTextConvertsToPNG() async throws {
        let svg = workDir.appendingPathComponent("label.svg")
        try """
        <svg xmlns="http://www.w3.org/2000/svg" width="200" height="60">
          <rect width="200" height="60" fill="#3b82f6"/>
          <text x="10" y="38" font-size="24" fill="white">Hello</text>
        </svg>
        """.write(to: svg, atomically: true, encoding: .utf8)
        let result = try await convert(svg, to: "png")
        XCTAssertEqual(try detector.detect(url: result.outputURL).formatID, "png")
    }

    func testMarkdownToDocxWithPandoc() async throws {
        let md = workDir.appendingPathComponent("notes.md")
        try "# Title\n\nHello from the converter.\n".write(to: md, atomically: true, encoding: .utf8)

        let result = try await convert(md, to: "docx")
        let detected = try detector.detect(url: result.outputURL)
        XCTAssertEqual(detected.formatID, "docx")
        XCTAssertEqual(detected.category, .document)
    }

    func testDocxToPDFWithLibreOffice() async throws {
        let md = workDir.appendingPathComponent("report.md")
        try "# Report\n\nBody text.\n".write(to: md, atomically: true, encoding: .utf8)
        let docx = try await convert(md, to: "docx").outputURL

        let result = try await convert(docx, to: "pdf")
        XCTAssertEqual(try detector.detect(url: result.outputURL).formatID, "pdf")
    }

    func testPythonToJavaWithOllama() async throws {
        let client = OllamaClient()
        guard await client.isRunning() else {
            throw XCTSkip("Ollama is not running")
        }
        let py = workDir.appendingPathComponent("Hello.py")
        try "print('hello from python')\n".write(to: py, atomically: true, encoding: .utf8)

        let result = try await convert(py, to: "java")
        XCTAssertNotNil(result.validation, "code translations should always report a syntax check")
        let code = try String(contentsOf: result.outputURL, encoding: .utf8)
        XCTAssertTrue(code.contains("class Hello"), "the Java class should be named after the file")
        XCTAssertFalse(code.contains("```"), "markdown fences must be stripped")
    }
}
