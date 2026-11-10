import Foundation

public struct ConversionRequest: Sendable {
    public let input: DetectedFile
    /// One conversion, or several in a row, ending at the chosen format.
    public let route: Route
    public let outputDirectory: URL
    /// How hard a PDF is compressed, when the route makes a smaller PDF.
    public let pdfCompression: PDFCompression

    /// What the user changed about an image: size, crop, background, style and compression.
    public let imageAdjustments: ImageAdjustments

    public init(input: DetectedFile, route: Route, outputDirectory: URL, pdfCompression: PDFCompression = .medium,
                imageAdjustments: ImageAdjustments = .unchanged) {
        self.input = input
        self.route = route
        self.outputDirectory = outputDirectory
        self.pdfCompression = pdfCompression
        self.imageAdjustments = imageAdjustments
    }
}

public struct ConversionResult: Sendable {
    public let outputURL: URL
    public let engine: Engine
    /// The commands that were run, for the log view.
    public let log: [String]
    /// Set for code translations only.
    public let validation: ValidationResult?
    /// Things the user should know about the result, such as a size that could not be reached.
    public let notes: [String]
}

/// Status of one external tool, for the "Tools" panel.
public struct ToolStatus: Sendable, Identifiable {
    public let id: String
    public let name: String
    public let purpose: String
    public let path: URL?
}

/// Finds external programs. A Mac app does not inherit the shell's PATH, so Homebrew's folders
/// are searched explicitly.
public struct ToolLocator: Sendable {
    public static let searchDirectories = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        "/Applications/LibreOffice.app/Contents/MacOS",
        "/Applications/calibre.app/Contents/MacOS",
    ]

    public init() {}

    public func locate(_ names: [String]) -> URL? {
        let pathDirectories = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
        for directory in Self.searchDirectories + pathDirectories {
            for name in names {
                let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
                if FileManager.default.isExecutableFile(atPath: url.path) { return url }
            }
        }
        return nil
    }

    public func statusOfAllTools() -> [ToolStatus] {
        let tools: [(id: String, name: String, binaries: [String], purpose: String)] = [
            ("ffmpeg", "FFmpeg", ["ffmpeg"], "Video and audio"),
            ("magick", "ImageMagick", ["magick", "convert"], "Images"),
            ("soffice", "LibreOffice", ["soffice"], "Documents, spreadsheets, slides"),
            ("pandoc", "Pandoc", ["pandoc"], "Markdown, HTML, EPUB"),
            ("7z", "7-Zip", ["7zz", "7z"], "ZIP and 7z archives"),
            ("poppler", "Poppler", ["pdftotext", "pdftoppm"], "PDF text and page images"),
            ("gs", "Ghostscript", ["gs"], "PostScript and EPS"),
            ("assimp", "Assimp", ["assimp"], "3D models"),
            ("ebook-convert", "Calibre", ["ebook-convert"], "E-books"),
            ("ollama", "Ollama", ["ollama"], "Code translation"),
        ]
        return tools.map { tool in
            ToolStatus(id: tool.id, name: tool.name, purpose: tool.purpose,
                       path: locate(tool.binaries))
        }
    }
}

/// Runs a conversion. Each engine writes into a private work folder first, and the finished file
/// is then moved into the output folder under a name that does not overwrite anything.
public struct Converter: Sendable {
    public let tools: ToolLocator
    public let ollama: OllamaClient
    public let validator: CodeValidator
    /// How many times the model may repair code that fails the syntax check. Zero turns repair off.
    public let repairAttempts: Int
    /// Reports what the conversion is doing now, such as "Translating part 2 of 5". Shown in the queue.
    public let progress: @Sendable (ConversionProgress) -> Void
    /// How several page images are delivered. One page is always a single image.
    public let pageOutput: PageOutput

    /// Source files larger than this are refused. Files up to this size are split at top-level definitions,
    /// and each part is translated on its own.
    public static let maxCodeBytes = 256 * 1024

    /// Targets that only keep the sound of a video. These need an audio track in the input.
    public static let audioOnlyTargets: Set<String> = ["mp3", "wav", "flac", "m4a", "ogg"]

    public init(tools: ToolLocator = ToolLocator(), ollama: OllamaClient = OllamaClient(), repairAttempts: Int = 1,
                pageOutput: PageOutput = .folder, progress: @escaping @Sendable (ConversionProgress) -> Void = { _ in }) {
        self.tools = tools
        self.ollama = ollama
        self.validator = CodeValidator(tools: tools)
        self.repairAttempts = repairAttempts
        self.pageOutput = pageOutput
        self.progress = progress
    }

    /// Tells the caller what is happening. A fraction is given only when the work can be measured.
    private func report(_ message: String, fraction: Double? = nil) {
        progress(ConversionProgress(message, fraction: fraction))
    }

    /// Runs every step of the request's route in order. Each step reads the previous step's output.
    /// The last output is moved into the output folder under a name that does not overwrite anything.
    public func convert(_ request: ConversionRequest) async throws -> ConversionResult {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("fc-work-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        try Task.checkCancellation()
        let finalTarget = request.route.target
        // Java needs the public class name to match the file name, so the name must be a legal identifier.
        let finalStem = finalTarget.id == "java"
            ? FormatCatalog.javaClassName(from: FileNames.stem(request.input.url))
            : FileNames.stem(request.input.url)

        var log: [String] = []
        var notes: [String] = []
        var validation: ValidationResult?
        var current = request.input
        let stepCount = request.route.steps.count

        for (index, step) in request.route.steps.enumerated() {
            try Task.checkCancellation()
            let stepDir = base.appendingPathComponent("step-\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: stepDir, withIntermediateDirectories: true)
            let isLast = index == stepCount - 1
            // The file name of an intermediate result is "out.<ext>", so its stem is "out".
            let stem = isLast ? finalStem : FileNames.stem(current.url)
            if stepCount > 1 {
                log.append("step \(index + 1) of \(stepCount): \(step.output.label)")
            }
            // One step that cannot be measured shows a spinner, so it reports no fraction. In a route, finished steps
            // count, and a step's own percentage fills its share, so the bar never moves backwards.
            report(stepCount > 1 ? "Step \(index + 1) of \(stepCount)…" : "Converting…",
                   fraction: stepCount > 1 ? Double(index) / Double(stepCount) : nil)
            let (produced, check) = try await worker(forStep: index, of: stepCount)
                .runStep(input: current, target: step.output, stem: stem,
                         workDir: stepDir, log: &log, notes: &notes,
                         compression: request.pdfCompression,
                         imageAdjustments: request.imageAdjustments)
            if isLast { validation = check }
            current = DetectedFile(url: produced, category: step.outputCategory, formatID: step.output.id,
                                   mimeType: "application/octet-stream", method: .magicBytes,
                                   extensionMismatch: false)
        }

        // A cancelled conversion must not leave a finished file behind.
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: request.outputDirectory, withIntermediateDirectories: true)
        // A folder of pages has no extension. A ZIP file of pages keeps its own. Everything else takes the target's.
        let produced = current.url
        let ext: String? = Self.isFolder(produced) ? nil
            : (produced.pathExtension == "zip" ? "zip" : finalTarget.fileExtension)
        let finalURL = try OutputNaming.move(current.url, stem: finalStem, ext: ext, into: request.outputDirectory)
        return ConversionResult(outputURL: finalURL, engine: finalTarget.engine, log: log,
                                validation: validation, notes: notes)
    }

    /// This converter, with progress scaled to one step of a route. A single step reports as it is.
    private func worker(forStep index: Int, of count: Int) -> Converter {
        guard count > 1 else { return self }
        let outer = progress
        return Converter(tools: tools, ollama: ollama, repairAttempts: repairAttempts, pageOutput: pageOutput) { update in
            outer(ConversionProgress("Step \(index + 1) of \(count): \(update.message)",
                                     fraction: update.fraction.map { (Double(index) + $0) / Double(count) }))
        }
    }

    /// Runs slow synchronous work off the caller's thread. Cancelling the caller cancels the work.
    static func offThread<Value: Sendable>(_ work: @escaping @Sendable () throws -> Value) async throws -> Value {
        let task = Task.detached(priority: .userInitiated) { try work() }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// One conversion, run by the engine the step names.
    private func runStep(input: DetectedFile, target: OutputFormat, stem: String, workDir: URL,
                         log: inout [String], notes: inout [String],
                         compression: PDFCompression, imageAdjustments: ImageAdjustments) async throws -> (URL, ValidationResult?) {
        switch target.engine {
        case .ffmpeg:
            return (try await runFFmpeg(input: input, target: target, workDir: workDir, log: &log), nil)
        case .imagemagick:
            return (try await runImageMagick(input: input, target: target, workDir: workDir, log: &log), nil)
        case .libreoffice:
            return (try await runLibreOffice(input: input, target: target, stem: stem, workDir: workDir,
                                             log: &log), nil)
        case .pandoc:
            return (try await runPandoc(input: input, target: target, workDir: workDir, log: &log), nil)
        case .fonttools:
            return (try await runFonts(input: input, target: target, workDir: workDir, log: &log), nil)
        case .poppler:
            return (try await runPoppler(input: input, target: target, workDir: workDir, log: &log, notes: &notes), nil)
        case .ghostscript:
            if input.formatID == "pdf" {
                return (try await compressPDF(input: input, compression: compression, workDir: workDir,
                                              log: &log, notes: &notes), nil)
            }
            return (try await runGhostscript(input: input, target: target, workDir: workDir, log: &log), nil)
        case .assimp:
            return (try await runAssimp(input: input, target: target, workDir: workDir, log: &log), nil)
        case .calibre:
            return (try await runCalibre(input: input, target: target, workDir: workDir, log: &log), nil)
        case .imageio:
            if target.id == "txt" {
                return (try await runImageText(input: input, workDir: workDir, log: &log, notes: &notes), nil)
            }
            return (try await runImageIO(input: input, target: target, adjustments: imageAdjustments,
                                         workDir: workDir, log: &log, notes: &notes), nil)
        case .builtin:
            return (try await runBuiltin(input: input, target: target, workDir: workDir, log: &log,
                                         notes: &notes), nil)
        case .archiver:
            return (try await runArchive(input: input, target: target, workDir: workDir, log: &log,
                                         notes: &notes), nil)
        case .ollama:
            let translation = try await runCodeTranslation(input: input, target: target, stem: stem,
                                                           workDir: workDir, log: &log, notes: &notes)
            return (translation.0, translation.1)
        }
    }

    // MARK: Engines

    private func runFFmpeg(input: DetectedFile, target: OutputFormat, workDir: URL,
                           log: inout [String]) async throws -> URL {
        guard let tool = tools.locate(["ffmpeg"]) else { throw ConversionError.toolNotFound("FFmpeg") }
        // A video without an audio track has no sound to save. FFmpeg's own error for this is unclear.
        if Self.audioOnlyTargets.contains(target.id), input.category == .video {
            let audible = try await hasAudio(input.url)
            guard audible else {
                throw ConversionError.unsupported(
                    "\(input.url.lastPathComponent) has no sound track, so there is no audio to save.")
            }
        }
        let output = workDir.appendingPathComponent("out.\(target.fileExtension)")
        // FFmpeg writes its progress as key=value lines to stdout. Their time, against the length, is the percentage.
        let duration = await mediaDuration(input.url)
        // Conversions run side by side, so each gets its share of the cores instead of every one asking for all of them.
        let threads = ["-threads", "\(ResourcePlan.threadsPerConversion())"]
        let args = ["-hide_banner", "-loglevel", "error", "-nostats", "-progress", "pipe:1", "-y", "-i", input.url.path]
            + Self.ffmpegOptions(for: target.id) + threads + [output.path]
        log.append("ffmpeg \(args.joined(separator: " "))")
        let result = try await ProcessRunner.run(tool, arguments: args, onOutput: { [self] line in
            guard let duration, duration > 0, line.hasPrefix("out_time_us="),
                  let microseconds = Double(line.dropFirst("out_time_us=".count)) else { return }
            self.report("Converting", fraction: microseconds / 1_000_000 / duration)
        })
        guard result.exitCode == 0 else {
            throw ConversionError.toolFailed(tool: "FFmpeg", exitCode: result.exitCode,
                                             message: Self.lastLines(result.stderr))
        }
        return try requireOutput(output, tool: "FFmpeg")
    }

    /// The length of a media file in seconds. Nil when ffprobe is missing or cannot read the file.
    private func mediaDuration(_ url: URL) async -> Double? {
        guard let probe = tools.locate(["ffprobe"]),
              let result = try? await ProcessRunner.run(probe, arguments: [
                  "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", url.path,
              ]), result.exitCode == 0 else { return nil }
        return Double(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// True when the file has at least one audio stream. Uses ffprobe, which comes with FFmpeg.
    /// If ffprobe is missing, returns true and lets FFmpeg report any problem.
    private func hasAudio(_ url: URL) async throws -> Bool {
        guard let probe = tools.locate(["ffprobe"]) else { return true }
        let result = try await ProcessRunner.run(probe, arguments: [
            "-v", "error", "-select_streams", "a", "-show_entries", "stream=index", "-of", "csv=p=0", url.path,
        ])
        guard result.exitCode == 0 else { return true }
        return !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The first system font that exists on this Mac, used for SVG text.
    static let svgFont: String? = [
        "/System/Library/Fonts/Helvetica.ttc",
        "/System/Library/Fonts/Supplemental/Arial.ttf",
    ].first { FileManager.default.fileExists(atPath: $0) }

    /// Encoder settings for each FFmpeg target. Kept separate so they can be unit tested.
    public static func ffmpegOptions(for targetID: String) -> [String] {
        switch targetID {
        case "mp4": return ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-movflags", "+faststart"]
        case "mkv": return []
        case "wmv": return ["-c:v", "wmv2", "-b:v", "2M", "-c:a", "wmav2"]
        case "flv": return ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac"]
        case "3gp": return ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-ar", "44100"]
        case "mov": return ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac"]
        case "avi": return ["-c:v", "mpeg4", "-q:v", "4", "-c:a", "libmp3lame"]
        case "webm": return ["-c:v", "libvpx-vp9", "-crf", "32", "-b:v", "0", "-c:a", "libopus"]
        case "gif": return ["-an", "-vf", "fps=12,scale=480:-1:flags=lanczos"]
        case "mp3": return ["-vn", "-c:a", "libmp3lame", "-q:a", "2"]
        case "wav": return ["-vn", "-c:a", "pcm_s16le"]
        case "flac": return ["-vn", "-c:a", "flac"]
        case "m4a": return ["-vn", "-c:a", "aac", "-b:a", "192k"]
        // Opus inside an Ogg container. Vorbis is not built into every Homebrew FFmpeg.
        case "ogg": return ["-vn", "-c:a", "libopus", "-b:a", "128k"]
        default: return []
        }
    }

    private func runImageMagick(input: DetectedFile, target: OutputFormat, workDir: URL,
                                log: inout [String]) async throws -> URL {
        guard let tool = tools.locate(["magick", "convert"]) else {
            throw ConversionError.toolNotFound("ImageMagick")
        }
        let output = workDir.appendingPathComponent("out.\(target.fileExtension)")
        // "[0]" takes the first frame of animated or multi-page files.
        var args: [String] = []
        if input.formatID == "svg" {
            args += ["-density", "300"]
            // ImageMagick's SVG renderer needs a font for <text>. Macs have no default font set for it.
            if let font = Self.svgFont { args += ["-font", font] }
        }
        args += [input.url.path + "[0]", output.path]
        log.append("magick \(args.joined(separator: " "))")
        let result = try await ProcessRunner.run(tool, arguments: args)
        guard result.exitCode == 0 else {
            throw ConversionError.toolFailed(tool: "ImageMagick", exitCode: result.exitCode,
                                             message: Self.lastLines(result.stderr))
        }
        return try requireOutput(output, tool: "ImageMagick")
    }

    private func runLibreOffice(input: DetectedFile, target: OutputFormat, stem: String,
                                workDir: URL, log: inout [String]) async throws -> URL {
        guard let tool = tools.locate(["soffice"]) else { throw ConversionError.toolNotFound("LibreOffice") }
        // A private profile per run. A shared profile makes a second run fail while the first is open.
        let profile = workDir.appendingPathComponent("profile", isDirectory: true)
        var args = [
            "--headless", "--norestore",
            "-env:UserInstallation=\(profile.absoluteString)",
            "--convert-to", target.fileExtension,
            "--outdir", workDir.path,
            input.url.path,
        ]
        // LibreOffice opens a PDF in its drawing module, which cannot save Word or OpenDocument text.
        // Opening it with the Writer PDF importer makes those formats available.
        if input.formatID == "pdf" && (target.id == "docx" || target.id == "odt") {
            args.insert("--infilter=writer_pdf_import", at: 0)
        }
        log.append("soffice \(args.joined(separator: " "))")
        let result = try await ProcessRunner.run(tool, arguments: args)
        guard result.exitCode == 0 else {
            throw ConversionError.toolFailed(tool: "LibreOffice", exitCode: result.exitCode,
                                             message: Self.lastLines(result.stderr + result.stdout))
        }
        // LibreOffice names its output after the input file's name, which may be an intermediate "out" file.
        return try requireOutput(workDir.appendingPathComponent("\(FileNames.stem(input.url)).\(target.fileExtension)"),
                                 tool: "LibreOffice")
    }

    private func runPandoc(input: DetectedFile, target: OutputFormat, workDir: URL,
                           log: inout [String]) async throws -> URL {
        guard let tool = tools.locate(["pandoc"]) else { throw ConversionError.toolNotFound("Pandoc") }
        guard let from = FormatCatalog.pandocName(input.formatID, input: true),
              let to = FormatCatalog.pandocName(target.id, input: false) else {
            throw ConversionError.unsupported("Pandoc cannot convert \(input.formatID) to \(target.id).")
        }
        let output = workDir.appendingPathComponent("out.\(target.fileExtension)")
        var args = ["--from", from, "--to", to, "-o", output.path]
        // Without --standalone, Pandoc writes a fragment that is not a complete RTF or HTML file.
        if to == "html" || to == "epub" || to == "rtf" { args.append("--standalone") }
        args.append(input.url.path)
        log.append("pandoc \(args.joined(separator: " "))")
        let result = try await ProcessRunner.run(tool, arguments: args)
        guard result.exitCode == 0 else {
            throw ConversionError.toolFailed(tool: "Pandoc", exitCode: result.exitCode,
                                             message: Self.lastLines(result.stderr))
        }
        return try requireOutput(output, tool: "Pandoc")
    }

    private func runCodeTranslation(input: DetectedFile, target: OutputFormat, stem: String,
                                    workDir: URL, log: inout [String],
                                    notes: inout [String]) async throws -> (URL, ValidationResult) {
        guard let source = FormatCatalog.codeLanguage(forID: input.formatID),
              let destination = FormatCatalog.codeLanguage(forID: target.id) else {
            throw ConversionError.unsupported("Unknown language pair.")
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: input.url.path)[.size] as? Int) ?? 0
        guard size <= Self.maxCodeBytes else {
            throw ConversionError.inputTooLarge(bytes: size, limit: Self.maxCodeBytes)
        }
        let code = try CodeText.read(input.url)

        guard await ollama.ensureRunning(tools: tools) else {
            throw ConversionError.ollamaUnavailable("Could not start Ollama. Open the Ollama app or run ollama serve, then try again.")
        }
        // Check the source first. Broken input usually gives a broken translation.
        let fileName = "\(stem).\(target.fileExtension)"
        let sourceCheck = try await validator.validate(code: code, language: source,
                                                       fileName: input.url.lastPathComponent, workDir: workDir)
        log.append("source syntax check: \(sourceCheck.summary)")

        log.append("ollama generate model=\(ollama.model) \(source.id)->\(destination.id)")
        var translated: String
        if code.utf8.count <= CodeChunker.wholeFileBytes {
            translated = try await generateCode(CodePrompt.make(source: source, target: destination,
                                                                code: code, className: stem))
        } else {
            // A Java class is cut between its members. Any other long file is cut at its top-level definitions.
            // Each part is translated on its own, then joined.
            let javaClass = source.id == "java" ? CodeChunker.splitJavaClass(code) : nil
            let pieces = javaClass?.parts ?? CodeChunker.split(code)
            log.append("long file: translating \(pieces.count) parts, then joining them")
            var translatedParts: [String] = []
            for (index, piece) in pieces.enumerated() {
                try Task.checkCancellation()
                report("Translating part \(index + 1) of \(pieces.count)", fraction: Double(index) / Double(pieces.count))
                let prompt = javaClass.map {
                    CodePrompt.members(source: source, target: destination, code: piece, className: $0.className,
                                       imports: $0.header, index: index + 1, count: pieces.count)
                } ?? CodePrompt.part(source: source, target: destination, code: piece, className: stem,
                                     index: index + 1, count: pieces.count)
                translatedParts.append(try await generateCode(prompt))
            }
            if destination.id == "java" {
                // A class in the source stays a class of its own. Any other class is one the model added around a part.
                translated = CodeChunker.joinJavaClass(translatedParts, className: stem,
                                                       keeping: CodeChunker.typeNames(in: code))
                log.append("Java: the parts are joined into one class named \(stem)")
            } else {
                translated = CodeChunker.join(translatedParts)
            }
            if let javaClass {
                notes.append("This long Java class was translated member by member, so \(javaClass.className) is now top-level functions and variables, not a class. Check how they fit together.")
            }
        }
        report("Checking the code")
        var check = try await validator.validate(code: translated, language: destination,
                                                 fileName: fileName, workDir: workDir)

        // One repair attempt: send the checker's own error messages back to the model.
        // A joined file too large for one repair request is saved with its errors listed instead.
        if case .failed(_, let messages) = check, repairAttempts > 0 {
            log.append("syntax check failed:")
            log.append(contentsOf: messages.map { "  \($0)" })
            if translated.utf8.count > CodeChunker.repairBytes {
                log.append("the file is too large for one repair request, so it is saved with the errors listed")
            } else {
                log.append("asking the model to repair the code")
                report("Repairing the code")
                translated = try await generateCode(CodePrompt.repair(target: destination, code: translated,
                                                                      errors: messages, className: stem))
                check = try await validator.validate(code: translated, language: destination,
                                                     fileName: fileName, workDir: workDir)
            }
        }
        log.append("syntax check: \(check.summary)")

        let output = workDir.appendingPathComponent("out.\(target.fileExtension)")
        try translated.write(to: output, atomically: true, encoding: .utf8)
        return (output, check)
    }

    /// Runs the model and cleans its reply. Throws when the reply contains no code.
    private func generateCode(_ prompt: String) async throws -> String {
        let text = CodeOutputCleaner.clean(try await ollama.generate(prompt))
        guard !text.isEmpty else {
            throw ConversionError.unsupported("The model returned no code. Try again.")
        }
        return text
    }

    /// PDF to text, or to one image per page (Poppler).
    private func runPoppler(input: DetectedFile, target: OutputFormat, workDir: URL,
                            log: inout [String], notes: inout [String]) async throws -> URL {
        if target.id == "txt" {
            guard let tool = tools.locate(["pdftotext"]) else { throw ConversionError.toolNotFound("Poppler") }
            let output = workDir.appendingPathComponent("out.txt")
            try await execute("pdftotext", tool, ["-enc", "UTF-8", input.url.path, output.path], log: &log)
            // A scanned page holds a picture and no text, so Vision reads the picture instead. pdftotext ends each
            // page with a form feed, so an empty page shows up here, even among pages that do have text.
            let layer = (try? String(contentsOf: output, encoding: .utf8)) ?? ""
            let hasEmptyPage = layer.components(separatedBy: "\u{0C}").dropLast()
                .contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            let hasNoText = layer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if hasEmptyPage || hasNoText {
                log.append("a page has no text layer, reading such pages with Vision")
                let url = input.url
                let result = try await Self.offThread { [self] in
                    try TextRecognition.recognize(pdf: url) { fraction in
                        self.report("Reading the pages", fraction: fraction)
                    }
                }
                if result.recognizedText {
                    try result.text.write(to: output, atomically: true, encoding: .utf8)
                    notes.append(hasNoText
                        ? "This PDF has no text layer, so its text was read from the page images. Check it for mistakes."
                        : "\(result.scannedPages) page(s) have no text layer, so their text was read from the page images. Check them for mistakes.")
                } else if hasNoText {
                    notes.append("No text was found on the pages.")
                }
            }
            return try requireOutput(output, tool: "Poppler")
        }
        // No -f or -l options, so every page is converted. pdftoppm names the files page-1.png, page-2.png and so on.
        guard let tool = tools.locate(["pdftoppm"]) else { throw ConversionError.toolNotFound("Poppler") }
        let format = target.id == "jpg" ? "-jpeg" : "-png"
        let pages = try makePagesFolder(workDir)
        try await execute("pdftoppm", tool, [format, "-r", "150", input.url.path,
                                             pages.appendingPathComponent("page").path], log: &log)
        return try await packagePages(pages, ext: target.fileExtension, workDir: workDir, log: &log, tool: "Poppler")
    }

    /// PostScript and EPS to PDF, or to one image per page (Ghostscript).
    private func runGhostscript(input: DetectedFile, target: OutputFormat, workDir: URL,
                                log: inout [String]) async throws -> URL {
        guard let tool = tools.locate(["gs"]) else { throw ConversionError.toolNotFound("Ghostscript") }
        let base = ["-q", "-dNOPAUSE", "-dBATCH", "-dSAFER"]
        if target.id == "pdf" {
            let output = workDir.appendingPathComponent("out.pdf")
            try await execute("Ghostscript", tool, base + ["-sDEVICE=pdfwrite", "-sOutputFile=\(output.path)",
                                                           input.url.path], log: &log)
            return try requireOutput(output, tool: "Ghostscript")
        }
        let device: [String]
        switch target.id {
        case "png": device = ["-sDEVICE=png16m", "-r150"]
        case "jpg": device = ["-sDEVICE=jpeg", "-dJPEGQ=90", "-r150"]
        default: throw ConversionError.unsupported("Ghostscript cannot write \(target.id).")
        }
        // %03d is replaced by the page number, so each page gets its own file.
        let pages = try makePagesFolder(workDir)
        try await execute("Ghostscript", tool, base + device
                          + ["-sOutputFile=\(pages.path)/page-%03d.\(target.fileExtension)", input.url.path], log: &log)
        return try await packagePages(pages, ext: target.fileExtension, workDir: workDir, log: &log, tool: "Ghostscript")
    }

    /// Makes a PDF smaller with Ghostscript. A preset runs once. A custom size tries stronger settings until the
    /// file fits. If nothing fits, the smallest result is kept and a note says so. A result that is not smaller
    /// than the original is replaced by a copy of the original.
    private func compressPDF(input: DetectedFile, compression: PDFCompression, workDir: URL,
                             log: inout [String], notes: inout [String]) async throws -> URL {
        guard let tool = tools.locate(["gs"]) else { throw ConversionError.toolNotFound("Ghostscript") }
        let originalSize = Int(Preflight.fileSize(input.url))
        let kept = workDir.appendingPathComponent("out.pdf")
        func keepOriginal() throws -> URL {
            try FileManager.default.copyItem(at: input.url, to: kept)
            return kept
        }

        if let goal = compression.goalBytes, originalSize <= goal {
            notes.append("The file is already \(FileSize.text(goal)) or smaller, so it was not changed.")
            return try keepOriginal()
        }

        let base = ["-q", "-dNOPAUSE", "-dBATCH", "-dSAFER", "-sDEVICE=pdfwrite", "-dCompatibilityLevel=1.6"]
        let attempts = compression.attempts
        var smallest: (url: URL, size: Int)?
        for (index, settings) in attempts.enumerated() {
            try Task.checkCancellation()
            // One attempt cannot be measured, so it shows a spinner.
            report(attempts.count > 1 ? "Compressing, try \(index + 1) of \(attempts.count)" : "Compressing",
                   fraction: attempts.count > 1 ? Double(index) / Double(attempts.count) : nil)
            let output = workDir.appendingPathComponent("compressed-\(index).pdf")
            try await execute("Ghostscript", tool, base + settings + ["-sOutputFile=\(output.path)", input.url.path],
                              log: &log)
            let size = Int(Preflight.fileSize(output))
            guard size > 0 else { continue }
            if smallest.map({ size < $0.size }) ?? true {
                smallest = (output, size)
            }
            if let goal = compression.goalBytes, size <= goal { break }
        }

        guard let best = smallest else { throw ConversionError.outputMissing(tool: "Ghostscript") }
        if best.size >= originalSize {
            notes.append("Compression did not make this file smaller, so the original was kept.")
            return try keepOriginal()
        }
        if let goal = compression.goalBytes, best.size > goal {
            notes.append("Could not get the file to \(FileSize.text(goal)). The smallest version is \(FileSize.text(best.size)).")
        }
        try FileManager.default.moveItem(at: best.url, to: kept)
        return kept
    }

    private func makePagesFolder(_ workDir: URL) throws -> URL {
        let pages = workDir.appendingPathComponent("pages", isDirectory: true)
        try FileManager.default.createDirectory(at: pages, withIntermediateDirectories: true)
        return pages
    }

    /// Turns a folder of page images into the step's result. One page stays a single image. Several pages become
    /// a folder, or a ZIP file when the user chose that in Settings.
    private func packagePages(_ pages: URL, ext: String, workDir: URL, log: inout [String],
                              tool: String) async throws -> URL {
        let images = try FileManager.default.contentsOfDirectory(at: pages, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == ext }
        guard !images.isEmpty else { throw ConversionError.outputMissing(tool: tool) }
        if images.count == 1 {
            let single = workDir.appendingPathComponent("out.\(ext)")
            try FileManager.default.moveItem(at: images[0], to: single)
            return single
        }
        switch pageOutput {
        case .folder:
            log.append("\(images.count) pages, one image each, saved in a folder")
            return pages
        case .zip:
            guard let ditto = tools.locate(["ditto"]) else { throw ConversionError.toolNotFound("ditto") }
            let zip = workDir.appendingPathComponent("out.zip")
            log.append("\(images.count) pages, one image each, saved in a ZIP file")
            try await execute("ditto", ditto, ["-c", "-k", "--norsrc", "--noextattr", "--noqtn", pages.path, zip.path],
                               log: &log)
            return try requireOutput(zip, tool: "ditto")
        }
    }

    /// 3D models (Assimp). The target's Assimp format name is set by `assimpFormat`.
    private func runAssimp(input: DetectedFile, target: OutputFormat, workDir: URL,
                           log: inout [String]) async throws -> URL {
        guard let tool = tools.locate(["assimp"]) else { throw ConversionError.toolNotFound("Assimp") }
        guard let format = Self.assimpFormat(for: target.id) else {
            throw ConversionError.unsupported("Assimp cannot write \(target.id).")
        }
        let output = workDir.appendingPathComponent("out.\(target.fileExtension)")
        try await execute("Assimp", tool, ["export", input.url.path, output.path, "-f\(format)"], log: &log)
        return try requireOutput(output, tool: "Assimp")
    }

    /// E-books through Calibre's ebook-convert. The output format comes from the output file's extension.
    private func runCalibre(input: DetectedFile, target: OutputFormat, workDir: URL,
                            log: inout [String]) async throws -> URL {
        guard let tool = tools.locate(["ebook-convert"]) else { throw ConversionError.toolNotFound("Calibre") }
        let output = workDir.appendingPathComponent("out.\(target.fileExtension)")
        // Offscreen Qt means Calibre's PDF renderer does not need a display, which a background app does not have.
        try await execute("Calibre", tool, [input.url.path, output.path],
                          environment: ["QT_QPA_PLATFORM": "offscreen"], log: &log)
        return try requireOutput(output, tool: "Calibre")
    }

    /// Assimp's name for each 3D target.
    public static func assimpFormat(for targetID: String) -> String? {
        switch targetID {
        case "obj": return "obj"
        case "stl": return "stl"
        case "ply": return "ply"
        case "dae": return "collada"
        case "gltf": return "gltf2"
        case "glb": return "glb2"
        default: return nil
        }
    }

    /// Converts between TrueType, OpenType and the web formats WOFF and WOFF2, using fontTools.
    private func runFonts(input: DetectedFile, target: OutputFormat, workDir: URL,
                          log: inout [String]) async throws -> URL {
        guard let python = Self.fontPython(tools: tools) else {
            throw ConversionError.toolNotFound("fontTools (see the user guide, section 2)")
        }
        let output = workDir.appendingPathComponent("out.\(target.fileExtension)")
        let script = """
        import sys
        from fontTools.ttLib import TTFont
        src, dst, target = sys.argv[1:4]
        font = TTFont(src)
        cff = 'CFF ' in font
        if target in ('woff', 'woff2'):
            font.flavor = target
        elif target == 'otf' and not cff:
            sys.exit('This font has TrueType outlines, so it cannot be saved as OTF.')
        elif target == 'ttf' and cff:
            sys.exit('This font has PostScript outlines, so it cannot be saved as TTF.')
        else:
            font.flavor = None
        font.save(dst)
        """
        log.append("fontTools \(input.url.lastPathComponent) -> \(target.id)")
        let result = try await ProcessRunner.run(python, arguments: [
            "-c", script, input.url.path, output.path, target.id,
        ])
        guard result.exitCode == 0 else {
            if result.stderr.contains("No module named") {
                throw ConversionError.toolNotFound("fontTools (see the user guide, section 2)")
            }
            throw ConversionError.unsupported(Self.lastLines(result.stderr))
        }
        return try requireOutput(output, tool: "fontTools")
    }

    /// Python with fontTools. Uses the environment from the user guide if it exists, otherwise Homebrew's Python.
    public static func fontPython(tools: ToolLocator) -> URL? {
        let venv = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".venvs/converter/bin/python")
        if FileManager.default.isExecutableFile(atPath: venv.path) { return venv }
        return tools.locate(["python3.12"])
    }

    /// Unpacks an archive into a private folder, then packs the same top-level items in the new format.
    private func runArchive(input: DetectedFile, target: OutputFormat, workDir: URL,
                            log: inout [String], notes: inout [String]) async throws -> URL {
        let extracted = workDir.appendingPathComponent("extracted", isDirectory: true)
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)

        // 7-Zip reads ZIP and 7z. The system tar reads tar and tar.gz.
        switch input.formatID {
        case "zip", "7z":
            try await extractWithSevenZip(input.url, into: extracted, log: &log)
        case "rar":
            // macOS's tar (libarchive) reads RAR5 files that 7-Zip cannot decompress, so it goes first.
            // 7-Zip is the fallback. RAR is only ever an input, because neither tool can write RAR.
            do {
                try await execute("tar", try requireTar(), ["-xf", input.url.path, "-C", extracted.path], log: &log)
            } catch {
                log.append("tar could not read the RAR file, trying 7-Zip")
                try? FileManager.default.removeItem(at: extracted)
                try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
                do {
                    try await extractWithSevenZip(input.url, into: extracted, log: &log)
                } catch ConversionError.toolFailed(_, _, let message) where message.contains("Unsupported Method") {
                    throw ConversionError.unsupported("This RAR archive uses a compression method that neither tar nor 7-Zip can read. Extract it with another app, then convert the files.")
                }
            }
        case "targz", "tar":
            try await execute("tar", try requireTar(),
                              ["-xf", input.url.path, "-C", extracted.path], log: &log)
        default:
            throw ConversionError.unsupported("This archive type cannot be opened yet.")
        }
        Self.dropLinks(in: extracted, notes: &notes)

        let items = try FileManager.default.contentsOfDirectory(atPath: extracted.path).sorted()
        guard !items.isEmpty else {
            throw ConversionError.unsupported("The archive is empty, so there is nothing to convert.")
        }

        // Repack. Item names are relative, so the new archive has clean paths.
        let output = workDir.appendingPathComponent("out.\(target.fileExtension)")
        switch target.id {
        case "zip", "7z":
            try await execute("7-Zip", try requireSevenZip(),
                              ["a", "-y", "-t\(target.id)", output.path] + items,
                              cwd: extracted, log: &log)
        case "targz":
            try await execute("tar", try requireTar(),
                              ["-czf", output.path, "-C", extracted.path] + items, log: &log)
        case "tar":
            try await execute("tar", try requireTar(),
                              ["-cf", output.path, "-C", extracted.path] + items, log: &log)
        default:
            throw ConversionError.unsupported("Cannot create a \(target.id) archive.")
        }
        return try requireOutput(output, tool: "Archive")
    }

    private func requireSevenZip() throws -> URL {
        // "7zz" is the name used by Homebrew's newer 7-Zip package. "7z" comes from p7zip.
        guard let tool = tools.locate(["7zz", "7z"]) else { throw ConversionError.toolNotFound("7-Zip") }
        return tool
    }

    private func requireTar() throws -> URL {
        guard let tool = tools.locate(["tar"]) else { throw ConversionError.toolNotFound("tar") }
        return tool
    }

    /// Unpacks with 7-Zip. An encrypted archive gets a clear message, because 7-Zip would only ask for a password.
    private func extractWithSevenZip(_ archive: URL, into folder: URL, log: inout [String]) async throws {
        do {
            try await execute("7-Zip", try requireSevenZip(),
                              ["x", "-y", "-o" + folder.path, archive.path], log: &log)
        } catch ConversionError.toolFailed(_, _, let message) where message.localizedCaseInsensitiveContains("password") {
            throw ConversionError.unsupported("This archive is password-protected. Universal Converter cannot open password-protected archives yet.")
        }
    }

    /// Runs a tool, logs the command, and throws if it fails.
    func execute(_ tool: String, _ executable: URL, _ arguments: [String], cwd: URL? = nil,
                         environment: [String: String] = [:], log: inout [String]) async throws {
        log.append("\(executable.lastPathComponent) \(arguments.joined(separator: " "))")
        let result = try await ProcessRunner.run(executable, arguments: arguments,
                                                 environment: environment, workingDirectory: cwd)
        guard result.exitCode == 0 else {
            throw ConversionError.toolFailed(tool: tool, exitCode: result.exitCode,
                                             message: Self.failureLines(result.stderr + result.stdout))
        }
    }

    // MARK: Helpers

    static func isFolder(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    func requireOutput(_ url: URL, tool: String) throws -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ConversionError.outputMissing(tool: tool)
        }
        return url
    }

    /// Removes symbolic links from an unpacked archive and notes how many. Repacking would follow a link and
    /// copy the file it points to, which may be anywhere on this Mac, into the result.
    static func dropLinks(in folder: URL, notes: inout [String]) {
        let count = removeLinks(in: folder)
        guard count > 0 else { return }
        notes.append(count == 1 ? "1 symbolic link was left out of the archive."
                                : "\(count) symbolic links were left out of the archive.")
    }

    static func removeLinks(in folder: URL) -> Int {
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isSymbolicLinkKey]) else {
            return 0
        }
        var links: [URL] = []
        for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
            links.append(url)
        }
        for link in links { try? FileManager.default.removeItem(at: link) }
        return links.count
    }

    /// Deletes work folders that an earlier run left behind, for example when the app quit during a conversion.
    /// Only folders older than `age` go, so a conversion in another window or app is never touched.
    public static func removeStaleWork(olderThan age: TimeInterval = 24 * 60 * 60) {
        let temp = FileManager.default.temporaryDirectory
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: temp.path) else { return }
        for name in names where name.hasPrefix("fc-work-") || name.hasPrefix("fc-proc-") {
            let url = temp.appendingPathComponent(name)
            guard let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  Date().timeIntervalSince(modified) > age else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// The lines that say what went wrong. 7-Zip marks them with "ERROR:". Otherwise, the last lines of the output.
    static func failureLines(_ text: String) -> String {
        let errors = text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("ERROR") }
        return errors.isEmpty ? lastLines(text) : errors.prefix(3).joined(separator: "\n")
    }

    /// The last few meaningful lines of a tool's log, for error messages.
    static func lastLines(_ text: String, count: Int = 6) -> String {
        text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .suffix(count)
            .joined(separator: "\n")
    }
}

/// How the images of a multi-page PDF or PostScript file are delivered.
public enum PageOutput: Sendable, Equatable {
    /// A folder holding one image per page, named page-1.png, page-2.png and so on.
    case folder
    /// One ZIP file holding the same images.
    case zip
}

/// Chooses output file names that never overwrite an existing file.
public enum OutputNaming {
    /// A nil extension gives a bare name, which is used for folders.
    public static func uniqueURL(stem: String, ext: String?, in directory: URL) -> URL {
        func name(_ base: String) -> String { ext.map { "\(base).\($0)" } ?? base }
        var candidate = directory.appendingPathComponent(name(stem))
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent(name("\(stem) (\(counter))"))
            counter += 1
        }
        return candidate
    }

    /// Moves a result into place under a name nobody else has taken. Two conversions that finish together can
    /// pick the same name, so a name that turns out to be taken is replaced by the next free one.
    public static func move(_ source: URL, stem: String, ext: String?, into directory: URL) throws -> URL {
        var lastError: Error?
        for _ in 0..<100 {
            let destination = uniqueURL(stem: stem, ext: ext, in: directory)
            do {
                try FileManager.default.moveItem(at: source, to: destination)
                return destination
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                lastError = error
            }
        }
        throw lastError ?? CocoaError(.fileWriteUnknown)
    }
}
