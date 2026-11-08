import Foundation

public struct ProcessOutput: Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
}

public enum ConversionError: LocalizedError, Sendable {
    case toolNotFound(String)
    case toolFailed(tool: String, exitCode: Int32, message: String)
    case timedOut(tool: String)
    case outputMissing(tool: String)
    case unsupported(String)
    case ollamaUnavailable(String)
    case inputTooLarge(bytes: Int, limit: Int)

    public var errorDescription: String? {
        switch self {
        case .toolNotFound(let tool):
            return "\(tool) is not installed. Install it with Homebrew and try again."
        case .toolFailed(let tool, let code, let message):
            let detail = message.isEmpty ? "" : "\n\(message)"
            return "\(tool) failed with exit code \(code).\(detail)"
        case .timedOut(let tool):
            return "\(tool) took too long and was stopped."
        case .outputMissing(let tool):
            return "\(tool) finished but did not produce an output file."
        case .unsupported(let reason):
            return reason
        case .ollamaUnavailable(let reason):
            return "The local code model is not available. \(reason)"
        case .inputTooLarge(let bytes, let limit):
            return "This file is \(bytes / 1024) KB. The code model accepts up to \(limit / 1024) KB."
        }
    }
}
