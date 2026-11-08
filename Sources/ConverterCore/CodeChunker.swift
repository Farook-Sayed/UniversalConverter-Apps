import Foundation

/// Splits a long source file into parts the model can handle, and joins the translated parts back together.
///
/// Cuts happen only between top-level definitions, so each part keeps its functions and classes whole.
public enum CodeChunker {
    /// The most source text sent to the model in one request. Keeps the request and the reply within the model's context.
    public static let partBytes = 6 * 1024

    /// Files up to this size are translated in one request. Larger files are split into parts.
    public static let wholeFileBytes = 8 * 1024

    /// The largest file that is sent back to the model for repair. The repair request includes the whole file.
    public static let repairBytes = 8 * 1024

    /// Splits `code` into parts of at most `limit` bytes. A single definition longer than `limit` is cut by line.
    public static func split(_ code: String, limit: Int = partBytes) -> [String] {
        guard code.utf8.count > limit else { return [code] }
        let lines = code.components(separatedBy: "\n")

        // Sections start at each top-level line, so each holds whole definitions.
        var sections: [[String]] = []
        var current: [String] = []
        for index in lines.indices {
            if isTopLevelStart(lines, index), !current.isEmpty {
                sections.append(current)
                current = []
            }
            current.append(lines[index])
        }
        if !current.isEmpty { sections.append(current) }

        // Pack sections into parts, starting a new part when the next section would not fit.
        var parts: [String] = []
        var buffer: [String] = []
        var bufferBytes = 0
        for section in sections {
            let size = section.joined(separator: "\n").utf8.count + 1
            if size > limit {
                if !buffer.isEmpty {
                    parts.append(buffer.joined(separator: "\n"))
                    buffer = []
                    bufferBytes = 0
                }
                parts.append(contentsOf: cutByLine(section, limit: limit))
                continue
            }
            if bufferBytes + size > limit, !buffer.isEmpty {
                parts.append(buffer.joined(separator: "\n"))
                buffer = []
                bufferBytes = 0
            }
            buffer.append(contentsOf: section)
            bufferBytes += size
        }
        if !buffer.isEmpty { parts.append(buffer.joined(separator: "\n")) }
        return parts
    }

    /// Joins translated parts. Import lines that appear in more than one part are kept once.
    public static func join(_ parts: [String]) -> String {
        var seenImports = Set<String>()
        var output: [String] = []
        for part in parts {
            for line in part.components(separatedBy: "\n") {
                if isTopLevelImport(line) {
                    let key = line.trimmingCharacters(in: .whitespaces)
                    if seenImports.contains(key) { continue }
                    seenImports.insert(key)
                }
                output.append(line)
            }
            output.append("")
        }
        while output.last == "" { output.removeLast() }
        return output.joined(separator: "\n") + "\n"
    }

    // MARK: Helpers

    /// A line starts a new top-level definition when it is not indented, comes after a blank line or the end
    /// of a block, and is not itself the end of a block.
    static func isTopLevelStart(_ lines: [String], _ index: Int) -> Bool {
        guard index > 0 else { return false }
        let line = lines[index]
        guard let first = line.first, first != " ", first != "\t" else { return false }
        if ["}", ")", "]"].contains(first) { return false }
        let previous = lines[index - 1]
        let afterBlank = previous.trimmingCharacters(in: .whitespaces).isEmpty
        let afterClose = previous.hasPrefix("}") || previous.hasPrefix(")") || previous.hasPrefix("]")
        return afterBlank || afterClose
    }

    static func isTopLevelImport(_ line: String) -> Bool {
        guard let first = line.first, first != " ", first != "\t" else { return false }
        return ["import ", "from ", "#include", "use ", "using ", "require "].contains { line.hasPrefix($0) }
    }

    private static func cutByLine(_ lines: [String], limit: Int) -> [String] {
        var parts: [String] = []
        var buffer: [String] = []
        var bytes = 0
        for line in lines {
            let size = line.utf8.count + 1
            if bytes + size > limit, !buffer.isEmpty {
                parts.append(buffer.joined(separator: "\n"))
                buffer = []
                bytes = 0
            }
            buffer.append(line)
            bytes += size
        }
        if !buffer.isEmpty { parts.append(buffer.joined(separator: "\n")) }
        return parts
    }
}
