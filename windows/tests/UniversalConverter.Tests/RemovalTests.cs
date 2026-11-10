using UniversalConverter.App.ViewModels;
using UniversalConverter.Core;
using Xunit;

namespace UniversalConverter.Tests;

public class RemovalTests
{
    private static ToolFeature Feature(string id, string[]? packages = null, ToolFeature.Extra[]? extras = null, bool installed = true) => new()
    {
        Id = id, Title = id, Detail = "", Size = "", Packages = packages ?? [], ExtraSteps = extras ?? [], Installed = _ => installed,
    };

    [SkippableFact]
    public void OnlyWhatWingetListsIsPlannedForRemoval()
    {
        var plan = ToolRemoval.Plan(Feature("v", ["Gyan.FFmpeg", "Other.Thing"]), new HashSet<string> { "Gyan.FFmpeg", "Unrelated.App" }, [], false, false);
        Assert.Equal(["Gyan.FFmpeg"], plan.Packages);
        Assert.Equal(["Other.Thing"], plan.InstalledElsewhere);
        Assert.False(plan.IsEmpty);
        Assert.True(ToolRemoval.Plan(Feature("v", ["Gyan.FFmpeg"]), new HashSet<string>(), [], false, false).IsEmpty);
    }

    [SkippableFact]
    public void ModelsFontToolsAndTypeScriptBelongOnlyToTheGroupsThatOwnThem()
    {
        var code = ToolRemoval.Plan(Feature("code", ["Ollama.Ollama"], [ToolFeature.Extra.CodeModel]), new HashSet<string> { "Ollama.Ollama" }, ["qwen2.5-coder:7b"], true, true);
        Assert.Equal(["qwen2.5-coder:7b"], code.Models);
        Assert.False(code.FontEnvironment);
        Assert.False(code.TypeScript);
        var fonts = ToolRemoval.Plan(Feature("fonts", ["Python.Python.3.12"], [ToolFeature.Extra.FontEnvironment]), new HashSet<string> { "Python.Python.3.12" }, ["m"], true, true);
        Assert.True(fonts.FontEnvironment);
        Assert.Empty(fonts.Models);
        Assert.True(ToolRemoval.Plan(Feature("fonts", [], [ToolFeature.Extra.FontEnvironment]), new HashSet<string>(), [], false, false).IsEmpty);
    }

    [SkippableFact]
    public void TheConfirmationListsWhatGoesAndWarnsAboutSharedTools()
    {
        var plan = ToolRemoval.Plan(Feature("checks", ["OpenJS.NodeJS.LTS", "GoLang.Go"], [ToolFeature.Extra.TypeScript]), new HashSet<string> { "OpenJS.NodeJS.LTS" }, [], false, true);
        var text = plan.Confirmation;
        Assert.Contains("Programs: OpenJS.NodeJS.LTS", text);
        Assert.Contains("TypeScript", text);
        Assert.Contains("general programming tools", text);
        Assert.Contains("Not removed, because winget does not list them: GoLang.Go", text);
        Assert.DoesNotContain("general programming tools", ToolRemoval.Plan(Feature("v", ["Gyan.FFmpeg"]), new HashSet<string> { "Gyan.FFmpeg" }, [], false, false).Confirmation);
    }

    private static (SettingsViewModel Settings, ToolRowViewModel Row) Installed(string id = "t")
    {
        var settings = new SettingsViewModel(new MainViewModel());
        var row = new ToolRowViewModel(settings, Feature(id, ["Some.Package"]));
        settings.ToolRows.Add(row);
        return (settings, row);
    }

    [SkippableFact]
    public async Task NothingIsRemovedUntilTheUserConfirms()
    {
        var (settings, row) = Installed();
        bool removed = false, asked = false;
        settings.PlanOverride = f => Task.FromResult(new RemovalPlan { Packages = ["Some.Package"] });
        settings.UninstallOverride = (_, _, _) => { removed = true; return Task.CompletedTask; };
        // No way to ask: nothing happens.
        await settings.RemoveAsync(row);
        Assert.False(removed);
        // The user says no.
        settings.Confirm = (title, text) => { asked = true; return Task.FromResult(false); };
        await settings.RemoveAsync(row);
        Assert.True(asked);
        Assert.False(removed);
        Assert.False(row.IsWorking);
        // The user says yes.
        settings.Confirm = (title, text) => { Assert.Contains("Remove t?", title); Assert.Contains("Some.Package", text); return Task.FromResult(true); };
        await settings.RemoveAsync(row);
        Assert.True(removed);
        Assert.Contains("t was removed.", settings.Message);
        Assert.False(row.IsWorking);
    }

    [SkippableFact]
    public async Task AToolThatWingetDidNotInstallIsExplainedAndNotTouched()
    {
        var (settings, row) = Installed();
        bool removed = false;
        settings.PlanOverride = _ => Task.FromResult(new RemovalPlan());
        settings.UninstallOverride = (_, _, _) => { removed = true; return Task.CompletedTask; };
        settings.Confirm = (_, _) => Task.FromResult(true);
        await settings.RemoveAsync(row);
        Assert.False(removed);
        Assert.Contains("not installed by winget", settings.Message);
    }

    [SkippableFact]
    public async Task AFailedRemovalIsReportedAndTheRowIsFreeAgain()
    {
        var (settings, row) = Installed();
        settings.PlanOverride = _ => Task.FromResult(new RemovalPlan { Packages = ["Some.Package"] });
        settings.UninstallOverride = (_, _, _) => throw ConversionException.Unsupported("winget failed with exit code 1.");
        settings.Confirm = (_, _) => Task.FromResult(true);
        await settings.RemoveAsync(row);
        Assert.Contains("winget failed", settings.Message);
        Assert.False(row.IsWorking);
        Assert.True(row.CanRemove);
    }

    [SkippableFact]
    public async Task ARowThatIsBusyCannotBeRemovedTwice()
    {
        var (settings, row) = Installed();
        int runs = 0;
        var release = new TaskCompletionSource();
        settings.PlanOverride = _ => Task.FromResult(new RemovalPlan { Packages = ["Some.Package"] });
        settings.UninstallOverride = async (_, _, _) => { Interlocked.Increment(ref runs); await release.Task; };
        settings.Confirm = (_, _) => Task.FromResult(true);
        var first = settings.RemoveAsync(row);
        await Task.Delay(60);
        Assert.True(row.IsWorking);
        Assert.False(row.CanRemove);
        await settings.RemoveAsync(row);
        release.SetResult();
        await first;
        Assert.Equal(1, runs);
    }

    [SkippableFact]
    public async Task ADownloadedModelIsRemovedAfterConfirmation()
    {
        var settings = new SettingsViewModel(new MainViewModel());
        var folder = Path.Combine(Path.GetTempPath(), "uc-models-" + Guid.NewGuid().ToString("N"));
        var previous = Environment.GetEnvironmentVariable("OLLAMA_MODELS");
        Environment.SetEnvironmentVariable("OLLAMA_MODELS", folder);
        try
        {
            var model = new CodeModel("test-model:1b", "Test model", "", "About 1 GB", 4);
            var manifest = CodeModels.ManifestPath(model.Name);
            Directory.CreateDirectory(Path.GetDirectoryName(manifest)!);
            File.WriteAllText(manifest, "{}");
            var row = new ModelRowViewModel(settings, model);
            settings.ModelRows.Add(row);
            Assert.True(row.IsInstalled);
            string? removedName = null;
            settings.RemoveModelOverride = name => { removedName = name; File.Delete(manifest); return Task.CompletedTask; };
            settings.Confirm = (_, _) => Task.FromResult(false);
            await settings.RemoveModelAsync(row);
            Assert.Null(removedName);
            settings.Confirm = (_, text) => { Assert.Contains("About 1 GB", text); return Task.FromResult(true); };
            await settings.RemoveModelAsync(row);
            Assert.Equal("test-model:1b", removedName);
            Assert.Contains("Test model was removed.", settings.Message);
            Assert.False(row.IsInstalled, "the row notices the model is gone");
        }
        finally
        {
            Environment.SetEnvironmentVariable("OLLAMA_MODELS", previous);
            try { Directory.Delete(folder, true); } catch { }
        }
    }

    [SkippableFact]
    public async Task AnEmptyPlanRemovesNothingAndNeedsNoTools()
    {
        var lines = await ToolRemoval.UninstallAsync(Feature("none"), new ToolLocator(), new RemovalPlan(), _ => { });
        Assert.Empty(lines);
    }

    [SkippableFact]
    public async Task RemovingWaitsForAnInstallInProgress()
    {
        // winget removes one program at a time, like it installs one at a time, so the removal takes the same turn.
        var coordinator = new InstallCoordinator();
        await coordinator.Installs.WaitAsync();
        var told = new List<string>();
        var plan = new RemovalPlan { Packages = ["Some.Package"] };
        // The wait message is raised before winget is even looked for, so a PC without winget still shows it.
        var removing = Task.Run(async () =>
        {
            try { await ToolRemoval.UninstallAsync(Feature("x"), new ToolLocator(), plan, s => { lock (told) told.Add(s); }, coordinator: coordinator); }
            catch (ConversionException) { /* winget is not here */ }
        });
        await Task.Delay(100);
        coordinator.Installs.Release();
        await removing;
    }
}
