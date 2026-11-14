import Foundation
import CoreGraphics
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// What can be merged into one file.
public enum MergeKind: String, Sendable, CaseIterable {
    /// Pictures and PDFs become the pages of one PDF.
    case pdf
    /// Audio files are played one after another in one audio file.
    case audio
    /// Videos are joined into one video.
    case video
    /// Text documents (Markdown, text, HTML, Word, OpenDocument, RTF) become one document.
    case document
}

/// The page size of the PDF when pictures are merged into it. PDFs that are merged keep their own pages.
public enum MergePageSize: String, Sendable, CaseIterable, Identifiable {
    case a4, letter, fitPicture
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .a4: return "A4 pages"
        case .letter: return "US Letter pages"
        case .fitPicture: return "Same size as each picture"
        }
    }

    /// The page for a picture of this many pixels. A4 and Letter turn to fit a picture that is wider than it is tall.
    func page(forPixels width: Int, _ height: Int) -> CGSize {
        switch self {
        case .a4, .letter:
            let portrait = self == .a4 ? CGSize(width: 595.28, height: 841.89) : CGSize(width: 612, height: 792)
            return width > height ? CGSize(width: portrait.height, height: portrait.width) : portrait
        case .fitPicture:
            // 150 pixels to the inch, which is sharp on paper and keeps the page a sensible size. A PDF page cannot be larger than 200 inches.
            let scale = 72.0 / 150.0
            return CGSize(width: min(max(Double(width) * scale, 36), 14_400), height: min(max(Double(height) * scale, 36), 14_400))
        }
    }

    /// The space left around the picture. Pictures that set their own page size fill it.
    var margin: CGFloat { self == .fitPicture ? 0 : 18 }
}

/// A set of files that can become one file, and what they can become.
public struct MergeGroup: Identifiable, Sendable {
    public let kind: MergeKind
    public let files: [DetectedFile]
    public let targets: [OutputFormat]

    public var id: String { kind.rawValue }

    /// The tool the merge needs, or nil when it needs nothing to install.
    public var engine: Engine? { targets.first?.engine == .builtin ? nil : targets.first?.engine }

    /// A plain description, such as "3 pictures and 2 PDFs into one PDF".
    public var title: String {
        func count(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }
        switch kind {
        case .pdf:
            let pdfs = files.filter { $0.formatID == "pdf" }.count
            let pictures = files.count - pdfs
            if pdfs == 0 { return "\(count(pictures, "picture", "pictures")) into one PDF" }
            if pictures == 0 { return "\(count(pdfs, "PDF", "PDFs")) into one PDF" }
            return "\(count(pictures, "picture", "pictures")) and \(count(pdfs, "PDF", "PDFs")) into one PDF"
        case .audio: return "\(count(files.count, "audio file", "audio files")) into one"
        case .video: return "\(count(files.count, "video", "videos")) into one"
        case .document: return "\(count(files.count, "document", "documents")) into one"
        }
    }
}

/// Finds what can be merged among the files in the queue.
public enum MergePlanner {
    public static let documentFormats: Set<String> = ["md", "txt", "html", "docx", "odt", "rtf"]
    public static let audioTargets = ["mp3", "wav", "flac", "m4a", "ogg"]
    public static let videoTargets = ["mp4", "mkv", "webm", "mov"]
    public static let documentTargets = ["docx", "md", "txt", "html", "rtf", "epub"]

    /// Every merge the files allow. A kind needs at least two files.
    public static func groups(for files: [DetectedFile]) -> [MergeGroup] {
        var groups: [MergeGroup] = []
        // PDF first: pictures and PDFs can be mixed. SVG is left out, because the picture library cannot draw it.
        let pdfFiles = files.filter { $0.formatID == "pdf" || ($0.category == .image) }
        if pdfFiles.count >= 2 {
            groups.append(MergeGroup(kind: .pdf, files: pdfFiles, targets: [target("pdf", engine: .builtin)]))
        }
        let audio = files.filter { $0.category == .audio }
        if audio.count >= 2 {
            groups.append(MergeGroup(kind: .audio, files: audio, targets: audioTargets.map { target($0, engine: .ffmpeg) }))
        }
        let video = files.filter { $0.category == .video }
        if video.count >= 2 {
            groups.append(MergeGroup(kind: .video, files: video, targets: videoTargets.map { target($0, engine: .ffmpeg) }))
        }
        let documents = files.filter { documentFormats.contains($0.formatID) && $0.category != .code }
        if documents.count >= 2 {
            groups.append(MergeGroup(kind: .document, files: documents, targets: documentTargets.map { target($0, engine: .pandoc) }))
        }
        return groups
    }

    private static func target(_ id: String, engine: Engine) -> OutputFormat {
        let label = FormatCatalog.displayName(ofFormat: id) ?? id.uppercased()
        return OutputFormat(id: id, label: label, fileExtension: id, engine: engine)
    }

    /// The format a merge of these files suggests: the one the first file already has, when it is on offer.
    public static func suggestedTarget(for group: MergeGroup) -> OutputFormat? {
        group.targets.first { $0.id == group.files.first?.formatID } ?? group.targets.first
    }
}

/// One merge: the files in the order they are joined, and what they become.
public struct MergeRequest: Sendable {
    public let kind: MergeKind
    public let inputs: [DetectedFile]
    public let target: OutputFormat
    public let outputDirectory: URL
    /// The name of the result, without its extension.
    public let name: String
    public let pageSize: MergePageSize

    public init(kind: MergeKind, inputs: [DetectedFile], target: OutputFormat, outputDirectory: URL,
                name: String = "Merged", pageSize: MergePageSize = .a4) {
        self.kind = kind
        self.inputs = inputs
        self.target = target
        self.outputDirectory = outputDirectory
        self.name = name
        self.pageSize = pageSize
    }
}

extension Converter {

    /// Joins the files of the request into one file, in the order given.
    public func merge(_ request: MergeRequest) async throws -> ConversionResult {
        guard request.inputs.count >= 2 else {
            throw ConversionError.unsupported("Choose at least two files to merge.")
        }
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("fc-work-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        var log: [String] = []
        var notes: [String] = []
        let produced: URL
        switch request.kind {
        case .pdf: produced = try await mergePDF(request, workDir: work, log: &log)
        case .audio, .video: produced = try await mergeMedia(request, workDir: work, log: &log, notes: &notes)
        case .document: produced = try await mergeDocuments(request, workDir: work, log: &log, notes: &notes)
        }

        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: request.outputDirectory, withIntermediateDirectories: true)
        let stem = Self.safeName(request.name)
        let final = try OutputNaming.move(produced, stem: stem, ext: request.target.fileExtension,
                                          into: request.outputDirectory)
        return ConversionResult(outputURL: final, engine: request.target.engine, log: log, validation: nil, notes: notes)
    }

    /// A file name with nothing in it that could point to another folder.
    static func safeName(_ name: String) -> String {
        let cleaned = name.map { "/\\:\0".contains($0) ? "-" : $0 }
        let text = String(cleaned).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty || text == "." || text == ".." ? "Merged" : text
    }

    // MARK: PDF

    private func mergePDF(_ request: MergeRequest, workDir: URL, log: inout [String]) async throws -> URL {
        let inputs = request.inputs
        let size = request.pageSize
        let count = inputs.count
        let progress: @Sendable (Int) -> Void = { index in
            self.report("Adding \(index + 1) of \(count)", fraction: Double(index) / Double(count))
        }
        let output = workDir.appendingPathComponent("merged.pdf")
        // Drawing and joining pages is processor work, so it runs off the caller's thread. Cancelling stops it between files.
        let task = Task.detached(priority: .userInitiated) { () throws -> Int in
            try PDFMerger.merge(inputs: inputs, pageSize: size, to: output, progress: progress)
        }
        let pages = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        log.append("merged \(count) files into \(pages) page(s)")
        return output
    }

    // MARK: Audio and video

    private func mergeMedia(_ request: MergeRequest, workDir: URL, log: inout [String],
                            notes: inout [String]) async throws -> URL {
        guard let tool = tools.locate(["ffmpeg"]) else { throw ConversionError.toolNotFound("FFmpeg") }
        let isVideo = request.kind == .video
        var durations: [Double] = []
        var withAudio: [Bool] = []
        for file in request.inputs {
            try Task.checkCancellation()
            guard let seconds = await mediaDuration(file.url) else {
                throw ConversionError.unsupported("\(file.url.lastPathComponent) could not be read, so it cannot be merged.")
            }
            durations.append(seconds)
            withAudio.append(try await hasAudio(file.url))
        }
        if !isVideo, let silent = withAudio.firstIndex(of: false) {
            throw ConversionError.unsupported("\(request.inputs[silent].url.lastPathComponent) has no sound track, so there is no audio to merge.")
        }
        let keepAudio = withAudio.allSatisfy { $0 }
        if isVideo, !keepAudio {
            notes.append("At least one video has no sound track, so the merged video has no sound.")
        }
        let first = isVideo ? await videoStream(request.inputs[0].url) : nil
        let arguments = FFmpegMerge.arguments(
            inputs: request.inputs.map(\.url), targetID: request.target.id, isVideo: isVideo,
            width: first?.width, height: first?.height, frameRate: first?.frameRate, keepAudio: keepAudio,
            output: workDir.appendingPathComponent("merged.\(request.target.fileExtension)"),
            threads: ResourcePlan.threadsPerConversion())
        let output = workDir.appendingPathComponent("merged.\(request.target.fileExtension)")
        if durations.contains(where: { $0 <= 0 }) {
            notes.append("The length of one file could not be read, so there is no percentage.")
        }
        let total = durations.reduce(0, +)
        log.append("ffmpeg " + arguments.joined(separator: " "))
        let result = try await ProcessRunner.run(tool, arguments: arguments, onOutput: { [self] line in
            guard total > 0, line.hasPrefix("out_time_us="),
                  let microseconds = Double(line.dropFirst("out_time_us=".count)) else { return }
            self.report("Joining", fraction: microseconds / 1_000_000 / total)
        })
        guard result.exitCode == 0 else {
            throw ConversionError.toolFailed(tool: "FFmpeg", exitCode: result.exitCode, message: Self.lastLines(result.stderr))
        }
        return try requireOutput(output, tool: "FFmpeg")
    }

    /// The size and frame rate of a video's first picture stream.
    func videoStream(_ url: URL) async -> (width: Int, height: Int, frameRate: Double?)? {
        guard let probe = tools.locate(["ffprobe"]),
              let result = try? await ProcessRunner.run(probe, arguments: [
                  "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height,avg_frame_rate",
                  "-of", "csv=p=0", url.path,
              ]), result.exitCode == 0 else { return nil }
        let parts = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ",").map(String.init)
        guard parts.count >= 2, let width = Int(parts[0]), let height = Int(parts[1]) else { return nil }
        var rate: Double?
        if parts.count >= 3 {
            let fraction = parts[2].split(separator: "/").compactMap { Double($0) }
            if fraction.count == 2, fraction[1] > 0 { rate = fraction[0] / fraction[1] } else if fraction.count == 1 { rate = fraction[0] }
        }
        return (width, height, rate.flatMap { $0 > 1 && $0 < 240 ? $0 : nil })
    }

    // MARK: Documents

    private func mergeDocuments(_ request: MergeRequest, workDir: URL, log: inout [String],
                                notes: inout [String]) async throws -> URL {
        guard let pandoc = tools.locate(["pandoc"]) else { throw ConversionError.toolNotFound("Pandoc") }
        guard let to = FormatCatalog.pandocName(request.target.id, input: false) else {
            throw ConversionError.unsupported("Pandoc cannot write \(request.target.id).")
        }
        let files = request.inputs
        var sources: [URL] = files.map(\.url)
        let from: String
        let names = try files.map { file -> String in
            guard let name = FormatCatalog.pandocName(file.formatID, input: true) else {
                throw ConversionError.unsupported("\(file.url.lastPathComponent) cannot be merged as a document.")
            }
            return name
        }
        if Set(names).count == 1, let only = names.first {
            from = only
        } else {
            // Pandoc reads one kind of file per run, so each file is first turned into Markdown and those are joined.
            from = "markdown"
            sources = []
            for (index, file) in files.enumerated() {
                try Task.checkCancellation()
                report("Reading \(index + 1) of \(files.count)", fraction: Double(index) / Double(files.count))
                let part = workDir.appendingPathComponent("part-\(index).md")
                try await execute("Pandoc", pandoc, ["--from", names[index], "--to", "markdown", "--wrap=none",
                                                     "-o", part.path, file.url.path], log: &log)
                sources.append(part)
            }
            notes.append("The files were different kinds, so they were joined as Markdown. Some layout may be lost.")
        }
        let output = workDir.appendingPathComponent("merged.\(request.target.fileExtension)")
        var arguments = ["--from", from, "--to", to, "-o", output.path]
        if ["html", "epub", "rtf"].contains(to) { arguments.append("--standalone") }
        arguments += sources.map(\.path)
        report("Joining")
        try await execute("Pandoc", pandoc, arguments, log: &log)
        return try requireOutput(output, tool: "Pandoc")
    }
}

/// Joins pictures and PDFs into one PDF with PDFKit and Core Graphics, which come with macOS.
enum PDFMerger {

    /// Writes the merged PDF and returns how many pages it has. `progress` is told which file (counting from 0) is next.
    static func merge(inputs: [DetectedFile], pageSize: MergePageSize, to output: URL,
                      progress: (Int) -> Void) throws -> Int {
        let document = PDFDocument()
        for (index, file) in inputs.enumerated() {
            try Task.checkCancellation()
            progress(index)
            let name = file.url.lastPathComponent
            if file.formatID == "pdf" {
                guard let source = PDFDocument(url: file.url) else {
                    throw ConversionError.unsupported("\(name) could not be opened as a PDF.")
                }
                if source.isLocked {
                    throw ConversionError.unsupported("\(name) is password-protected. Enter its password in the file list first, then merge it.")
                }
                for number in 0..<source.pageCount {
                    // A page is copied, because PDFKit pages belong to the document they came from.
                    guard let page = source.page(at: number)?.copy() as? PDFPage else { continue }
                    document.insert(page, at: document.pageCount)
                }
            } else {
                try autoreleasepool {
                    let image: CGImage
                    do { image = try ImageProcessing.load(file.url) } catch {
                        throw ConversionError.unsupported("\(name) could not be read as a picture, so it cannot be merged.")
                    }
                    guard let page = picturePage(image, pageSize: pageSize) else {
                        throw ConversionError.unsupported("\(name) could not be added to the PDF.")
                    }
                    document.insert(page, at: document.pageCount)
                }
            }
        }
        guard document.pageCount > 0 else {
            throw ConversionError.unsupported("There was nothing to merge: the files have no pages.")
        }
        guard document.write(to: output) else {
            throw ConversionError.unsupported("The merged PDF could not be saved.")
        }
        return document.pageCount
    }

    /// One PDF page holding one picture. The picture goes in as a JPEG on white, which keeps the file small.
    static func picturePage(_ image: CGImage, pageSize: MergePageSize) -> PDFPage? {
        guard let flat = ImageProcessing.flattened(image),
              let jpeg = ImageProcessing.encode(flat, type: .jpeg, quality: 0.9),
              let provider = CGDataProvider(data: jpeg as CFData),
              let embedded = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true,
                                     intent: .defaultIntent) else { return nil }
        let size = pageSize.page(forPixels: image.width, image.height)
        var box = CGRect(origin: .zero, size: size)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        // The picture is as large as fits inside the margins, in its own proportions, in the middle of the page.
        let room = box.insetBy(dx: pageSize.margin, dy: pageSize.margin)
        let scale = min(room.width / CGFloat(image.width), room.height / CGFloat(image.height))
        let width = CGFloat(image.width) * scale, height = CGFloat(image.height) * scale
        let target = CGRect(x: room.midX - width / 2, y: room.midY - height / 2, width: width, height: height)
        context.beginPDFPage(nil)
        context.draw(embedded, in: target)
        context.endPDFPage()
        context.closePDF()
        return PDFDocument(data: data as Data)?.page(at: 0)
    }
}

/// The FFmpeg command that joins audio or video files. It is built apart from running it, so it can be tested.
public enum FFmpegMerge {

    /// Every file is first made alike (the same sample rate and channels, and for video the same size and frame rate),
    /// because FFmpeg's join needs inputs that match. Video is scaled to fit the first video and padded with black.
    public static func arguments(inputs: [URL], targetID: String, isVideo: Bool, width: Int?, height: Int?,
                                 frameRate: Double?, keepAudio: Bool, output: URL, threads: Int) -> [String] {
        var arguments = ["-hide_banner", "-loglevel", "error", "-nostats", "-progress", "pipe:1", "-y"]
        for input in inputs { arguments += ["-i", input.path] }

        // Sizes must be even for most video encoders.
        let w = max(2, ((width ?? 1280) / 2) * 2), h = max(2, ((height ?? 720) / 2) * 2)
        let fps = frameRate.map { String(format: "%g", ($0 * 1000).rounded() / 1000) } ?? "30"
        var filters: [String] = []
        var joined = ""
        for index in inputs.indices {
            if isVideo {
                filters.append("[\(index):v:0]scale=\(w):\(h):force_original_aspect_ratio=decrease,pad=\(w):\(h):(ow-iw)/2:(oh-ih)/2,setsar=1,fps=\(fps),format=yuv420p[v\(index)]")
                joined += "[v\(index)]"
            }
            if keepAudio {
                filters.append("[\(index):a:0]aresample=44100,aformat=sample_fmts=fltp:channel_layouts=stereo[a\(index)]")
                joined += "[a\(index)]"
            }
        }
        let video = isVideo ? 1 : 0, audio = keepAudio ? 1 : 0
        let outputs = (isVideo ? "[v]" : "") + (keepAudio ? "[a]" : "")
        filters.append("\(joined)concat=n=\(inputs.count):v=\(video):a=\(audio)\(outputs)")
        arguments += ["-filter_complex", filters.joined(separator: ";")]
        if isVideo { arguments += ["-map", "[v]"] }
        if keepAudio { arguments += ["-map", "[a]"] }
        arguments += Converter.ffmpegOptions(for: targetID)
        arguments += ["-threads", "\(threads)", output.path]
        return arguments
    }
}
