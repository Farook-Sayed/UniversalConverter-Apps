import XCTest
import ConverterCore

final class CodeChunkerTests: XCTestCase {

    func testShortCodeIsOnePart() {
        let code = "print('hi')\n"
        XCTAssertEqual(CodeChunker.split(code), [code])
    }

    func testPartsStartAtDefinitionsAndStayWithinTheLimit() {
        let function = "def f(x):\n    return x + 1\n"
        let code = String(repeating: function + "\n", count: 40)
        let parts = CodeChunker.split(code, limit: 200)

        XCTAssertGreaterThan(parts.count, 1)
        for part in parts {
            XCTAssertLessThanOrEqual(part.utf8.count, 200)
            XCTAssertTrue(part.hasPrefix("def f"), "a part should start at a definition")
        }
        // Nothing is lost: all 40 definitions survive the split and the join.
        let joined = CodeChunker.join(parts)
        XCTAssertEqual(joined.components(separatedBy: "def f(x):").count - 1, 40)
    }

    func testOneHugeDefinitionIsCutByLineWithoutLosingLines() {
        let body = (1...300).map { "    value_\($0) = \($0)" }.joined(separator: "\n")
        let code = "def big():\n" + body + "\n"
        let parts = CodeChunker.split(code, limit: 500)

        XCTAssertGreaterThan(parts.count, 1)
        for part in parts {
            XCTAssertLessThanOrEqual(part.utf8.count, 500)
        }
        XCTAssertEqual(parts.joined(separator: "\n").components(separatedBy: "value_").count - 1, 300)
    }

    func testClosingBraceDoesNotStartAPart() {
        let code = "int f() {\n    return 1;\n}\n\nint g() {\n    return 2;\n}\n"
        let parts = CodeChunker.split(code, limit: 30)

        for part in parts {
            XCTAssertFalse(part.hasPrefix("}"))
        }
        XCTAssertTrue(parts.contains { $0.hasPrefix("int g") })
    }

    func testJoinKeepsOneCopyOfEachImport() {
        let parts = ["import os\n\ndef a():\n    pass\n", "import os\nimport sys\n\ndef b():\n    pass\n"]
        let joined = CodeChunker.join(parts)

        XCTAssertEqual(joined.components(separatedBy: "import os").count - 1, 1)
        XCTAssertTrue(joined.contains("import sys"))
        XCTAssertTrue(joined.contains("def a():") && joined.contains("def b():"))
        XCTAssertTrue(joined.hasSuffix("\n"))
    }

    func testPartPromptNamesThePart() {
        let python = FormatCatalog.codeLanguage(forID: "python")!
        let java = FormatCatalog.codeLanguage(forID: "java")!
        let prompt = CodePrompt.part(source: python, target: java, code: "x = 1", className: "Demo",
                                     index: 2, count: 5)
        XCTAssertTrue(prompt.contains("part 2 of 5"))
        XCTAssertTrue(prompt.contains("Write only the members"), "Java parts are members, joined into one class later")
    }

    func testFileOverTheLimitIsRefusedBeforeAnythingRuns() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chunk-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("huge.py")
        let line = "x = 1  # padding padding padding padding padding padding\n"
        let count = Converter.maxCodeBytes / line.utf8.count + 10
        try String(repeating: line, count: count).write(to: url, atomically: true, encoding: .utf8)

        let detected = try FileDetector().detect(url: url)
        guard let route = FormatCatalog.targets(for: detected, available: { _ in true })
            .first(where: { $0.id == "java" }) else {
            return XCTFail("Python should offer Java translation")
        }
        do {
            _ = try await Converter().convert(
                ConversionRequest(input: detected, route: route, outputDirectory: dir.appendingPathComponent("out")))
            XCTFail("a file over the limit should be refused")
        } catch let error as ConversionError {
            guard case .inputTooLarge = error else { return XCTFail("wrong error: \(error)") }
        }
    }
}
