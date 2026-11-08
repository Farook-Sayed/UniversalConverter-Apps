import Foundation

public struct ConversionRequest: Sendable {
    public let input: DetectedFile
    /// One conversion, or several in a row, ending at the chosen format.
    public let route: Route
    public let outputDirectory: URL

    public init(input: DetectedFile, route: Route, outputDirectory: URL) {
        self.input = input
        self.route = route
        self.outputDirectory = outputDirectory
    }
}

public struct ConversionResult: Sendable {
    public let outputURL: URL
    public let engine: Engine
    /// The commands that were run, for the log view.
    public let log: [String]
    /// Set for code translations only.
    public let validation: ValidationResult?
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
            ("7z", "7-Zip", ["7z", "7zz"], "ZIP and 7z archives"),
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

    /// Source files larger than this are refused by the code branch. Larger inputs would exceed
    /// what the local model can read at once.
    public static let maxCodeBytes = 60 * 1024

    /// Targets that only keep the sound of a video. These need an audio track in the input.
    public static let audioOnlyTargets: Set<String> = ["mp3", "wav", "flac", "m4a", "ogg"]

    public init(tools: ToolLocator = ToolLocator(), ollama: OllamaClient = OllamaClient(), repairAttempts: Int = 1) {
        self.tools = tools
        self.ollama = ollama
        self.validator = CodeValidator(tools: tools)
        self.repairAttempts = repairAttempts
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
            let (produced, check) = try await runStep(input: current, target: step.output, stem: stem,
                                                      workDir: stepDir, log: &log)
            if isLast { validation = check }
            current = DetectedFile(url: produced, category: step.outputCategory, formatID: step.output.id,
                                   mimeType: "application/octet-stream", method: .magicBytes,
                                   extensionMismatch: false)
        }

        // A cancelled conversion must not leave a finished file behind.
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: request.outputDirectory, withIntermediateDirectories: true)
        let finalURL = OutputNaming.uniqueURL(stem: finalStem, ext: finalTarget.fileExtension,
                                              in: request.outputDirectory)
        try FileManager.default.moveItem(at: current.url, to: finalURL)
        return ConversionResult(outputURL: finalURL, engine: finalTarget.engine, log: log,
                                validation: validation)
    }

    /// One conversion, run by the engine the step names.
    private func runStep(input: DetectedFile, target: OutputFormat, stem: String, workDir: URL,
                         log: inout [String]) async throws -> (URL, ValidationResult?) {
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
            return (try await runPoppler(input: input, target: target, workDir: workDir, log: &log), nil)
        case .ghostscript:
            return (try await runGhostscript(input: input, target: target, workDir: workDir, log: &log), nil)
        case .assimp:
            return (try await runAssimp(input: input, target: target, workDir: workDir, log: &log), nil)
        case .calibre:
            return (try await runCalibre(input: input, target: target, workDir: workDir, log: &log), nil)
        case .archiver:
            return (try await runArchive(input: input, target: target, workDir: workDir, log: &log), nil)
        case .ollama:
            let translation = try await runCodeTranslation(input: input, target: target, stem: stem,
                                                           workDir: workDir, log: &log)
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
                    "\(input.url.lastPathComponent) has no sound track, so there is no audio to save as \(target.label).")
            }
        }
        let output = workDir.appendingPathComponent("out.\(target.fileExtension)")
        let args = ["-hide_banner", "-loglevel", "error", "-y", "-i", input.url.path]
            + Self.ffmpegOptions(for: target.id) + [output.path]
        log.append("ffmpeg \(args.joined(separator: " "))")
        let result = try await ProcessRunner.run(tool, arguments: args)
        guard result.exitCode == 0 else {
            throw ConversionError.toolFailed(tool: "FFmpeg", exitCode: result.exitCode,
                                             message: Self.lastLines(result.stderr))
        }
        return try requireOutput(output, tool: "FFmpeg")
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
                                    workDir: URL, log: inout [String]) async throws -> (URL, ValidationResult) {
        guard let source = FormatCatalog.codeLanguage(forID: input.formatID),
              let destination = FormatCatalog.codeLanguage(forID: target.id) else {
            throw ConversionError.unsupported("Unknown language pair.")
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: input.url.path)[.size] as? Int) ?? 0
        guard size <= Self.maxCodeBytes else {
            throw ConversionError.inputTooLarge(bytes: size, limit: Self.maxCodeBytes)
        }
        let code = try String(contentsOf: input.url, encoding: .utf8)

        guard await ollama.ensureRunning(tools: tools) else {
            throw ConversionError.ollamaUnavailable("Could not start Ollama. Open the Ollama app or run ollama serve, then try again.")
        }
        // Check the source first. Broken input usually gives a broken translation.
        let fileName = "\(stem).\(target.fileExtension)"
        let sourceCheck = try await validator.validate(code: code, language: source,
                                                       fileName: input.url.lastPathComponent, workDir: workDir)
        log.append("source syntax check: \(sourceCheck.summary)")

        log.append("ollama generate model=\(ollama.model) \(source.id)->\(destination.id)")
        var translated = try await generateCode(CodePrompt.make(source: source, target: destination,
                                                                code: code, className: stem))
        var check = try await validator.validate(code: translated, language: destination,
                                                 fileName: fileName, workDir: workDir)

        // One repair attempt: send the checker's own error messages back to the model.
        if case .failed(_, let messages) = check, repairAttempts > 0 {
            log.append("syntax check failed, asking the model to repair the code:")
            log.append(contentsOf: messages.map { "  \($0)" })
            translated = try await generateCode(CodePrompt.repair(target: destination, code: translated,
                                                                  errors: messages, className: stem))
            check = try await validator.validate(code: translated, language: destination,
                                                 fileName: fileName, workDir: workDir)
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

    /// PDF to text or to an image of the first page (Poppler).
    private func runPoppler(input: DetectedFile, target: OutputFormat, workDir: URL,
                            log: inout [String]) async throws -> URL {
        let output = workDir.appendingPathComponent("out.\(target.fileExtension)")
        if target.id == "txt" {
            guard let tool = tools.locate(["pdftotext"]) else { throw ConversionError.toolNotFound("Poppler") }
            try await execute("pdftotext", tool, ["-enc", "UTF-8", input.url.path, output.path], log: &log)
        } else {
            // pdftoppm adds the .png or .jpg extension to the prefix itself.
            guard let tool = tools.locate(["pdftoppm"]) else { throw ConversionError.toolNotFound("Poppler") }
            let format = target.id == "jpg" ? "-jpeg" : "-png"
            let prefix = workDir.appendingPathComponent("out").path
            try await execute("pdftoppm", tool, [format, "-singlefile", "-r", "150", "-f", "1", "-l", "1",
                                                 input.url.path, prefix], log: &log)
        }
        return try requireOutput(output, tool: "Poppler")
    }

    /// PostScript and EPS to PDF or to an image of the first page (Ghostscript).
    private func runGhostscript(input: DetectedFile, target: OutputFormat, workDir: URL,
                                log: inout [String]) async throws -> URL {
        guard let tool = tools.locate(["gs"]) else { throw ConversionError.toolNotFound("Ghostscript") }
        let output = workDir.appendingPathComponent("out.\(target.fileExtension)")
        var args = ["-q", "-dNOPAUSE", "-dBATCH", "-dSAFER"]
        switch target.id {
        case "pdf": args += ["-sDEVICE=pdfwrite"]
        case "png": args += ["-sDEVICE=png16m", "-r150", "-dFirstPage=1", "-dLastPage=1"]
        case "jpg": args += ["-sDEVICE=jpeg", "-dJPEGQ=90", "-r150", "-dFirstPage=1", "-dLastPage=1"]
        default: throw ConversionError.unsupported("Ghostscript cannot write \(target.id).")
        }
        args += ["-sOutputFile=\(output.path)", input.url.path]
        try await execute("Ghostscript", tool, args, log: &log)
        return try requireOutput(output, tool: "Ghostscript")
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
                            log: inout [String]) async throws -> URL {
        let extracted = workDir.appendingPathComponent("extracted", isDirectory: true)
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)

        // 7-Zip reads ZIP and 7z. The system tar reads tar and tar.gz.
        switch input.formatID {
        case "zip", "7z":
            try await execute("7-Zip", try requireSevenZip(),
                              ["x", "-y", "-o" + extracted.path, input.url.path], log: &log)
        case "targz", "tar":
            try await execute("tar", try requireTar(),
                              ["-xf", input.url.path, "-C", extracted.path], log: &log)
        default:
            throw ConversionError.unsupported("This archive type cannot be opened yet.")
        }

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
        guard let tool = tools.locate(["7z", "7zz"]) else { throw ConversionError.toolNotFound("7-Zip") }
        return tool
    }

    private func requireTar() throws -> URL {
        guard let tool = tools.locate(["tar"]) else { throw ConversionError.toolNotFound("tar") }
        return tool
    }

    /// Runs a tool, logs the command, and throws if it fails.
    private func execute(_ tool: String, _ executable: URL, _ arguments: [String], cwd: URL? = nil,
                         environment: [String: String] = [:], log: inout [String]) async throws {
        log.append("\(executable.lastPathComponent) \(arguments.joined(separator: " "))")
        let result = try await ProcessRunner.run(executable, arguments: arguments,
                                                 environment: environment, workingDirectory: cwd)
        guard result.exitCode == 0 else {
            throw ConversionError.toolFailed(tool: tool, exitCode: result.exitCode,
                                             message: Self.lastLines(result.stderr + result.stdout))
        }
    }

    // MARK: Helpers

    private func requireOutput(_ url: URL, tool: String) throws -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ConversionError.outputMissing(tool: tool)
        }
        return url
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

/// Chooses output file names that never overwrite an existing file.
public enum OutputNaming {
    public static func uniqueURL(stem: String, ext: String, in directory: URL) -> URL {
        var candidate = directory.appendingPathComponent("\(stem).\(ext)")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(stem) (\(counter)).\(ext)")
            counter += 1
        }
        return candidate
    }
}
