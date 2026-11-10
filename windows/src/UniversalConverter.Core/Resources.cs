using System.Text.RegularExpressions;

namespace UniversalConverter.Core;

/// <summary>How much this PC's hardware is used. The numbers follow the processor cores, so a small PC is not overloaded and
/// a big one is not left idle.</summary>
public static class ResourcePlan
{
    /// <summary>Downloads that run side by side. A download waits on the network, not on the processor, so a few at once keep
    /// a fast connection busy. More than this only makes each one slower.</summary>
    public const int ParallelDownloads = 4;

    /// <summary>Conversions that run side by side: one for every three cores, between two and four. Two always run, so one can
    /// read or write files while the other uses the processor.</summary>
    public static int ParallelConversions(int? cores = null) => Math.Max(2, Math.Min(4, (cores ?? Environment.ProcessorCount) / 3));

    /// <summary>The processor threads each conversion may use, so that the conversions running together share the cores instead
    /// of all asking for every one of them.</summary>
    public static int ThreadsPerConversion(int? cores = null, int? parallel = null)
    {
        int c = cores ?? Environment.ProcessorCount;
        return Math.Max(2, c / Math.Max(parallel ?? ParallelConversions(c), 1));
    }

    /// <summary>Limits the picture library to this conversion's share of the cores. Call it once, at start-up.</summary>
    public static void ApplyPictureThreads() => ImageMagick.ResourceLimits.Thread = (ulong)ThreadsPerConversion();
}

/// <summary>Decides what may run at the same time while tools are installed. Downloads and extra steps only use the network, so
/// several run together. Windows runs only one installer at a time for the whole PC (a second one fails with "another
/// installation is in progress"), so the installs take turns.</summary>
public sealed class InstallCoordinator
{
    public static InstallCoordinator Shared { get; } = new();

    public SemaphoreSlim Downloads { get; } = new(ResourcePlan.ParallelDownloads);
    public SemaphoreSlim Installs { get; } = new(1);

    /// <summary>Runs <paramref name="body"/> while holding one slot. <paramref name="onWait"/> is called first when none is free.</summary>
    public static async Task<T> WithSlotAsync<T>(SemaphoreSlim gate, Func<Task<T>> body, Action? onWait = null, CancellationToken cancellation = default)
    {
        if (gate.CurrentCount == 0) onWait?.Invoke();
        await gate.WaitAsync(cancellation);
        try { return await body(); }
        finally { gate.Release(); }
    }

    public static Task WithSlotAsync(SemaphoreSlim gate, Func<Task> body, Action? onWait = null, CancellationToken cancellation = default) =>
        WithSlotAsync<bool>(gate, async () => { await body(); return true; }, onWait, cancellation);
}

/// <summary>Reads what winget prints while it works, as a short step and a share between 0 and 1 when it can be told.</summary>
public static partial class WingetProgress
{
    // winget draws a bar and then the sizes: "  ████▒▒▒▒  14.0 MB / 31.0 MB".
    [GeneratedRegex(@"(?<done>\d+(?:\.\d+)?)\s*(?<doneUnit>KB|MB|GB)\s*/\s*(?<total>\d+(?:\.\d+)?)\s*(?<totalUnit>KB|MB|GB)", RegexOptions.IgnoreCase)]
    private static partial Regex Sizes();

    private static double Bytes(string number, string unit) =>
        double.Parse(number, System.Globalization.CultureInfo.InvariantCulture) * unit.ToUpperInvariant() switch { "KB" => 1e3, "MB" => 1e6, _ => 1e9 };

    public static (string? Step, double? Fraction) Parse(string line)
    {
        var text = line.Trim();
        if (text.Length == 0) return (null, null);
        if (Sizes().Match(text) is { Success: true } m)
        {
            double total = Bytes(m.Groups["total"].Value, m.Groups["totalUnit"].Value);
            double done = Bytes(m.Groups["done"].Value, m.Groups["doneUnit"].Value);
            return ("Downloading", total > 0 ? Math.Clamp(done / total, 0, 1) : null);
        }
        if (text.StartsWith("Downloading", StringComparison.OrdinalIgnoreCase)) return ("Downloading", null);
        if (text.Contains("Starting package install", StringComparison.OrdinalIgnoreCase) || text.StartsWith("Installing", StringComparison.OrdinalIgnoreCase)) return ("Installing", null);
        if (text.StartsWith("Successfully installed", StringComparison.OrdinalIgnoreCase)) return ("Finishing", null);
        return (null, null);
    }

    /// <summary>The step as shown in a row, such as "Downloading… 45%".</summary>
    public static string? Describe(string line)
    {
        var (step, fraction) = Parse(line);
        if (step is null) return null;
        return fraction is double f ? $"{step}… {f:P0}" : step + "…";
    }
}
