using UglyToad.PdfPig;
using UglyToad.PdfPig.Exceptions;
using UglyToad.PdfPig.Writer;

namespace UniversalConverter.Core;

/// <summary>How a PDF was found to be protected, and what was done about it.</summary>
public abstract record PdfOpened
{
    /// <summary>Not encrypted. The original file is used as it is.</summary>
    public sealed record NotProtected : PdfOpened;
    /// <summary>Opened. <paramref name="Copy"/> is a copy without protection, with the same file name as the original.</summary>
    public sealed record Unlocked(string Copy, string? Password) : PdfOpened;
    /// <summary>A password is needed, and none of the passwords tried fits.</summary>
    public sealed record NeedsPassword : PdfOpened;
}

/// <summary>
/// Opens password-protected PDFs and writes a copy without protection, with PdfPig, which is part of the app. Everything
/// happens on this PC. A password is never guessed: a PDF that needs one stays locked until the user types it.
/// </summary>
public static class PdfUnlocker
{
    /// <summary>
    /// Opens a PDF for the queue. A PDF that only has restrictions opens at once. For a PDF with a password, the passwords
    /// already typed for other files are tried first, so one password can open many files.
    /// </summary>
    public static PdfOpened Open(string path, IEnumerable<string> passwords)
    {
        var first = Try(path, null);
        if (first is Result.Open plain) return plain.Encrypted ? (PdfOpened?)Copy(path, "") ?? new PdfOpened.NeedsPassword() : new PdfOpened.NotProtected();
        if (first is Result.NotPdf) return new PdfOpened.NotProtected();
        foreach (var password in passwords)
            if (Try(path, password) is Result.Open && Copy(path, password) is { } opened) return opened;
        return new PdfOpened.NeedsPassword();
    }

    /// <summary>Tries one password. Returns null when it does not open the PDF.</summary>
    public static PdfOpened.Unlocked? Open(string path, string password) =>
        Try(path, password) is Result.Open ? Copy(path, password) as PdfOpened.Unlocked : null;

    /// <summary>Writes a copy of the PDF without a password or restrictions.</summary>
    public static void WriteUnlocked(string path, string password, string output)
    {
        using var document = Load(path, password) ?? throw ConversionException.Unsupported("That password does not open this PDF.");
        var builder = new PdfDocumentBuilder();
        // The pages keep their text, images and drawings. Bookmarks and form fields of the original are not carried over.
        for (int number = 1; number <= document.NumberOfPages; number++) builder.AddPage(document, number);
        var bytes = builder.Build();
        Directory.CreateDirectory(Path.GetDirectoryName(output)!);
        File.WriteAllBytes(output, bytes);
    }

    private static PdfOpened.Unlocked? Copy(string path, string password)
    {
        var folder = Path.Combine(Path.GetTempPath(), "fc-work-unlocked-" + Guid.NewGuid().ToString("N"));
        var copy = Path.Combine(folder, Path.GetFileName(path));
        try
        {
            WriteUnlocked(path, password, copy);
            return new PdfOpened.Unlocked(copy, password.Length == 0 ? null : password);
        }
        catch
        {
            try { Directory.Delete(folder, true); } catch { /* nothing was written */ }
            return null;
        }
    }

    private abstract record Result
    {
        public sealed record Open(bool Encrypted) : Result;
        public sealed record NeedsPassword : Result;
        public sealed record NotPdf : Result;
    }

    private static Result Try(string path, string? password)
    {
        try
        {
            using var document = password is null ? PdfDocument.Open(path) : PdfDocument.Open(path, Options(password));
            return new Result.Open(document.IsEncrypted);
        }
        catch (PdfDocumentEncryptedException) { return new Result.NeedsPassword(); }
        catch { return new Result.NotPdf(); }
    }

    private static PdfDocument? Load(string path, string password)
    {
        try { return PdfDocument.Open(path, Options(password)); }
        catch { return null; }
    }

    private static ParsingOptions Options(string password) => new() { Passwords = [password], UseLenientParsing = true };
}
