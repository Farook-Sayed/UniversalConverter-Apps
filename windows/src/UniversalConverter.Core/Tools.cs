using System.Runtime.InteropServices;

namespace UniversalConverter.Core;

/// <summary>Finds the programs the converter uses, including ones installed a moment ago.</summary>
public sealed class ToolLocator
{
    public static readonly bool IsWindows = RuntimeInformation.IsOSPlatform(OSPlatform.Windows);

    /// <summary>Extra places to look, in addition to PATH. Patterns may use * in a folder name.</summary>
    private static IEnumerable<string> ExtraFolders()
    {
        if (IsWindows)
        {
            string pf = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
            string pf86 = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86);
            string local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            string home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            return
            [
                Path.Combine(local, "Microsoft", "WinGet", "Links"),
                Path.Combine(pf, "LibreOffice", "program"), Path.Combine(pf86, "LibreOffice", "program"),
                Path.Combine(pf, "Calibre2"), Path.Combine(pf, "7-Zip"), Path.Combine(pf, "Pandoc"),
                Path.Combine(local, "Pandoc"), Path.Combine(pf, "gs", "gs*", "bin"),
                Path.Combine(local, "Programs", "Ollama"), Path.Combine(pf, "ffmpeg", "bin"),
                Path.Combine(pf, "nodejs"), Path.Combine(pf, "Go", "bin"), Path.Combine(home, ".cargo", "bin"),
                Path.Combine(pf, "LLVM", "bin"), Path.Combine(local, "Programs", "Python", "Python3*"),
                Path.Combine(pf, "Microsoft", "jdk-*", "bin"), Path.Combine(pf, "Eclipse Adoptium", "jdk-*", "bin"),
                Path.Combine(pf, "Java", "jdk-*", "bin"), Path.Combine(pf, "Ruby*", "bin"),
                Path.Combine(Environment.GetEnvironmentVariable("APPDATA") ?? "", "npm"),
            ];
        }
        return
        [
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
            "/Applications/LibreOffice.app/Contents/MacOS", "/Applications/calibre.app/Contents/MacOS",
        ];
    }

    /// <summary>The PATH a program is started with. On Windows it is read again from the registry, so a tool
    /// installed while the app is open is found without restarting it.</summary>
    public static string SearchPath()
    {
        // Reading the registry and listing the install folders for every lookup and every program start adds up when a
        // queue of files is checked, so the answer is kept for two seconds. A tool installed a moment ago is still found.
        lock (CacheGate)
        {
            if (_cachedPath is not null && DateTime.UtcNow - _cachedAt < TimeSpan.FromSeconds(2)) return _cachedPath;
            _cachedPath = BuildSearchPath();
            _cachedAt = DateTime.UtcNow;
            return _cachedPath;
        }
    }

    private static readonly object CacheGate = new();
    private static string? _cachedPath;
    private static DateTime _cachedAt;

    private static string BuildSearchPath()
    {
        var parts = new List<string>();
        void AddPath(string? value) { if (!string.IsNullOrEmpty(value)) parts.AddRange(value.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries)); }
        AddPath(Environment.GetEnvironmentVariable("PATH"));
        if (IsWindows)
        {
            AddPath(Environment.GetEnvironmentVariable("PATH", EnvironmentVariableTarget.Machine));
            AddPath(Environment.GetEnvironmentVariable("PATH", EnvironmentVariableTarget.User));
        }
        foreach (var folder in ExtraFolders()) parts.AddRange(Expand(folder));
        return string.Join(Path.PathSeparator, parts.Distinct(StringComparer.OrdinalIgnoreCase));
    }

    private static IEnumerable<string> Expand(string pattern)
    {
        if (!pattern.Contains('*')) return Directory.Exists(pattern) ? [pattern] : [];
        var segments = pattern.Split(Path.DirectorySeparatorChar);
        var current = new List<string> { segments[0] + Path.DirectorySeparatorChar };
        foreach (var segment in segments.Skip(1))
        {
            var next = new List<string>();
            foreach (var folder in current)
            {
                if (!Directory.Exists(folder)) continue;
                if (segment.Contains('*'))
                {
                    try { next.AddRange(Directory.GetDirectories(folder, segment).OrderDescending()); } catch { /* not readable */ }
                }
                else next.Add(Path.Combine(folder, segment));
            }
            current = next;
        }
        return current.Where(Directory.Exists);
    }

    private static readonly string[] Suffixes = IsWindows ? [".exe", ".cmd", ".bat", ""] : [""];

    /// <summary>The full path of the first of these programs that exists. Null when none is installed.</summary>
    public string? Locate(params string[] names)
    {
        var folders = SearchPath().Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries);
        foreach (var name in names)
        {
            foreach (var folder in folders)
            {
                // The "python" in WindowsApps is a shortcut to the Microsoft Store, not a Python.
                if (IsWindows && folder.Contains("WindowsApps", StringComparison.OrdinalIgnoreCase) && name != "winget") continue;
                foreach (var suffix in Suffixes)
                {
                    var candidate = Path.Combine(folder, name + suffix);
                    if (File.Exists(candidate)) return candidate;
                }
            }
        }
        return null;
    }

    /// <summary>Whether the tool an engine needs is installed and ready. Built-in conversions need nothing.</summary>
    public bool IsAvailable(Engine engine, string? codeModel = null) => engine switch
    {
        Engine.Image or Engine.Pdf or Engine.Archive or Engine.Assimp => true,
        Engine.Ocr => OcrAvailable,
        Engine.Ffmpeg => Locate("ffmpeg") is not null,
        Engine.LibreOffice => Locate("soffice") is not null,
        Engine.Pandoc => Locate("pandoc") is not null,
        Engine.Ollama => Locate("ollama") is not null && CodeModels.IsInstalled(codeModel ?? CodeModels.Selected),
        Engine.SevenZip => Locate("7zz", "7z") is not null,
        Engine.FontTools => FontPython(this) is not null,
        Engine.Ghostscript => GhostscriptPath(this) is not null,
        Engine.Calibre => Locate("ebook-convert") is not null,
        _ => false,
    };

    /// <summary>Set by the Windows app when the system's text recognition is available.</summary>
    public static bool OcrAvailable { get; set; }

    public static string? GhostscriptPath(ToolLocator tools) => tools.Locate("gswin64c", "gswin32c", "gs");

    /// <summary>Python with fontTools. Uses the environment the installer made, if it exists.</summary>
    public static string? FontPython(ToolLocator tools)
    {
        var venv = ToolFeature.FontEnvironmentPython;
        if (File.Exists(venv)) return venv;
        return tools.Locate("python3.12", "python3", "python");
    }
}

/// <summary>An optional group of tools. The app works without any of them. Each group adds formats.</summary>
public sealed class ToolFeature
{
    public enum Extra { FontEnvironment, CodeModel, TypeScript }

    public required string Id { get; init; }
    public required string Title { get; init; }
    public required string Detail { get; init; }
    /// <summary>A rough download size. Real sizes depend on the PC and on what is already installed.</summary>
    public required string Size { get; init; }
    /// <summary>winget package ids.</summary>
    public string[] Packages { get; init; } = [];
    public Extra[] ExtraSteps { get; init; } = [];
    public required Func<ToolLocator, bool> Installed { get; init; }

    public bool IsInstalled(ToolLocator tools) => Installed(tools);

    public static string FontEnvironment => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".venvs", "converter");

    public static string FontEnvironmentPython => ToolLocator.IsWindows
        ? Path.Combine(FontEnvironment, "Scripts", "python.exe")
        : Path.Combine(FontEnvironment, "bin", "python");

    public static readonly IReadOnlyList<ToolFeature> All =
    [
        new() { Id = "video", Title = "Video, audio and subtitles", Size = "About 100 MB", Packages = ["Gyan.FFmpeg"],
                Detail = "Video formats (MP4, MKV, WebM, WMV, FLV, 3GP), MP3, FLAC and other audio, subtitles and GIF.",
                Installed = t => t.Locate("ffmpeg") is not null },
        new() { Id = "office", Title = "Office documents and spreadsheets", Size = "About 350 MB", Packages = ["TheDocumentFoundation.LibreOffice"],
                Detail = "PDF from Word and slides, XLSX, ODS, CSV, PowerPoint and OpenDocument files, and PDF to Word.",
                Installed = t => t.Locate("soffice") is not null },
        new() { Id = "markdown", Title = "Markdown, HTML and EPUB", Size = "About 150 MB", Packages = ["JohnMacFarlane.Pandoc"],
                Detail = "Markdown, EPUB and the text formats, and Jupyter notebooks.",
                Installed = t => t.Locate("pandoc") is not null },
        new() { Id = "ebooks", Title = "E-books", Size = "About 250 MB", Packages = ["calibre.calibre"],
                Detail = "MOBI, AZW3 and FB2 e-books.",
                Installed = t => t.Locate("ebook-convert") is not null },
        new() { Id = "postscript", Title = "PDF compression and PostScript", Size = "About 60 MB", Packages = ["ArtifexSoftware.GhostScript"],
                Detail = "Smaller PDF files, and PostScript and EPS to PDF, PNG and JPEG.",
                Installed = t => ToolLocator.GhostscriptPath(t) is not null },
        new() { Id = "sevenzip", Title = "7-Zip archives", Size = "About 2 MB", Packages = ["7zip.7zip"],
                Detail = "Saving files as 7z archives. Reading 7z and RAR needs nothing to install.",
                Installed = t => t.Locate("7zz", "7z") is not null },
        new() { Id = "fonts", Title = "Fonts", Size = "About 100 MB", Packages = ["Python.Python.3.12"], ExtraSteps = [Extra.FontEnvironment],
                Detail = "TTF, OTF, WOFF and WOFF2.",
                Installed = _ => File.Exists(FontEnvironmentPython) },
        new() { Id = "code", Title = "Code translation", Size = "1 to 9 GB, depending on the model", Packages = ["Ollama.Ollama"], ExtraSteps = [Extra.CodeModel],
                Detail = "Translates code between languages with a model that runs on this PC. Choose the model in Settings.",
                Installed = t => t.Locate("ollama") is not null && CodeModels.IsInstalled(CodeModels.Selected) },
        new() { Id = "codeChecks", Title = "Code checks", Size = "About 1 GB", Packages = ["OpenJS.NodeJS.LTS", "GoLang.Go", "Python.Python.3.12", "Microsoft.OpenJDK.21"],
                ExtraSteps = [Extra.TypeScript],
                Detail = "Checks translated code with the Python, Java, Node.js, Go and TypeScript tools.",
                Installed = t => t.Locate("node") is not null && t.Locate("gofmt") is not null && t.Locate("javac") is not null && t.Locate("tsc") is not null },
    ];
}

/// <summary>Installs a feature with winget, then runs any extra steps it needs.
///
/// Several features can be installed at the same time. Windows runs one installer at a time, so the winget steps take
/// turns. Everything else (the font tools, the model download, the TypeScript install) only uses the network, so it runs
/// while other tools install.</summary>
public static class ToolInstaller
{
    // winget reports these when there is nothing to do, which is a success for this purpose.
    private static readonly HashSet<int> AlreadyDone = [unchecked((int)0x8A15002B), unchecked((int)0x8A150061), unchecked((int)0x8A15010D)];

    public static async Task<List<string>> InstallAsync(ToolFeature feature, ToolLocator tools, string codeModel,
                                                        Action<string> progress, CancellationToken cancellation = default,
                                                        InstallCoordinator? coordinator = null)
    {
        coordinator ??= InstallCoordinator.Shared;
        var log = new SafeLog();
        if (feature.Packages.Length > 0)
        {
            var winget = tools.Locate("winget") ?? throw ConversionException.ToolNotFound(
                "winget, the Windows package manager. Install \"App Installer\" from the Microsoft Store, then try again");
            foreach (var package in feature.Packages)
            {
                // winget works out and downloads the package itself, so the whole step takes its turn. Skipping the Microsoft
                // Store as a source saves a search that every install would otherwise make.
                await InstallCoordinator.WithSlotAsync(coordinator.Installs, async () =>
                {
                    progress($"Installing {package}…");
                    await RunAsync(winget, ["install", "--id", package, "-e", "--source", "winget", "--silent", "--disable-interactivity",
                                            "--accept-package-agreements", "--accept-source-agreements"],
                                   "winget", log, cancellation, allowed: AlreadyDone,
                                   onOutput: line => { if (WingetProgress.Describe(line) is { } step) progress(step); });
                }, onWait: () => progress("Waiting for another install to finish…"), cancellation);
            }
        }
        foreach (var extra in feature.ExtraSteps)
        {
            cancellation.ThrowIfCancellationRequested();
            switch (extra)
            {
                case ToolFeature.Extra.FontEnvironment:
                    progress("Setting up the font tools…");
                    await InstallCoordinator.WithSlotAsync(coordinator.Downloads, () => SetUpFontsAsync(tools, log, cancellation), cancellation: cancellation);
                    break;
                case ToolFeature.Extra.CodeModel:
                    progress("Downloading the code model. This can take a while…");
                    await PullModelAsync(codeModel, tools, log.Lines, cancellation, coordinator);
                    break;
                case ToolFeature.Extra.TypeScript:
                    progress("Installing TypeScript…");
                    var npm = tools.Locate("npm") ?? throw ConversionException.ToolNotFound("npm, which comes with Node.js");
                    await InstallCoordinator.WithSlotAsync(coordinator.Downloads,
                        () => RunAsync(npm, ["install", "-g", "typescript"], "npm", log, cancellation), cancellation: cancellation);
                    break;
            }
        }
        return log.Lines;
    }

    /// <summary>Downloads one code model through Ollama. The model list in Settings uses this. It takes one of the download
    /// slots, so it runs next to installs and other downloads.</summary>
    public static async Task<List<string>> PullModelAsync(string name, ToolLocator tools, List<string>? log = null,
                                                          CancellationToken cancellation = default, InstallCoordinator? coordinator = null)
    {
        coordinator ??= InstallCoordinator.Shared;
        var lines = new SafeLog();
        var ollama = tools.Locate("ollama") ?? throw ConversionException.ToolNotFound("Ollama");
        if (!await new OllamaClient(model: name).EnsureRunningAsync(tools, cancellation: cancellation))
            throw ConversionException.OllamaUnavailable("Could not start Ollama. Open the Ollama app, then try again.");
        await InstallCoordinator.WithSlotAsync(coordinator.Downloads, () => RunAsync(ollama, ["pull", name], "Ollama", lines, cancellation), cancellation: cancellation);
        log?.AddRange(lines.Lines);
        return lines.Lines;
    }

    private static async Task SetUpFontsAsync(ToolLocator tools, SafeLog log, CancellationToken cancellation)
    {
        var python = tools.Locate("python3.12", "python3", "python") ?? throw ConversionException.ToolNotFound("Python 3.12");
        if (!File.Exists(ToolFeature.FontEnvironmentPython))
            await RunAsync(python, ["-m", "venv", ToolFeature.FontEnvironment], "Python", log, cancellation);
        await RunAsync(ToolFeature.FontEnvironmentPython, ["-m", "pip", "install", "fonttools", "brotli"], "pip", log, cancellation);
    }

    private static async Task RunAsync(string executable, string[] arguments, string name, SafeLog log,
                                       CancellationToken cancellation, HashSet<int>? allowed = null, Action<string>? onOutput = null)
    {
        log.Add($"{name}: {Path.GetFileName(executable)} {string.Join(' ', arguments)}");
        var result = await ProcessRunner.RunAsync(executable, arguments, cancellation: cancellation, onOutput: onOutput);
        if (result.ExitCode != 0 && allowed?.Contains(result.ExitCode) != true)
            throw ConversionException.ToolFailed(name, result.ExitCode, Converter.LastLines(result.StdErr + result.StdOut));
    }

    /// <summary>The lines an install writes to its log. Several installs run at once, so adding a line is thread safe.</summary>
    private sealed class SafeLog
    {
        private readonly List<string> _lines = [];
        public void Add(string line) { lock (_lines) _lines.Add(line); }
        public List<string> Lines { get { lock (_lines) return _lines.ToList(); } }
    }
}
