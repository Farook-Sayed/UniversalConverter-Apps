using ImageMagick;
using ImageMagick.Drawing;
using UniversalConverter.Core;
using Xunit;

namespace UniversalConverter.Tests;

/// <summary>Finds the sample files that scripts/make-test-files.sh makes, and builds small inputs in code.</summary>
public static class Samples
{
    public static string? Folder
    {
        get
        {
            if (Environment.GetEnvironmentVariable("UC_SAMPLES") is { Length: > 0 } custom && Directory.Exists(custom)) return custom;
            var dir = new DirectoryInfo(AppContext.BaseDirectory);
            while (dir is not null)
            {
                var candidate = Path.Combine(dir.FullName, "TestFiles");
                if (Directory.Exists(candidate)) return candidate;
                dir = dir.Parent;
            }
            return null;
        }
    }

    public static string Path_(string relative)
    {
        var folder = Folder ?? throw new SkipException("The sample files are missing. Run scripts/make-test-files.sh.");
        var path = Path.Combine(folder, relative);
        return File.Exists(path) ? path : throw new SkipException($"Sample {relative} is missing.");
    }

    /// <summary>A picture with a bright subject on a dark background, so cropping and background removal can be checked.</summary>
    public static string Picture(string folder, string name = "subject.png", int width = 400, int height = 300)
    {
        var path = Path.Combine(folder, name);
        using var image = new MagickImage(new MagickColor("#203040"), (uint)width, (uint)height);
        new Drawables().FillColor(MagickColors.OrangeRed).Circle(width / 2, height / 2, width / 2, height / 2 + height / 4).Draw(image);
        image.Write(path);
        return path;
    }
}


public sealed class TempFolder : IDisposable
{
    public string Path { get; } = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "uc-test-" + Guid.NewGuid().ToString("N"));
    public TempFolder() => Directory.CreateDirectory(Path);
    public void Dispose() { try { Directory.Delete(Path, true); } catch { } }
    public string File_(string name) => System.IO.Path.Combine(Path, name);
}

public sealed class ProgressLog
{
    private readonly List<ConversionProgress> _all = [];
    public void Add(ConversionProgress p) { lock (_all) _all.Add(p); }
    public List<ConversionProgress> All { get { lock (_all) return _all.ToList(); } }
}

public sealed class FakeOcr(string text) : IOcrEngine
{
    public int Calls;
    public Task<string> RecognizeAsync(byte[] png, CancellationToken cancellation) { Interlocked.Increment(ref Calls); return Task.FromResult(text); }
}
