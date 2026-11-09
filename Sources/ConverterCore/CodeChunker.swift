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

    /// A Java file that holds one class, cut between its members. Each part holds whole fields and methods.
    /// Nil for anything else, such as a script or several top-level classes.
    public static func splitJavaClass(_ code: String, limit: Int = partBytes) -> (className: String, header: String, parts: [String])? {
        let lines = code.components(separatedBy: "\n")
        guard let headerIndex = lines.firstIndex(where: { isClassHeader($0) }),
              let className = javaClassName(inHeader: lines[headerIndex]),
              let closing = lines.lastIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              closing > headerIndex, lines[closing].trimmingCharacters(in: .whitespaces) == "}" else { return nil }
        let body = Array(lines[(headerIndex + 1)..<closing])
        // Anything unindented in the body is another top-level declaration, so this is not a single class.
        for line in body where !line.isEmpty && !(line.hasPrefix(" ") || line.hasPrefix("\t") || line.hasPrefix("//")) {
            return nil
        }
        guard let first = body.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return nil }
        let indent = String(first.prefix { $0 == " " || $0 == "\t" })
        guard !indent.isEmpty else { return nil }

        // A member starts at the member indent, after a blank line or the end of the previous member.
        func startsMember(_ index: Int) -> Bool {
            let line = body[index]
            guard line.hasPrefix(indent), let next = line.dropFirst(indent.count).first,
                  next != " ", next != "\t", next != "}" else { return false }
            guard index > 0 else { return true }
            let previous = body[index - 1]
            return previous.trimmingCharacters(in: .whitespaces).isEmpty
                || (previous.hasPrefix(indent) && previous.trimmingCharacters(in: .whitespaces) == "}")
        }
        var sections: [[String]] = []
        var current: [String] = []
        for index in body.indices {
            if startsMember(index), !current.isEmpty {
                sections.append(current)
                current = []
            }
            current.append(body[index])
        }
        if !current.isEmpty { sections.append(current) }

        var parts: [String] = []
        var buffer: [String] = []
        var bytes = 0
        for section in sections {
            let size = section.joined(separator: "\n").utf8.count + 1
            // A member is never cut in two. A method longer than the limit becomes a part of its own.
            if bytes + size > limit, !buffer.isEmpty {
                parts.append(buffer.joined(separator: "\n"))
                buffer = []
                bytes = 0
            }
            buffer.append(contentsOf: section)
            bytes += size
        }
        if !buffer.isEmpty { parts.append(buffer.joined(separator: "\n")) }
        let header = lines[..<headerIndex].joined(separator: "\n")
        return (className, header, parts)
    }

    /// Joins translated Java members into one class named after the file. Import lines move to the top, and each
    /// is kept once. A package line is dropped, because the file has no package.
    ///
    /// A model often puts its own class around a part. That class is unwrapped: its members stay, and its declaration
    /// and closing brace go. A class named in `keeping` is one the source really has, so it stays, as a static class
    /// that any method can use.
    public static func joinJavaClass(_ parts: [String], className: String, keeping: Set<String> = []) -> String {
        var imports: [String] = []
        var seen = Set<String>()
        var members: [String] = []
        for part in parts {
            var nestedDepth: Int?
            for line in part.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if nestedDepth == nil, isNestedClassDeclaration(trimmed) {
                    if let name = javaClassName(inHeader: trimmed), name != className, keeping.contains(name) {
                        members.append(staticClassLine(line))
                        continue
                    }
                    nestedDepth = braceDifference(trimmed)
                    continue
                }
                if let depth = nestedDepth {
                    let updated = depth + braceDifference(trimmed)
                    nestedDepth = updated
                    if updated <= 0 {
                        nestedDepth = nil
                        if trimmed.hasPrefix("}") { continue }
                    }
                }
                if trimmed.hasPrefix("package ") { continue }
                if trimmed.hasPrefix("import ") {
                    if seen.insert(trimmed).inserted { imports.append(trimmed) }
                    continue
                }
                let indented = line.isEmpty || line.hasPrefix(" ") || line.hasPrefix("\t")
                members.append(indented ? line : "    " + line)
            }
            members.append("")
        }
        while members.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { members.removeFirst() }
        while members.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { members.removeLast() }
        var output = imports.isEmpty ? "" : imports.joined(separator: "\n") + "\n\n"
        output += "public class \(className) {\n" + members.joined(separator: "\n") + "\n}\n"
        return output
    }

    /// A class line inside the joined class, made static and indented.
    private static func staticClassLine(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let isIndented = line.hasPrefix(" ") || line.hasPrefix("\t")
        let indent = isIndented ? String(line.prefix { $0 == " " || $0 == "\t" }) : "    "
        guard !javaTypeWords(trimmed).contains("static") else { return indent + trimmed }
        if trimmed.hasPrefix("class ") { return indent + "static " + trimmed }
        return indent + trimmed.replacingOccurrences(of: " class ", with: " static class ")
    }

    /// The names of the classes, structs and interfaces a source file defines, in any of the code languages.
    public static func typeNames(in code: String) -> Set<String> {
        let keywords: Set<String> = ["class", "struct", "interface", "trait"]
        var names = Set<String>()
        for line in code.components(separatedBy: "\n") {
            let words = line.split(whereSeparator: { " \t(:<{".contains($0) }).map(String.init)
            // Comments can use these words too, so the keyword must lead the line, after modifiers at most.
            guard let first = words.first, !first.hasPrefix("//"), !first.hasPrefix("#"), !first.hasPrefix("*") else { continue }
            guard let index = words.prefix(4).firstIndex(where: { keywords.contains($0) }), index + 1 < words.count else { continue }
            names.insert(words[index + 1])
        }
        return names
    }

    /// True for a line that starts a class inside a part, such as "public class Inner {".
    static func isNestedClassDeclaration(_ trimmed: String) -> Bool {
        guard trimmed.hasSuffix("{") else { return false }
        return javaTypeWords(trimmed).contains("class") && !trimmed.hasPrefix("//")
    }

    /// Opening braces minus closing braces on one line.
    static func braceDifference(_ line: String) -> Int {
        line.filter { $0 == "{" }.count - line.filter { $0 == "}" }.count
    }

    /// True for a line that declares a class, interface, enum or record at the top level.
    static func isClassHeader(_ line: String) -> Bool {
        guard !line.hasPrefix(" "), !line.hasPrefix("\t"), line.contains("{") else { return false }
        return javaTypeWords(line).contains { ["class", "interface", "enum", "record"].contains($0) }
    }

    /// The name that follows "class" (or interface, enum or record) on a declaration line.
    static func javaClassName(inHeader line: String) -> String? {
        let words = javaTypeWords(line)
        guard let index = words.firstIndex(where: { ["class", "interface", "enum", "record"].contains($0) }),
              index + 1 < words.count else { return nil }
        return words[index + 1]
    }

    private static func javaTypeWords(_ line: String) -> [String] {
        line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "{" }).map(String.init)
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
        let afterBlank = previous.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

/// Reads a source file as text. Windows line endings become plain newlines, so splitting and checking
/// work the same for every file. Files that are not UTF-8 are read as the older Windows encoding.
public enum CodeText {
    public static func read(_ url: URL) throws -> String {
        normalize(decode(try Data(contentsOf: url)))
    }

    static func decode(_ data: Data) -> String {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]),
           let text = String(data: data, encoding: .utf16) {
            return text
        }
        var bytes = data
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        if let text = String(data: bytes, encoding: .utf8) { return text }
        // Older source files are usually Windows-1252. ISO Latin 1 accepts every byte, so it is the last resort.
        return String(data: bytes, encoding: .windowsCP1252)
            ?? String(data: bytes, encoding: .isoLatin1)
            ?? String(decoding: bytes, as: UTF8.self)
    }

    public static func normalize(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }
}
