using System.Diagnostics;
using System.Text;

namespace UniversalConverter.Core;

public sealed record ProcessOutput(int ExitCode, string StdOut, string StdErr);

/// <summary>Runs a program and collects its output. Cancelling stops the program and everything it started.</summary>
public static class ProcessRunner
{
    public static readonly TimeSpan DefaultTimeout = TimeSpan.FromMinutes(60);

    public static async Task<ProcessOutput> RunAsync(
        string executable, IEnumerable<string> arguments,
        IDictionary<string, string>? environment = null, string? workingDirectory = null,
        TimeSpan? timeout = null, Action<string>? onOutput = null, CancellationToken cancellation = default)
    {
        cancellation.ThrowIfCancellationRequested();
        var info = new ProcessStartInfo(executable)
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            RedirectStandardInput = true,
            UseShellExecute = false,
            CreateNoWindow = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
        };
        foreach (var argument in arguments) info.ArgumentList.Add(argument);
        if (workingDirectory is not null) info.WorkingDirectory = workingDirectory;
        // A program started from a window with no console would otherwise inherit a search path without the tools.
        info.Environment["PATH"] = ToolLocator.SearchPath();
        if (environment is not null) foreach (var pair in environment) info.Environment[pair.Key] = pair.Value;

        var output = new StringBuilder();
        var errors = new StringBuilder();
        using var process = new Process { StartInfo = info };
        process.OutputDataReceived += (_, e) =>
        {
            if (e.Data is null) return;
            lock (output) output.AppendLine(e.Data);
            onOutput?.Invoke(e.Data);
        };
        process.ErrorDataReceived += (_, e) => { if (e.Data is not null) lock (errors) errors.AppendLine(e.Data); };

        try { process.Start(); }
        catch (Exception ex) when (ex is System.ComponentModel.Win32Exception or InvalidOperationException)
        {
            throw ConversionException.Unsupported($"{Path.GetFileName(executable)} could not be started: {ex.Message}");
        }
        // The program never waits for input.
        try { process.StandardInput.Close(); } catch { /* already closed */ }
        process.BeginOutputReadLine();
        process.BeginErrorReadLine();

        using var limit = new CancellationTokenSource(timeout ?? DefaultTimeout);
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellation, limit.Token);
        try
        {
            await process.WaitForExitAsync(linked.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            Kill(process);
            if (cancellation.IsCancellationRequested) throw;
            throw ConversionException.TimedOut(Path.GetFileNameWithoutExtension(executable));
        }
        // The last lines can still be arriving. This waits for the end of both streams.
        process.WaitForExit();
        // A program that ended with an error just as the user cancelled was most likely stopped by the cancel, so the
        // result is a cancellation, not a failure of the program.
        if (cancellation.IsCancellationRequested && process.ExitCode != 0) throw new OperationCanceledException(cancellation);
        return new ProcessOutput(process.ExitCode, output.ToString(), errors.ToString());
    }

    private static void Kill(Process process)
    {
        try { if (!process.HasExited) process.Kill(entireProcessTree: true); } catch { /* it ended by itself */ }
    }
}
