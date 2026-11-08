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
                    detail: "WebP, AVIF, HEIC, SVG, and PDF output.",
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
                    size: "About 10 MB", formulae: ["p7zip"],
                    installed: { $0.locate(["7z", "7zz"]) != nil }),
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

/// Installs a feature with Homebrew, then runs any extra steps it needs. One install at a time.
public enum ToolInstaller {
    public static func install(_ feature: ToolFeature, tools: ToolLocator, codeModel: String,
                               progress: @escaping @Sendable (String) -> Void) async throws -> [String] {
        guard let brew = tools.locate(["brew"]) else {
            throw ConversionError.toolNotFound("Homebrew. Install it from brew.sh, then try again")
        }
        var log: [String] = []
        for formula in feature.formulae {
            progress("Installing \(formula)…")
            try await run(brew, ["install", formula], named: "Homebrew", log: &log)
        }
        for cask in feature.casks {
            progress("Installing \(cask)…")
            try await run(brew, ["install", "--cask", cask], named: "Homebrew", log: &log)
        }
        for step in feature.extraSteps {
            switch step {
            case .fontEnvironment:
                progress("Setting up the font tools…")
                try await setUpFonts(tools: tools, log: &log)
            case .codeModel:
                progress("Downloading the code model. This can take a while…")
                try await pullCodeModel(codeModel, tools: tools, log: &log)
            case .typeScript:
                progress("Installing TypeScript…")
                guard let npm = tools.locate(["npm"]) else {
                    throw ConversionError.toolNotFound("npm, which comes with Node.js")
                }
                try await run(npm, ["install", "-g", "typescript"], named: "npm", log: &log)
            }
        }
        return log
    }

    /// Downloads one code model through Ollama. The model list in Settings uses this.
    public static func pullModel(_ name: String, tools: ToolLocator,
                                 progress: @escaping @Sendable (String) -> Void) async throws -> [String] {
        var log: [String] = []
        progress("Downloading \(name). This can take a while…")
        try await pullCodeModel(name, tools: tools, log: &log)
        return log
    }

    private static func setUpFonts(tools: ToolLocator, log: inout [String]) async throws {
        guard let python = tools.locate(["python3.12"]) else { throw ConversionError.toolNotFound("Python 3.12") }
        let environment = ToolFeature.fontEnvironment
        if !FileManager.default.isExecutableFile(atPath: environment.appendingPathComponent("bin/python").path) {
            try await run(python, ["-m", "venv", environment.path], named: "Python", log: &log)
        }
        try await run(environment.appendingPathComponent("bin/pip"), ["install", "fonttools", "brotli"],
                      named: "pip", log: &log)
    }

    private static func pullCodeModel(_ model: String, tools: ToolLocator, log: inout [String]) async throws {
        guard let ollama = tools.locate(["ollama"]) else { throw ConversionError.toolNotFound("Ollama") }
        guard await OllamaClient(model: model).ensureRunning(tools: tools) else {
            throw ConversionError.ollamaUnavailable("Could not start Ollama. Open the Ollama app, then try again.")
        }
        try await run(ollama, ["pull", model], named: "Ollama", log: &log)
    }

    private static func run(_ executable: URL, _ arguments: [String], named: String, log: inout [String]) async throws {
        log.append("\(named): \(executable.lastPathComponent) \(arguments.joined(separator: " "))")
        let result = try await ProcessRunner.run(executable, arguments: arguments)
        guard result.exitCode == 0 else {
            throw ConversionError.toolFailed(tool: named, exitCode: result.exitCode,
                                             message: Converter.lastLines(result.stderr + result.stdout))
        }
    }
}
