using UniversalConverter.App.ViewModels;
using UniversalConverter.Core;
using Xunit;

namespace UniversalConverter.Tests;

public class ResourceTests
{
    [SkippableFact]
    public void WorkIsSizedToTheProcessorCores()
    {
        Assert.Equal(2, ResourcePlan.ParallelConversions(2));
        Assert.Equal(2, ResourcePlan.ParallelConversions(8));
        Assert.Equal(3, ResourcePlan.ParallelConversions(10));
        Assert.Equal(4, ResourcePlan.ParallelConversions(16));
        Assert.Equal(4, ResourcePlan.ParallelConversions(64));
        Assert.Equal(4, ResourcePlan.ThreadsPerConversion(8, 2));
        Assert.Equal(4, ResourcePlan.ThreadsPerConversion(16, 4));
        Assert.Equal(2, ResourcePlan.ThreadsPerConversion(2, 4));
        Assert.True(ResourcePlan.ParallelConversions() >= 2);
    }

    /// <summary>Six installs: every one downloads at the same time (up to four at once), and no two install together.</summary>
    [SkippableFact]
    public async Task DownloadsOverlapButInstallsTakeTurns()
    {
        var coordinator = new InstallCoordinator();
        int downloadsNow = 0, downloadsPeak = 0, installsNow = 0, installsPeak = 0;
        var gate = new object();
        void Enter(ref int now, ref int peak) { lock (gate) { now++; peak = Math.Max(peak, now); } }
        void Leave(ref int now) { lock (gate) now--; }
        var started = DateTime.UtcNow;
        await Task.WhenAll(Enumerable.Range(0, 6).Select(async _ =>
        {
            await InstallCoordinator.WithSlotAsync(coordinator.Downloads, async () =>
            {
                lock (gate) { downloadsNow++; downloadsPeak = Math.Max(downloadsPeak, downloadsNow); }
                await Task.Delay(150);
                lock (gate) downloadsNow--;
            });
            await InstallCoordinator.WithSlotAsync(coordinator.Installs, async () =>
            {
                lock (gate) { installsNow++; installsPeak = Math.Max(installsPeak, installsNow); }
                await Task.Delay(30);
                lock (gate) installsNow--;
            });
        }));
        Assert.Equal(ResourcePlan.ParallelDownloads, downloadsPeak);
        Assert.Equal(1, installsPeak);
        Assert.True(DateTime.UtcNow - started < TimeSpan.FromMilliseconds(900), "overlapping the downloads is faster than one after another");
    }

    [SkippableFact]
    public async Task ACallerIsToldWhileItWaitsForAnotherInstall()
    {
        var gate = new SemaphoreSlim(1);
        await gate.WaitAsync();
        int told = 0;
        var waiting = InstallCoordinator.WithSlotAsync(gate, () => Task.CompletedTask, onWait: () => Interlocked.Increment(ref told));
        await Task.Delay(100);
        Assert.Equal(1, told);
        Assert.False(waiting.IsCompleted);
        gate.Release();
        await waiting;
    }

    [SkippableFact]
    public async Task ACancelledWaitStopsWaitingAndLeaksNoSlot()
    {
        var gate = new SemaphoreSlim(1);
        await gate.WaitAsync();
        using var cancel = new CancellationTokenSource();
        var waiting = InstallCoordinator.WithSlotAsync(gate, () => Task.CompletedTask, cancellation: cancel.Token);
        await Task.Delay(50);
        cancel.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => waiting);
        gate.Release();
        await InstallCoordinator.WithSlotAsync(gate, () => Task.CompletedTask);
    }

    [SkippableFact]
    public async Task ASlotIsGivenBackWhenTheWorkFails()
    {
        var gate = new SemaphoreSlim(1);
        await Assert.ThrowsAsync<InvalidOperationException>(() => InstallCoordinator.WithSlotAsync(gate, () => throw new InvalidOperationException()));
        Assert.Equal(1, gate.CurrentCount);
    }

    [SkippableTheory]
    [InlineData("  ██████████▒▒▒▒▒▒▒▒▒▒  14.0 MB / 28.0 MB", "Downloading", 0.5)]
    [InlineData("  ██████████████████████  512 KB / 512 KB", "Downloading", 1.0)]
    [InlineData("Downloading https://example.com/setup.exe", "Downloading", null)]
    [InlineData("Starting package install...", "Installing", null)]
    [InlineData("Successfully installed", "Finishing", null)]
    public void WingetOutputBecomesAStepAndAShare(string line, string step, double? fraction)
    {
        var (s, f) = WingetProgress.Parse(line);
        Assert.Equal(step, s);
        if (fraction is null) Assert.Null(f); else Assert.Equal(fraction.Value, f!.Value, 3);
    }

    [SkippableFact]
    public void WingetNoiseIsIgnoredAndAShareIsShownAsAPercentage()
    {
        Assert.Null(WingetProgress.Parse("").Step);
        Assert.Null(WingetProgress.Parse("Found Ollama [Ollama.Ollama] Version 0.30.0").Step);
        Assert.Equal("Downloading… 50%", WingetProgress.Describe("  ███▒▒▒  1.0 MB / 2.0 MB"));
        Assert.Equal("Installing…", WingetProgress.Describe("Starting package install..."));
    }

    [SkippableFact]
    public void FFmpegGetsItsShareOfTheCoresAndNotMoreThanItsOptionsSay()
    {
        Assert.DoesNotContain("-threads", Converter.FfmpegOptions("mp4"));
    }

    [SkippableFact]
    public async Task SeveralToolsCanBeInstalledAtTheSameTime()
    {
        var main = new MainViewModel();
        var settings = new SettingsViewModel(main);
        int now = 0, peak = 0;
        settings.InstallOverride = async (feature, step, _) =>
        {
            lock (settings) { now++; peak = Math.Max(peak, now); }
            step("Downloading… 10%");
            await Task.Delay(150);
            lock (settings) now--;
        };
        var rows = settings.ToolRows.Where(r => r.CanInstall).Take(3).ToList();
        if (rows.Count < 3) throw new SkipException("Fewer than three tools are missing on this PC");
        var all = rows.Select(settings.InstallAsync).ToList();
        await Task.Delay(60);
        Assert.All(rows, r => Assert.True(r.IsWorking, "every row shows its own install at the same time"));
        Assert.True(settings.AnyInstalling);
        Assert.All(rows, r => Assert.False(r.CanInstall, "a row that is installing cannot be started twice"));
        await Task.WhenAll(all);
        Assert.Equal(3, peak);
        Assert.All(rows, r => Assert.False(r.IsWorking));
        Assert.Equal(3, settings.Message.Split((char)10).Length);
        Assert.False(settings.AnyInstalling);
    }

    [SkippableFact]
    public async Task InstallEverythingStartsAllMissingToolsTogether()
    {
        var main = new MainViewModel();
        var settings = new SettingsViewModel(main);
        int now = 0, peak = 0;
        settings.InstallOverride = async (_, _, _) =>
        {
            lock (settings) { now++; peak = Math.Max(peak, now); }
            await Task.Delay(120);
            lock (settings) now--;
        };
        int missing = settings.ToolRows.Count(r => r.CanInstall);
        if (missing < 2) throw new SkipException("Fewer than two tools are missing on this PC");
        Assert.True(settings.CanInstallAll);
        await settings.InstallAllCommand.ExecuteAsync(null);
        Assert.Equal(missing, peak);
    }

    [SkippableFact]
    public async Task AFailedInstallDoesNotStopTheOthers()
    {
        var main = new MainViewModel();
        var settings = new SettingsViewModel(main);
        var rows = settings.ToolRows.Where(r => r.CanInstall).Take(2).ToList();
        if (rows.Count < 2) throw new SkipException("Fewer than two tools are missing on this PC");
        settings.InstallOverride = async (feature, _, _) =>
        {
            await Task.Delay(50);
            if (feature.Id == rows[0].Feature.Id) throw ConversionException.Unsupported("The download failed.");
        };
        await Task.WhenAll(rows.Select(settings.InstallAsync));
        Assert.Contains("The download failed.", settings.Message);
        Assert.Contains($"{rows[1].Title} is installed.", settings.Message);
        Assert.All(rows, r => Assert.False(r.IsWorking));
    }
}
