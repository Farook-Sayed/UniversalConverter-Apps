import Foundation

/// Talks to a local Ollama server (http://localhost:11434). Nothing leaves the Mac.
public struct OllamaClient: Sendable {
    public let baseURL: URL
    public let model: String

    public init(baseURL: URL = URL(string: "http://localhost:11434")!,
                model: String = "qwen2.5-coder:7b") {
        self.baseURL = baseURL
        self.model = model
    }

    /// True when the server answers. Short timeout, so the UI never waits long on a missing server.
    public func isRunning() async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        request.timeoutInterval = 2
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    /// Starts `ollama serve` if the server is not answering, then waits for it.
    /// Returns false when the server could not be started in time.
    public func ensureRunning(tools: ToolLocator, waitSeconds: Int = 20) async -> Bool {
        if await isRunning() { return true }
        guard let binary = tools.locate(["ollama"]) else { return false }
        let process = Process()
        process.executableURL = binary
        process.arguments = ["serve"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        for _ in 0..<(waitSeconds * 2) {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if await isRunning() { return true }
        }
        return false
    }

    /// Runs one non-streaming generation and returns the full text.
    public func generate(_ prompt: String) async throws -> String {
        struct Options: Encodable { let temperature: Double }
        struct Body: Encodable {
            let model: String
            let prompt: String
            let stream: Bool
            let options: Options
        }
        struct Reply: Decodable { let response: String }

        var request = URLRequest(url: baseURL.appendingPathComponent("api/generate"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 600
        request.httpBody = try JSONEncoder().encode(
            Body(model: model, prompt: prompt, stream: false, options: Options(temperature: 0.1))
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 {
            throw ConversionError.ollamaUnavailable("The model \(model) is not installed. Run: ollama pull \(model)")
        }
        guard status == 200 else {
            let text = String(decoding: data, as: UTF8.self)
            throw ConversionError.ollamaUnavailable("The server replied: \(text)")
        }
        return try JSONDecoder().decode(Reply.self, from: data).response
    }
}

/// The instruction sent to the code model.
public enum CodePrompt {
    public static func make(source: CodeLanguage, target: CodeLanguage, code: String, className: String) -> String {
        // Java requires the public class to match the file name.
        let classRule = target.id == "java"
            ? "The public class must be named \(className)."
            : ""
        return """
        You are a source-code translator. Translate the \(source.label) program below into \(target.label).
        Keep the same behaviour and the same output. Use idiomatic \(target.label). Where the source uses a \
        third-party library, use the standard library or the closest \(target.label) equivalent. Include every \
        import the code needs. \(classRule)
        Return ONLY the \(target.label) source code. No explanations and no markdown code fences.

        \(source.label) source:
        \(code)
        """
    }
}

extension CodePrompt {
    /// Asks the model to fix code that failed the syntax check, using the checker's own messages.
    public static func repair(target: CodeLanguage, code: String, errors: [String], className: String) -> String {
        let classRule = target.id == "java" ? "The public class must be named \(className)." : ""
        return """
        The \(target.label) code below does not parse or compile. Fix every error and return ONLY the corrected \
        \(target.label) source code. Keep the same behaviour. \(classRule)
        No explanations and no markdown code fences.

        Errors reported by the \(target.label) checker:
        \(errors.joined(separator: "\n"))

        Code:
        \(code)
        """
    }
}

/// Removes markdown fences and surrounding prose that models often add despite instructions.
public enum CodeOutputCleaner {
    public static func clean(_ raw: String) -> String {
        var lines = raw.components(separatedBy: "\n")
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        if let first = lines.first, first.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
            lines.removeFirst()
        }
        if let last = lines.last, last.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
            lines.removeLast()
        }
        let body = lines.joined(separator: "\n")
        return body.isEmpty ? "" : body + "\n"
    }
}
