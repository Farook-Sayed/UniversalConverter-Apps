import XCTest
import ConverterCore

/// Fixes found in a full review of the project. Each test names the problem it guards against.
final class RobustnessTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fc-robust-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: Running programs

    /// An app opened from Finder has a PATH of only /usr/bin and /bin. Homebrew tools such as npm and tsc
    /// start node through PATH, so they failed there.
    func testToolsSeeTheInstallFoldersEvenWithAMinimalPath() async throws {
        let result = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/printenv"), arguments: ["PATH"],
                                                 environment: ["PATH": "/usr/bin:/bin"])
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(path.hasPrefix("/usr/bin:/bin"), "the folders already on PATH keep their order")
        XCTAssertTrue(path.contains("/opt/homebrew/bin"))
    }

    /// A tool that waits for typed input, such as 7-Zip asking for a password, must not wait for the app.
    func testAProgramThatReadsInputGetsNothingAndEnds() async throws {
        let result = try await ProcessRunner.run(URL(fileURLWithPath: "/bin/cat"), arguments: [], timeout: 10)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "")
    }

    // MARK: Detection

    /// A 4 KB read can end in the middle of a character. Text with accents or CJK was then taken for binary.
    func testTextCutInTheMiddleOfACharacterIsStillText() {
        var head = Data(repeating: UInt8(ascii: "x"), count: 4095)
        head.append(0xC3)   // the first byte of "é", which needs a second byte
        XCTAssertEqual(head.count, 4096)
        let detected = FileDetector().detect(head: head, url: URL(fileURLWithPath: "/tmp/a.py"))
        XCTAssertEqual(detected.formatID, "python")
        XCTAssertEqual(detected.category, .code)
    }

    func testShortInvalidUTF8IsStillNotText() {
        let head = Data([0x78, 0xC3])
        let detected = FileDetector().detect(head: head, url: URL(fileURLWithPath: "/tmp/a.py"))
        XCTAssertNotEqual(detected.method, .textWithExtension)
    }

    /// "password/" contains "word/", so an ordinary ZIP with that folder was taken for a Word document.
    func testZipWithAFolderCalledPasswordIsNotAWordFile() async throws {
        let folder = dir.appendingPathComponent("password", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "hello".write(to: folder.appendingPathComponent("list.txt"), atomically: true, encoding: .utf8)
        let zip = dir.appendingPathComponent("backup.zip")
        let made = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/zip"),
                                               arguments: ["-q", "-r", zip.path, "password"], workingDirectory: dir)
        guard made.exitCode == 0 else { throw XCTSkip("zip is not available") }
        XCTAssertEqual(try FileDetector().detect(url: zip).formatID, "zip")
    }

    // MARK: Code files

    /// CRLF line endings left a "\r" on every line, so blank lines were not seen and a file was cut mid-function.
    func testWindowsLineEndingsStillSplitAtDefinitions() {
        let function = "def f(x):\r\n    return x\r\n\r\n"
        let code = CodeText.normalize(String(repeating: function, count: 40))
        XCTAssertFalse(code.contains("\r"))
        let parts = CodeChunker.split(code, limit: 200)
        XCTAssertGreaterThan(parts.count, 1)
        for part in parts {
            XCTAssertTrue(part.hasPrefix("def f"), "a part should start at a definition")
        }
    }

    func testSourceFilesInOtherEncodingsAreRead() throws {
        func read(_ data: Data) throws -> String {
            let url = dir.appendingPathComponent(UUID().uuidString)
            try data.write(to: url)
            return try CodeText.read(url)
        }
        XCTAssertEqual(try read(Data([0x63, 0x61, 0x66, 0xE9])), "café", "Windows-1252")
        XCTAssertEqual(try read(Data([0xEF, 0xBB, 0xBF, 0x78])), "x", "a UTF-8 byte order mark is dropped")
        XCTAssertEqual(try read(try XCTUnwrap("hi".data(using: .utf16))), "hi", "UTF-16 with a byte order mark")
        XCTAssertEqual(try read(Data("a\r\nb\rc".utf8)), "a\nb\nc")
    }

    // MARK: Archives

    /// A tar file can hold a link to any file on this Mac. Repacking followed the link and put the file's
    /// contents into the new ZIP.
    func testSymbolicLinksInAnArchiveAreNotCopiedIntoTheResult() async throws {
        let source = dir.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let outside = dir.appendingPathComponent("outside.txt")
        try "secret-data".write(to: outside, atomically: true, encoding: .utf8)
        try "real".write(to: source.appendingPathComponent("real.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("link.txt"),
                                                   withDestinationURL: outside)
        let tar = dir.appendingPathComponent("a.tar")
        let made = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/tar"),
                                               arguments: ["-cf", tar.path, "-C", source.path, "link.txt", "real.txt"])
        XCTAssertEqual(made.exitCode, 0)

        let detected = try FileDetector().detect(url: tar)
        // Both ways of making the ZIP: with 7-Zip, and with the tools that ship with macOS.
        let modes: [(String, (Engine) -> Bool)] = [("all tools", { _ in true }), ("macOS only", { $0 == .builtin })]
        var ran = 0
        defer { XCTAssertGreaterThan(ran, 0, "at least one way of making the ZIP should have run") }
        for (name, available) in modes {
            guard let route = FormatCatalog.targets(for: detected, available: available).first(where: { $0.id == "zip" }) else {
                XCTFail("tar should offer ZIP (\(name))")
                continue
            }
            let result: ConversionResult
            do {
                result = try await Converter().convert(ConversionRequest(
                    input: detected, route: route, outputDirectory: dir.appendingPathComponent("out-\(name)")))
            } catch ConversionError.toolNotFound {
                continue
            }
            ran += 1
            let listing = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/unzip"),
                                                      arguments: ["-Z1", result.outputURL.path])
            XCTAssertTrue(listing.stdout.contains("real.txt"), name)
            XCTAssertFalse(listing.stdout.contains("link.txt"), "the link must not be followed (\(name))")
            XCTAssertTrue(result.notes.contains { $0.contains("symbolic link") }, "the user should be told (\(name))")
        }
    }

    // MARK: Output names and work folders

    /// Two conversions that finish together can pick the same name. The second move failed with "file exists".
    func testMovedResultsNeverShareAName() throws {
        let out = dir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var names: [String] = []
        for index in 0..<3 {
            let source = dir.appendingPathComponent("source-\(index).txt")
            try "x".write(to: source, atomically: true, encoding: .utf8)
            names.append(try OutputNaming.move(source, stem: "report", ext: "txt", into: out).lastPathComponent)
        }
        XCTAssertEqual(names, ["report.txt", "report (2).txt", "report (3).txt"])

        let folder = dir.appendingPathComponent("pages", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertEqual(try OutputNaming.move(folder, stem: "scan", ext: nil, into: out).lastPathComponent, "scan")
    }

    /// Work folders from a run that quit mid-conversion are cleared, and a recent one is left alone.
    func testOldWorkFoldersAreRemovedAndNewOnesKept() throws {
        let temp = FileManager.default.temporaryDirectory
        let old = temp.appendingPathComponent("fc-work-test-\(UUID().uuidString)", isDirectory: true)
        let recent = temp.appendingPathComponent("fc-work-test-\(UUID().uuidString)", isDirectory: true)
        for folder in [old, recent] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: recent) }
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -2 * 24 * 3600)],
                                              ofItemAtPath: old.path)
        Converter.removeStaleWork(olderThan: 3600)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path))
    }

    // MARK: Models

    /// A model named "someone/model" is stored under its own namespace, not under "library".
    func testNamespacedModelsAreFoundUnderTheirOwnFolder() {
        XCTAssertTrue(CodeModels.manifestURL(for: "someone/model:1b").path
            .hasSuffix("registry.ollama.ai/someone/model/1b"))
        XCTAssertTrue(CodeModels.manifestURL(for: "llama3.2:3b").path
            .hasSuffix("registry.ollama.ai/library/llama3.2/3b"))
    }
}
