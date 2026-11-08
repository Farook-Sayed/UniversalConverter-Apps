import XCTest
import ConverterCore

/// Tests the syntax checks. Each test is skipped when its checker is not installed.
final class CodeValidationTests: XCTestCase {

    private var workDir: URL!
    private let validator = CodeValidator()

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fc-validate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    private func check(_ code: String, _ languageID: String, _ fileName: String) async throws -> ValidationResult {
        let language = try XCTUnwrap(FormatCatalog.codeLanguage(forID: languageID))
        let result = try await validator.validate(code: code, language: language, fileName: fileName, workDir: workDir)
        if case .notChecked(let reason) = result {
            throw XCTSkip(reason)
        }
        return result
    }

    func testValidPythonPasses() async throws {
        let result = try await check("print('hi')\n", "python", "hello.py")
        XCTAssertEqual(result, .passed(checker: "Python 3.12"))
    }

    func testPythonSyntaxErrorFails() async throws {
        let result = try await check("def broken(:\n    pass\n", "python", "broken.py")
        guard case .failed(_, let messages) = result else {
            return XCTFail("expected a failure, got \(result)")
        }
        XCTAssertFalse(messages.isEmpty)
        XCTAssertFalse(messages.contains { $0.contains(workDir.path) }, "temporary paths should be hidden")
    }

    func testValidCPasses() async throws {
        let result = try await check("#include <stdio.h>\nint main(void) { printf(\"hi\"); return 0; }\n", "c", "hello.c")
        XCTAssertEqual(result, .passed(checker: "clang (C)"))
    }

    func testCMissingSemicolonFails() async throws {
        let result = try await check("int main(void) {\n    return 0\n}\n", "c", "bad.c")
        guard case .failed = result else { return XCTFail("expected a failure, got \(result)") }
    }

    func testValidCppPasses() async throws {
        let result = try await check("#include <iostream>\nint main() { std::cout << 1; return 0; }\n", "cpp", "hello.cpp")
        XCTAssertEqual(result, .passed(checker: "clang (C++)"))
    }

    func testValidJavaPasses() async throws {
        let code = "public class Hello {\n    public static void main(String[] args) { System.out.println(1); }\n}\n"
        let result = try await check(code, "java", "Hello.java")
        XCTAssertEqual(result, .passed(checker: "javac"))
    }

    func testJavaClassNameMustMatchFileName() async throws {
        let code = "public class Hello {\n    public static void main(String[] args) { }\n}\n"
        let result = try await check(code, "java", "Other.java")
        guard case .failed = result else { return XCTFail("expected a failure, got \(result)") }
    }

    func testRubyCheck() async throws {
        let good = try await check("puts 'hi'\n", "ruby", "hello.rb")
        XCTAssertEqual(good, .passed(checker: "Ruby"))
        let bad = try await check("def broken(\n", "ruby", "bad.rb")
        guard case .failed = bad else { return XCTFail("expected a Ruby syntax error") }
    }

    func testJavaScriptCheck() async throws {
        let good = try await check("console.log(1);\n", "javascript", "hello.js")
        XCTAssertEqual(good, .passed(checker: "Node.js"))
        let bad = try await check("console.log(\n", "javascript", "bad.js")
        guard case .failed = bad else { return XCTFail("expected a JavaScript syntax error") }
    }

    func testGoCheck() async throws {
        let good = try await check("package main\n\nfunc main() {}\n", "go", "main.go")
        XCTAssertEqual(good, .passed(checker: "gofmt"))
        let bad = try await check("package main\n\nfunc main() {\n", "go", "bad.go")
        guard case .failed = bad else { return XCTFail("expected a Go syntax error") }
    }

    func testRustCheck() async throws {
        let good = try await check("pub fn add(a: i32, b: i32) -> i32 { a + b }\n", "rust", "lib.rs")
        XCTAssertEqual(good, .passed(checker: "rustc"))
        let bad = try await check("pub fn broken() { let x = ; }\n", "rust", "bad.rs")
        guard case .failed = bad else { return XCTFail("expected a Rust syntax error") }
    }

    func testTypeScriptCheck() async throws {
        let good = try await check("const x: number = 1;\n", "typescript", "hello.ts")
        XCTAssertEqual(good, .passed(checker: "TypeScript (tsc)"))
        let bad = try await check("const x: number = 'text';\n", "typescript", "bad.ts")
        guard case .failed = bad else { return XCTFail("expected a TypeScript type error") }
    }

    func testLanguageWithoutCheckerIsReportedNotGuessed() async throws {
        // C# has no checker yet, so the app must say so rather than report a pass.
        let language = try XCTUnwrap(FormatCatalog.codeLanguage(forID: "csharp"))
        let result = try await validator.validate(code: "class P {}\n", language: language,
                                                  fileName: "P.cs", workDir: workDir)
        guard case .notChecked(let reason) = result else { return XCTFail("expected notChecked") }
        XCTAssertTrue(reason.contains("C#"), reason)
    }

    func testRepairPromptContainsErrorsAndClassName() throws {
        let java = try XCTUnwrap(FormatCatalog.codeLanguage(forID: "java"))
        let prompt = CodePrompt.repair(target: java, code: "class X {}",
                                       errors: ["Hello.java:3: error: ';' expected"], className: "Hello")
        XCTAssertTrue(prompt.contains("Hello.java:3: error: ';' expected"))
        XCTAssertTrue(prompt.contains("The public class must be named Hello."))
        XCTAssertTrue(prompt.contains("class X {}"))
    }
}
