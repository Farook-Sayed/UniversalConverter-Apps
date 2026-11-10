using System.Globalization;

namespace UniversalConverter.Core;

/// <summary>Which program or library does a conversion.</summary>
public enum Engine
{
    Ffmpeg, Image, Pdf, LibreOffice, Pandoc, Ollama, Archive, SevenZip, FontTools, Ghostscript, Assimp, Calibre, Ocr,
}

/// <summary>The broad family a file belongs to.</summary>
public enum MediaCategory
{
    Video, Audio, Image, Vector, Document, Spreadsheet, Presentation, Markup, Code, Archive, Subtitle, Font,
    Postscript, Model3D, Ebook, Unknown,
}

public enum DetectionMethod { MagicBytes, TextWithExtension, ExtensionOnly }

/// <summary>The result of looking at a file.</summary>
public sealed record DetectedFile(string Path, MediaCategory Category, string FormatId, string MimeType,
                                  DetectionMethod Method, bool ExtensionMismatch);

/// <summary>A format the user can convert a file into.</summary>
public sealed record OutputFormat(string Id, string Label, string FileExtension, Engine Engine);

/// <summary>A programming language that code translation can read or write.</summary>
public sealed record CodeLanguage(string Id, string Label, string[] Extensions);

public sealed record RouteStep(string InputFormatId, MediaCategory InputCategory, OutputFormat Output,
                               MediaCategory OutputCategory)
{
    /// <summary>PDF or PostScript pages saved as images. These can be several files, so this is only ever the last step.</summary>
    public bool ProducesPageImages =>
        (Output.Id is "png" or "jpg") && Output.Engine is Engine.Pdf or Engine.Ghostscript;
}

/// <summary>The way to reach a target format: one conversion, or several in a row.</summary>
public sealed class Route
{
    public IReadOnlyList<RouteStep> Steps { get; }

    public Route(IEnumerable<RouteStep> steps)
    {
        Steps = steps.ToList();
        if (Steps.Count == 0) throw new ArgumentException("A route has at least one step");
    }

    public OutputFormat Target => Steps[^1].Output;
    public string Id => Target.Id;
    public string FileExtension => Target.FileExtension;
    public Engine Engine => Target.Engine;
    public bool IsMultiStep => Steps.Count > 1;

    /// <summary>The name shown in menus. A multi-step route names the formats it passes through.</summary>
    public string Label => !IsMultiStep
        ? Target.Label
        : $"{Target.Label} (via {string.Join(" → ", Steps.Take(Steps.Count - 1).Select(s => s.Output.FileExtension.ToUpperInvariant()))})";

    public override string ToString() => Label;
}

/// <summary>What a conversion is doing now. Fraction is 0..1 when the work can be measured, and null when it cannot.</summary>
public sealed record ConversionProgress(string Message, double? Fraction = null)
{
    public double? Fraction { get; } = Fraction is null ? null : Math.Clamp(Fraction.Value, 0, 1);
}

public class ConversionException : Exception
{
    public ConversionException(string message) : base(message) { }

    public static ConversionException ToolNotFound(string tool) =>
        new($"{tool} is not installed. Install it from Tools in the app and try again.");

    public static ConversionException ToolFailed(string tool, int exitCode, string message) =>
        new($"{tool} failed with exit code {exitCode}." + (string.IsNullOrWhiteSpace(message) ? "" : "\n" + message));

    public static ConversionException TimedOut(string tool) => new($"{tool} took too long and was stopped.");

    public static ConversionException OutputMissing(string tool) =>
        new($"{tool} finished but did not produce an output file.");

    public static ConversionException Unsupported(string reason) => new(reason);

    public static ConversionException OllamaUnavailable(string reason) =>
        new($"The local code model is not available. {reason}");

    public static ConversionException InputTooLarge(long bytes, long limit) =>
        new($"This file is {bytes / 1024} KB. The code model accepts up to {limit / 1024} KB.");
}

/// <summary>Sizes such as "2 MB", "800 KB" or "1.5mb". A bare number means megabytes. Units are decimal.</summary>
public static class FileSize
{
    public static long? Parse(string? text)
    {
        if (string.IsNullOrWhiteSpace(text)) return null;
        string number = "", unit = "";
        foreach (var c in text.ToLowerInvariant().Where(c => c != ' '))
        {
            if (char.IsDigit(c) || c == '.')
            {
                if (unit.Length > 0) return null;
                number += c;
            }
            else if (char.IsLetter(c)) unit += c;
            else return null;
        }
        if (!double.TryParse(number, NumberStyles.Float, CultureInfo.InvariantCulture, out var value) || value <= 0) return null;
        double multiplier = unit switch
        {
            "" or "m" or "mb" => 1_000_000,
            "k" or "kb" => 1_000,
            "g" or "gb" => 1_000_000_000,
            "b" or "bytes" or "byte" => 1,
            _ => 0,
        };
        if (multiplier == 0) return null;
        var bytes = (long)Math.Round(value * multiplier);
        return bytes > 0 ? bytes : null;
    }

    /// <summary>A size in the style Windows uses, such as "2.1 MB".</summary>
    public static string Text(long bytes)
    {
        string[] units = ["bytes", "KB", "MB", "GB", "TB"];
        double size = bytes;
        int unit = 0;
        while (size >= 1000 && unit < units.Length - 1) { size /= 1000; unit++; }
        return unit == 0 ? $"{bytes} bytes" : string.Create(CultureInfo.InvariantCulture, $"{size:0.#} {units[unit]}");
    }
}

/// <summary>How hard a PDF is compressed. Each preset is a Ghostscript setting that sets the image resolution.</summary>
public abstract record PdfCompression
{
    public sealed record Original : PdfCompression;
    public sealed record Low : PdfCompression;
    public sealed record Medium : PdfCompression;
    public sealed record High : PdfCompression;
    public sealed record Custom(long Bytes) : PdfCompression;

    /// <summary>The settings to try, in order. A preset tries one. A custom size tries stronger settings until it fits.</summary>
    public IReadOnlyList<string[]> Attempts => this switch
    {
        Original => [["-dPDFSETTINGS=/prepress"]],
        Low => [["-dPDFSETTINGS=/printer"]],
        Medium => [["-dPDFSETTINGS=/ebook"]],
        High => [["-dPDFSETTINGS=/screen"]],
        _ => new[] { new[] { "-dPDFSETTINGS=/printer" }, ["-dPDFSETTINGS=/ebook"], ["-dPDFSETTINGS=/screen"] }
            .Concat(new[] { 96, 72, 60, 48, 36 }.Select(dpi => new[]
            {
                "-dPDFSETTINGS=/screen", "-dDownsampleColorImages=true",
                $"-dColorImageResolution={dpi}", $"-dGrayImageResolution={dpi}", $"-dMonoImageResolution={dpi}",
            })).ToList(),
    };

    public long? GoalBytes => this is Custom c ? c.Bytes : null;
}

/// <summary>How the images of a multi-page PDF or PostScript file are delivered.</summary>
public enum PageOutput { Folder, Zip }
