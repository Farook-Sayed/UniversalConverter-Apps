import Foundation

/// An optional group of tools. The app works without any of them. Each group adds formats.
public struct ToolFeature: Identifiable, Sendable {
    /// Steps that are more than a Homebrew install.
    public enum ExtraStep: Sendable {
        /// A Python environment with fontTools, in `ToolFeature.fontEnvironment`.
        case fontEnvironment
        /// The default code model, pulled through Ollama.
        case codeModel
        /// The TypeScript compiler, installed with npm.
        case typeScript
    }

    public let id: String
    public let title: String
    public let detail: String
    /// A rough download size. Real sizes depend on the Mac and on what is already installed.
    public let size: String
    public let formulae: [String]
    public let casks: [String]
    public let extraSteps: [ExtraStep]
    private let installedCheck: @Sendable (ToolLocator) -> Bool

    init(id: String, title: String, detail: String, size: String, formulae: [String] = [],
         casks: [String] = [], extraSteps: [ExtraStep] = [],
         installed: @escaping @Sendable (ToolLocator) -> Bool) {
        self.id = id
        self.title = title
        self.detail = detail
        self.size = size
        self.formulae = formulae
        self.casks = casks
        self.extraSteps = extraSteps
        self.installedCheck = installed
    }

    public func isInstalled(_ tools: ToolLocator) -> Bool {
        installedCheck(tools)
    }

    /// Where the font tools' Python environment lives. The converter looks here first.
    public static var fontEnvironment: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".venvs/converter")
    }

    /// The file Ollama keeps for the chosen code model. Its presence means that model is installed.
    public static var codeModelManifest: URL {
        CodeModels.manifestURL(for: CodeModels.selected)
    }

    public static let all: [ToolFeature] = [
        ToolFeature(id: "video", title: "Video, audio and subtitles",
                    detail: "More video formats (MKV, WebM, WMV, FLV, 3GP), MP3 and FLAC audio, subtitles and GIF.",
                    size: "About 200 MB", formulae: ["ffmpeg"],
                    installed: { $0.locate(["ffmpeg"]) != nil }),
        ToolFeature(id: "images", title: "More image formats",
                    detail: "WebP and AVIF, SVG input, and PDF output.",
                    size: "About 40 MB", formulae: ["imagemagick"],
                    installed: { $0.locate(["magick", "convert"]) != nil }),
        ToolFeature(id: "office", title: "Office documents and spreadsheets",
                    detail: "PDF from Word and slides, XLSX, ODS, CSV, PowerPoint and OpenDocument files.",
                    size: "About 800 MB", casks: ["libreoffice"],
                    installed: { $0.locate(["soffice"]) != nil }),
        ToolFeature(id: "markdown", title: "Markdown, HTML and EPUB",
                    detail: "Markdown, EPUB and the text formats, and Jupyter notebooks.",
                    size: "About 300 MB", formulae: ["pandoc"],
                    installed: { $0.locate(["pandoc"]) != nil }),
        ToolFeature(id: "ebooks", title: "E-books",
                    detail: "MOBI, AZW3 and FB2 e-books.",
                    size: "About 500 MB", casks: ["calibre"],
                    installed: { $0.locate(["ebook-convert"]) != nil }),
        ToolFeature(id: "pdf", title: "PDF text and pages",
                    detail: "PDF to text, PNG and JPEG.",
                    size: "About 100 MB", formulae: ["poppler"],
                    installed: { $0.locate(["pdftotext"]) != nil && $0.locate(["pdftoppm"]) != nil }),
        ToolFeature(id: "postscript", title: "PostScript and EPS",
                    detail: "PostScript and EPS to PDF, PNG and JPEG.",
                    size: "About 150 MB", formulae: ["ghostscript"],
                    installed: { $0.locate(["gs"]) != nil }),
        ToolFeature(id: "models", title: "3D models",
                    detail: "OBJ, STL, PLY, COLLADA, glTF and GLB.",
                    size: "About 60 MB", formulae: ["assimp"],
                    installed: { $0.locate(["assimp"]) != nil }),
        ToolFeature(id: "sevenzip", title: "7-Zip archives",
                    detail: "7z archives, and RAR archives as input.",
                    size: "About 10 MB", formulae: ["sevenzip"],
                    // The old p7zip cannot read all RAR files, so the current 7-Zip (7zz) is required.
                    installed: { $0.locate(["7zz"]) != nil }),
        ToolFeature(id: "fonts", title: "Fonts",
                    detail: "TTF, OTF, WOFF and WOFF2.",
                    size: "About 150 MB", formulae: ["python@3.12"], extraSteps: [.fontEnvironment],
                    installed: { _ in FileManager.default.isExecutableFile(
                        atPath: ToolFeature.fontEnvironment.appendingPathComponent("bin/python").path) }),
        ToolFeature(id: "code", title: "Code translation",
                    detail: "Translates code between languages with a model that runs on this Mac. Choose the model in Settings → Code.",
                    size: "1 to 9 GB, depending on the model", formulae: ["ollama"], extraSteps: [.codeModel],
                    installed: { $0.locate(["ollama"]) != nil
                        && FileManager.default.fileExists(atPath: ToolFeature.codeModelManifest.path) }),
        ToolFeature(id: "codeChecks", title: "Code checks",
                    detail: "Checks translated code with the Python, Node.js, Go, Rust and TypeScript compilers.",
                    size: "About 1.5 GB", formulae: ["node", "go", "rust", "python@3.12"], extraSteps: [.typeScript],
                    installed: { $0.locate(["node"]) != nil && $0.locate(["gofmt"]) != nil
                        && $0.locate(["rustc"]) != nil && $0.locate(["tsc"]) != nil }),
    ]
}

/// Installs a feature with Homebrew, then runs any extra steps it needs.
///
/// Several features can be installed at the same time. Each one first downloads everything it needs, side by side with
/// the others, then takes its turn to install, then runs its extra steps (the font tools, the model download) without
/// holding up anyone else.
public enum ToolInstaller {

    /// Settings that stop Homebrew doing slow extra work on every install: updating itself, cleaning up old versions,
    /// sending statistics, and upgrading packages the user did not ask about. None of them changes what gets installed.
    public static let brewEnvironment: [String: String] = [
        "HOMEBREW_NO_AUTO_UPDATE": "1",
        "HOMEBREW_NO_INSTALL_CLEANUP": "1",
        "HOMEBREW_NO_INSTALL_UPGRADE": "1",
        "HOMEBREW_NO_ANALYTICS": "1",
        "HOMEBREW_NO_ENV_HINTS": "1",
        // Newer Homebrew downloads several files at once. Older versions ignore this.
        "HOMEBREW_DOWNLOAD_CONCURRENCY": "auto",
    ]

    public static func install(_ feature: ToolFeature, tools: ToolLocator, codeModel: String,
                               coordinator: InstallCoordinator = .shared,
                               progress: @escaping @Sendable (String) -> Void) async throws -> [String] {
        guard let brew = tools.locate(["brew"]) else {
            throw ConversionError.toolNotFound("Homebrew. Install it from brew.sh, then try again")
        }
        let log = InstallLog()

        // 1. Download. Homebrew is asked exactly what the install would download, which leaves out what is already here
        //    and the build tools that a ready-made package never needs. Those packages are fetched in batches that run
        //    side by side, and a package that another feature is already fetching is waited for, not fetched twice.
        if !feature.formulae.isEmpty || !feature.casks.isEmpty {
            progress("Checking what to download…")
            let formulaNames = feature.formulae.isEmpty ? [] : await plannedDownloads(
                brew, ["install", "--dry-run", "--formula"] + feature.formulae, log: log)
            var downloads: [Task<Void, Never>] = []
            downloads += await coordinator.ledger.reserve(formulaNames, groups: ResourcePlan.downloadBatchesPerFeature, kind: "formula") { batch in
                await download(brew, ["fetch", "--formula"] + batch, coordinator: coordinator, log: log)
            }
            // A cask is one large file, so each gets a download of its own and does not wait behind the small tools.
            for cask in feature.casks {
                downloads += await coordinator.ledger.reserve([cask], groups: 1, kind: "cask") { batch in
                    await download(brew, ["fetch", "--cask"] + batch, coordinator: coordinator, log: log)
                }
            }
            progress("Downloading…")
            for task in downloads { await task.value }
        }
        try Task.checkCancellation()

        // 2. Install, one feature at a time. The files are already here, so this is quick.
        if !feature.formulae.isEmpty || !feature.casks.isEmpty {
            try await coordinator.installs.withSlot(onWait: { progress("Waiting for another install to finish…") }) {
                if !feature.formulae.isEmpty {
                    // One run for every formula, so Homebrew works out the shared dependencies once.
                    progress("Installing \(feature.formulae.joined(separator: ", "))…")
                    try await run(brew, ["install", "--formula"] + feature.formulae, named: "Homebrew",
                                  environment: brewEnvironment, log: log, onOutput: installProgress(progress))
                }
                for cask in feature.casks {
                    progress("Installing \(cask)…")
                    try await run(brew, ["install", "--cask", cask], named: "Homebrew", environment: brewEnvironment,
                                  log: log, onOutput: installProgress(progress))
                }
            }
        }

        // 3. Extra steps. They do not touch Homebrew's folders, so they run while other features install.
        for step in feature.extraSteps {
            try Task.checkCancellation()
            switch step {
            case .fontEnvironment:
                progress("Setting up the font tools…")
                try await setUpFonts(tools: tools, log: log)
            case .codeModel:
                progress("Downloading the code model. This can take a while…")
                try await pullCodeModel(codeModel, tools: tools, coordinator: coordinator, log: log)
            case .typeScript:
                progress("Installing TypeScript…")
                guard let npm = tools.locate(["npm"]) else {
                    throw ConversionError.toolNotFound("npm, which comes with Node.js")
                }
                try await run(npm, ["install", "-g", "typescript"], named: "npm", log: log)
            }
        }
        return log.lines
    }

    /// Downloads one code model through Ollama. The model list in Settings uses this.
    public static func pullModel(_ name: String, tools: ToolLocator, coordinator: InstallCoordinator = .shared,
                                 progress: @escaping @Sendable (String) -> Void) async throws -> [String] {
        let log = InstallLog()
        progress("Downloading \(name). This can take a while…")
        try await pullCodeModel(name, tools: tools, coordinator: coordinator, log: log)
        return log.lines
    }

    /// A line of Homebrew output as a short step, such as "Installing ffmpeg…". Nil for any other line.
    public static func step(fromBrewLine line: String) -> String? {
        // "==> Pouring ffmpeg--8.1.1.arm64_tahoe.bottle.tar.gz" names the package being unpacked.
        guard line.hasPrefix("==> Pouring ") else { return nil }
        let name = line.dropFirst("==> Pouring ".count).components(separatedBy: "--").first ?? ""
        return name.isEmpty ? nil : "Installing \(name)…"
    }

    private static func installProgress(_ progress: @escaping @Sendable (String) -> Void) -> @Sendable (String) -> Void {
        { line in
            if let step = step(fromBrewLine: line) { progress(step) }
        }
    }

    /// The packages Homebrew would download for these arguments, from a dry run. Empty when the dry run fails, in which
    /// case the install simply downloads for itself.
    private static func plannedDownloads(_ brew: URL, _ arguments: [String], log: InstallLog) async -> [String] {
        log.add("Homebrew: brew \(arguments.joined(separator: " "))")
        guard let result = try? await ProcessRunner.run(brew, arguments: arguments, environment: brewEnvironment),
              result.exitCode == 0 else {
            log.add("could not work out what to download in advance, so the install will download for itself")
            return []
        }
        return packageNames(fromDryRun: result.stdout)
    }

    /// The package names in a `brew install --dry-run` report. Each "==> Would install ..." heading is followed by one
    /// "name version" line for every package, up to the next heading.
    public static func packageNames(fromDryRun output: String) -> [String] {
        var names: [String] = []
        var listing = false
        for raw in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("==>") {
                listing = line.hasPrefix("==> Would install")
                continue
            }
            guard listing, !line.hasPrefix("Already downloaded"), let name = line.split(separator: " ").first else { continue }
            let text = String(name)
            if !names.contains(text) { names.append(text) }
        }
        return names
    }

    /// Downloads ahead of the install. A failure here is not fatal, because the install downloads again by itself and
    /// then reports the real problem.
    private static func download(_ brew: URL, _ arguments: [String], coordinator: InstallCoordinator,
                                 log: InstallLog) async {
        do {
            try await coordinator.downloads.withSlot {
                log.add("Homebrew: brew \(arguments.joined(separator: " "))")
                let result = try await ProcessRunner.run(brew, arguments: arguments, environment: brewEnvironment)
                if result.exitCode != 0 {
                    log.add("the download did not finish, so the install will try again: \(Converter.lastLines(result.stderr))")
                }
            }
        } catch {
            log.add("the download was stopped: \(error.localizedDescription)")
        }
    }

    private static func setUpFonts(tools: ToolLocator, log: InstallLog) async throws {
        guard let python = tools.locate(["python3.12"]) else { throw ConversionError.toolNotFound("Python 3.12") }
        let environment = ToolFeature.fontEnvironment
        if !FileManager.default.isExecutableFile(atPath: environment.appendingPathComponent("bin/python").path) {
            try await run(python, ["-m", "venv", environment.path], named: "Python", log: log)
        }
        try await run(environment.appendingPathComponent("bin/pip"), ["install", "fonttools", "brotli"],
                      named: "pip", log: log)
    }

    private static func pullCodeModel(_ model: String, tools: ToolLocator, coordinator: InstallCoordinator,
                                      log: InstallLog) async throws {
        guard let ollama = tools.locate(["ollama"]) else { throw ConversionError.toolNotFound("Ollama") }
        guard await OllamaClient(model: model).ensureRunning(tools: tools) else {
            throw ConversionError.ollamaUnavailable("Could not start Ollama. Open the Ollama app, then try again.")
        }
        // A model is a large download, so it takes one of the download slots like any other.
        try await coordinator.downloads.withSlot {
            try await run(ollama, ["pull", model], named: "Ollama", log: log)
        }
    }

    private static func run(_ executable: URL, _ arguments: [String], named: String,
                            environment: [String: String] = [:], log: InstallLog,
                            onOutput: (@Sendable (String) -> Void)? = nil) async throws {
        log.add("\(named): \(executable.lastPathComponent) \(arguments.joined(separator: " "))")
        let result = try await ProcessRunner.run(executable, arguments: arguments, environment: environment,
                                                 onOutput: onOutput)
        guard result.exitCode == 0 else {
            throw ConversionError.toolFailed(tool: named, exitCode: result.exitCode,
                                             message: Converter.lastLines(result.stderr + result.stdout))
        }
    }
}

/// The lines an install writes to its log. Several installs run at once, so adding a line is thread safe.
final class InstallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    func add(_ line: String) {
        lock.lock()
        stored.append(line)
        lock.unlock()
    }

    var lines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
