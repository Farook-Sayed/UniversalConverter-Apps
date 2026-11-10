namespace UniversalConverter.Core;

/// <summary>What removing a tool group would take away. It is worked out before anything is deleted, so the user can see it first.</summary>
public sealed record RemovalPlan
{
    /// <summary>winget packages of this group that are installed.</summary>
    public IReadOnlyList<string> Packages { get; init; } = [];
    /// <summary>Code models that are downloaded, as Ollama names them.</summary>
    public IReadOnlyList<string> Models { get; init; } = [];
    public bool FontEnvironment { get; init; }
    public bool TypeScript { get; init; }
    /// <summary>Packages of this group that winget does not list. The app leaves them alone.</summary>
    public IReadOnlyList<string> InstalledElsewhere { get; init; } = [];

    public bool IsEmpty => Packages.Count == 0 && Models.Count == 0 && !FontEnvironment && !TypeScript;

    /// <summary>Programming languages and tools that other software on this PC may also use.</summary>
    public static readonly IReadOnlySet<string> GeneralTools = new HashSet<string>
    {
        "Python.Python.3.12", "OpenJS.NodeJS.LTS", "GoLang.Go", "Microsoft.OpenJDK.21",
    };

    public bool TouchesGeneralTools => Packages.Any(GeneralTools.Contains);

    public IReadOnlyList<string> Items
    {
        get
        {
            var lines = new List<string>();
            if (Packages.Count > 0) lines.Add("Programs: " + string.Join(", ", Packages));
            if (Models.Count > 0) lines.Add("Downloaded models: " + string.Join(", ", Models));
            if (FontEnvironment) lines.Add("The font tools environment");
            if (TypeScript) lines.Add("TypeScript");
            return lines;
        }
    }

    public string Confirmation
    {
        get
        {
            var text = "This removes:\n" + string.Join("\n", Items.Select(i => "• " + i));
            text += "\n\nIt also removes them for any other program that uses them, including ones you installed yourself. You can install them again from here.";
            if (TouchesGeneralTools) text += "\n\nPython, Node.js, Go and Java are general programming tools, so other software on this PC may need them.";
            if (InstalledElsewhere.Count > 0) text += "\n\nNot removed, because winget does not list them: " + string.Join(", ", InstalledElsewhere) + ".";
            return text;
        }
    }
}

public static class ToolRemoval
{
    // winget reports this when the package is already gone, which is the result the user wanted.
    private static readonly HashSet<int> AlreadyGone = [unchecked((int)0x8A150014), unchecked((int)0x8A150010)];

    /// <summary>Works out what removing a feature would take away. <paramref name="installedPackages"/> is what winget lists.</summary>
    public static RemovalPlan Plan(ToolFeature feature, ISet<string> installedPackages, IEnumerable<string> downloadedModels,
                                   bool fontEnvironmentExists, bool typeScriptInstalled) => new()
    {
        Packages = feature.Packages.Where(installedPackages.Contains).ToList(),
        InstalledElsewhere = feature.Packages.Where(p => !installedPackages.Contains(p)).ToList(),
        Models = feature.ExtraSteps.Contains(ToolFeature.Extra.CodeModel) ? downloadedModels.ToList() : [],
        FontEnvironment = feature.ExtraSteps.Contains(ToolFeature.Extra.FontEnvironment) && fontEnvironmentExists,
        TypeScript = feature.ExtraSteps.Contains(ToolFeature.Extra.TypeScript) && typeScriptInstalled,
    };

    /// <summary>The same, using what is installed on this PC now.</summary>
    public static async Task<RemovalPlan> PlanAsync(ToolFeature feature, ToolLocator tools, CancellationToken cancellation = default)
    {
        var installed = new HashSet<string>();
        if (tools.Locate("winget") is { } winget)
        {
            foreach (var package in feature.Packages)
            {
                var result = await ProcessRunner.RunAsync(winget, ["list", "--id", package, "-e", "--accept-source-agreements", "--disable-interactivity"], cancellation: cancellation);
                // winget prints a table with the id when the package is installed, and a message when it is not.
                if (result.ExitCode == 0 && result.StdOut.Contains(package, StringComparison.OrdinalIgnoreCase)) installed.Add(package);
            }
        }
        return Plan(feature, installed, CodeModels.Catalog.Where(m => m.IsInstalled).Select(m => m.Name),
                    File.Exists(ToolFeature.FontEnvironmentPython), tools.Locate("tsc") is not null);
    }

    /// <summary>Removes what the plan lists. Models go first, because Ollama is needed to remove them. The winget steps take their
    /// turn with installs, because Windows runs one installer or uninstaller at a time.</summary>
    public static async Task<List<string>> UninstallAsync(ToolFeature feature, ToolLocator tools, RemovalPlan plan, Action<string> progress,
                                                          CancellationToken cancellation = default, InstallCoordinator? coordinator = null)
    {
        coordinator ??= InstallCoordinator.Shared;
        var log = new List<string>();
        foreach (var model in plan.Models)
        {
            progress($"Removing {model}…");
            await RemoveModelAsync(model, tools, log, cancellation);
        }
        if (plan.TypeScript && tools.Locate("npm") is { } npm)
        {
            progress("Removing TypeScript…");
            await RunAsync(npm, ["uninstall", "-g", "typescript"], "npm", log, cancellation);
        }
        if (plan.FontEnvironment)
        {
            progress("Removing the font tools…");
            log.Add($"removed {ToolFeature.FontEnvironment}");
            Directory.Delete(ToolFeature.FontEnvironment, true);
        }
        if (plan.Packages.Count > 0)
        {
            var winget = tools.Locate("winget") ?? throw ConversionException.ToolNotFound("winget, which is needed to remove what it installed");
            foreach (var package in plan.Packages)
            {
                await InstallCoordinator.WithSlotAsync(coordinator.Installs, async () =>
                {
                    progress($"Removing {package}…");
                    await RunAsync(winget, ["uninstall", "--id", package, "-e", "--silent", "--disable-interactivity", "--accept-source-agreements"],
                                   "winget", log, cancellation, allowed: AlreadyGone);
                }, onWait: () => progress("Waiting for another install to finish…"), cancellation);
            }
        }
        return log;
    }

    /// <summary>Deletes one downloaded code model through Ollama.</summary>
    public static async Task<List<string>> RemoveModelAsync(string name, ToolLocator tools, List<string>? log = null, CancellationToken cancellation = default)
    {
        log ??= [];
        var ollama = tools.Locate("ollama") ?? throw ConversionException.ToolNotFound("Ollama");
        if (!await new OllamaClient(model: name).EnsureRunningAsync(tools, cancellation: cancellation))
            throw ConversionException.OllamaUnavailable($"Could not start Ollama, which is needed to remove {name}. Open the Ollama app, then try again.");
        await RunAsync(ollama, ["rm", name], "Ollama", log, cancellation);
        return log;
    }

    private static async Task RunAsync(string executable, string[] arguments, string name, List<string> log, CancellationToken cancellation, HashSet<int>? allowed = null)
    {
        log.Add($"{name}: {Path.GetFileName(executable)} {string.Join(' ', arguments)}");
        var result = await ProcessRunner.RunAsync(executable, arguments, cancellation: cancellation);
        if (result.ExitCode != 0 && allowed?.Contains(result.ExitCode) != true)
            throw ConversionException.ToolFailed(name, result.ExitCode, Converter.LastLines(result.StdErr + result.StdOut));
    }
}
