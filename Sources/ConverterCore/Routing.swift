import Foundation

/// One conversion inside a route: the format going in, and the output coming out.
public struct RouteStep: Sendable, Hashable {
    public let inputFormatID: String
    public let inputCategory: MediaCategory
    public let output: OutputFormat
    public let outputCategory: MediaCategory

    public init(inputFormatID: String, inputCategory: MediaCategory, output: OutputFormat,
                outputCategory: MediaCategory) {
        self.inputFormatID = inputFormatID
        self.inputCategory = inputCategory
        self.output = output
        self.outputCategory = outputCategory
    }
}

/// The way to reach a target format: one conversion, or several in a row.
///
/// For example, Markdown to PDF is two steps: Markdown to HTML with Pandoc, then HTML to PDF with LibreOffice.
public struct Route: Sendable, Hashable, Identifiable {
    public let steps: [RouteStep]

    public init(steps: [RouteStep]) {
        precondition(!steps.isEmpty, "A route has at least one step")
        self.steps = steps
    }

    public var target: OutputFormat { steps[steps.count - 1].output }
    public var id: String { target.id }
    public var fileExtension: String { target.fileExtension }
    /// The tool that makes the last step. For a single step, that is the only tool.
    public var engine: Engine { target.engine }
    /// Every tool the route runs, in order.
    public var engines: [Engine] { steps.map { $0.output.engine } }
    public var isMultiStep: Bool { steps.count > 1 }

    /// The name shown in menus. A multi-step route names the formats it passes through.
    public var label: String {
        guard isMultiStep else { return target.label }
        let via = steps.dropLast().map { $0.output.fileExtension.uppercased() }.joined(separator: " → ")
        return "\(target.label) (via \(via))"
    }
}

extension FormatCatalog {

    /// The category a format has once it is the output of a conversion. Matches the categories detection gives.
    public static func outputCategory(ofFormat id: String) -> MediaCategory {
        if codeLanguage(forID: id) != nil { return .code }
        switch id {
        case "mp4", "mkv", "webm", "avi", "mov", "wmv", "flv", "3gp", "m2ts", "mpg", "vob": return .video
        case "mp3", "wav", "flac", "m4a", "ogg": return .audio
        case "png", "jpg", "webp", "gif", "bmp", "tiff", "avif", "heic": return .image
        case "svg": return .vector
        case "pdf", "docx", "doc", "odt", "rtf": return .document
        case "xlsx", "xls", "ods", "csv": return .spreadsheet
        case "pptx", "ppt", "odp": return .presentation
        case "html", "txt", "md", "epub", "ipynb": return .markup
        case "zip", "7z", "targz", "tar", "gz", "rar": return .archive
        case "srt", "vtt", "ass": return .subtitle
        case "ttf", "otf", "woff", "woff2": return .font
        case "eps", "ps": return .postscript
        case "obj", "stl", "ply", "dae", "gltf", "glb", "fbx": return .model3d
        case "mobi", "azw3", "fb2": return .ebook
        default: return .unknown
        }
    }

    /// Every way to convert a file: direct conversions first, then chains of up to three steps.
    public static func targets(for source: DetectedFile) -> [Route] {
        routes(fromFormat: source.formatID, category: source.category)
    }

    static func routes(fromFormat formatID: String, category sourceCategory: MediaCategory) -> [Route] {
        var found: [String: Route] = [:]
        var order: [String] = []
        var visited: Set<String> = [formatID]
        var frontier: [Route] = []

        // Step one: the direct conversions, which are always the shortest route.
        for output in directTargets(formatID: formatID, category: sourceCategory)
        where !visited.contains(output.id) {
            let step = RouteStep(inputFormatID: formatID, inputCategory: sourceCategory, output: output,
                                 outputCategory: outputCategory(ofFormat: output.id))
            let route = Route(steps: [step])
            found[output.id] = route
            order.append(output.id)
            visited.insert(output.id)
            frontier.append(route)
        }

        // Chains of two and three steps, found breadth first, so each target gets its shortest route.
        // Rules that keep chains sensible:
        //  - Code translation is only ever the final step, never an intermediate result.
        //  - A chain must end in a different kind of format from the source. Otherwise a font could
        //    be "converted" to another font through a web font, and the result would be wrong.
        for _ in 2...3 {
            var next: [Route] = []
            for route in frontier {
                let node = route.steps[route.steps.count - 1]
                guard node.outputCategory != .code else { continue }
                for output in directTargets(formatID: node.output.id, category: node.outputCategory) {
                    guard output.engine != .ollama, !visited.contains(output.id) else { continue }
                    let category = outputCategory(ofFormat: output.id)
                    guard category != sourceCategory else { continue }
                    let step = RouteStep(inputFormatID: node.output.id, inputCategory: node.outputCategory,
                                         output: output, outputCategory: category)
                    let extended = Route(steps: route.steps + [step])
                    found[output.id] = extended
                    order.append(output.id)
                    visited.insert(output.id)
                    next.append(extended)
                }
            }
            frontier = next
        }

        return order.compactMap { found[$0] }
    }
}
