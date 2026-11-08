import Foundation

/// What the syntax check found for a piece of code.
public enum ValidationResult: Equatable, Sendable {
    case passed(checker: String)
    case failed(checker: String, messages: [String])
    /// The checker for this language is not installed or not set up yet.
    case notChecked(reason: String)

    public var summary: String {
        switch self {
        case .passed(let checker): return "passed (\(checker))"
        case .failed(let checker, let messages):
            return "failed (\(checker)): \(messages.first ?? "errors found")"
        case .notChecked(let reason): return "not checked. \(reason)"
        }
    }
}

/// Checks that generated code parses, using the language's own parser or compiler.
///
/// The chat suggested tree-sitter. These tools are already on the Mac, and they are the same
/// tools the language uses, so they catch more problems than a syntax-only parse.
public struct CodeValidator: Sendable {
    public let tools: ToolLocator

    public init(tools: ToolLocator = ToolLocator()) {
        self.tools = tools
    }

    /// Writes the code to a private file named `fileName` and runs the checker for `language` on it.
    /// The file name matters for Java, where the public class must match it.
    public func validate(code: String, language: CodeLanguage, fileName: String,
                         workDir: URL) async throws -> ValidationResult {
        let dir = workDir.appendingPathComponent("validate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(fileName)
        try code.write(to: file, atomically: true, encoding: .utf8)

        switch language.id {
        case "python":
            return try await run("Python 3.12", ["python3.12"],
                                 ["-c", Self.pythonParseScript, file.path], in: dir,
                                 install: "Install it with: brew install python@3.12")
        case "ruby":
            return try await run("Ruby", ["ruby"], ["-c", file.path], in: dir,
                                 install: "Ruby ships with macOS.")
        case "c":
            return try await run("clang (C)", ["clang"],
                                 ["-fsyntax-only", "-x", "c", "-std=c11", file.path], in: dir,
                                 install: "Install the Xcode command line tools.")
        case "cpp":
            return try await run("clang (C++)", ["clang"],
                                 ["-fsyntax-only", "-x", "c++", "-std=c++17", file.path], in: dir,
                                 install: "Install the Xcode command line tools.")
        case "java":
            return try await run("javac", ["javac"],
                                 ["-proc:none", "-d", dir.path, file.path], in: dir,
                                 install: "Install a JDK, for example with: brew install openjdk")
        case "rust":
            return try await run("rustc", ["rustc"],
                                 ["--edition", "2021", "--crate-type", "lib", "--emit=metadata",
                                  "-o", dir.appendingPathComponent("check.rmeta").path, file.path],
                                 in: dir, install: "Install Rust with: brew install rust")
        case "go":
            return try await run("gofmt", ["gofmt"], ["-e", file.path], in: dir,
                                 install: "Install Go with: brew install go")
        case "typescript":
            return try await run("TypeScript (tsc)", ["tsc"],
                                 ["--noEmit", "--target", "ES2020", file.path], in: dir,
                                 install: "Install it with: npm install -g typescript")
        case "javascript":
            return try await run("Node.js", ["node"], ["--check", file.path], in: dir,
                                 install: "Install it with: brew install node")
        default:
            return .notChecked(reason: "No checker is set up for \(language.label) yet.")
        }
    }

    /// Parses Python without running it.
    static let pythonParseScript = """
        import ast, sys
        ast.parse(open(sys.argv[1], encoding='utf-8').read(), sys.argv[1])
        """

    private func run(_ label: String, _ names: [String], _ arguments: [String], in dir: URL,
                     install: String) async throws -> ValidationResult {
        guard let tool = tools.locate(names) else {
            return .notChecked(reason: "\(label) is not installed. \(install)")
        }
        let result = try await ProcessRunner.run(tool, arguments: arguments, workingDirectory: dir)
        guard result.exitCode == 0 else {
            return .failed(checker: label, messages: Self.errorLines(result, in: dir))
        }
        return .passed(checker: label)
    }

    /// The error lines from a checker's output, with temporary folder paths removed.
    static func errorLines(_ result: ProcessOutput, in dir: URL) -> [String] {
        let text = result.stderr + "\n" + result.stdout
        let lines = text.split(separator: "\n")
            .map { String($0).replacingOccurrences(of: dir.path + "/", with: "") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let errors = lines.filter { $0.localizedCaseInsensitiveContains("error") || $0.contains("line ") }
        let chosen = errors.isEmpty ? Array(lines.suffix(6)) : errors
        return Array(chosen.prefix(8))
    }
}
