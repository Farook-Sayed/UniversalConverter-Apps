using UglyToad.PdfPig;
using UniversalConverter.Core;
using Xunit;

namespace UniversalConverter.Tests;

/// <summary>Opening password-protected PDFs and saving a copy without the password.</summary>
public class PdfUnlockTests : IDisposable
{
    private readonly TempFolder _temp = new();
    public void Dispose() => _temp.Dispose();

    // One-page PDFs made with PDFKit. The first two need the password to open. The last only has restrictions.
    private const string SharedPassword = "JVBERi0xLjYKJcTl8uXrp/Og0MTGCjQgMCBvYmoKPDwgL0xlbmd0aCAzMiAvRmlsdGVyIC9GbGF0ZURlY29kZSA+PgpzdHJlYW0KLC2zOmxKk2ByvQhfaraXRY44u1AmL4mmg74qJgVVY9sKZW5kc3RyZWFtCmVuZG9iagoxIDAgb2JqCjw8IC9UeXBlIC9QYWdlIC9QYXJlbnQgMiAwIFIgL1Jlc291cmNlcyAzIDAgUiAvQ29udGVudHMgNCAwIFIgL01lZGlhQm94IFswIDAgNjEyIDc5Ml0KL1JvdGF0ZSAwID4+CmVuZG9iagozIDAgb2JqCjw8IC9Qcm9jU2V0IFsgL1BERiBdID4+CmVuZG9iagoyIDAgb2JqCjw8IC9UeXBlIC9QYWdlcyAvTWVkaWFCb3ggWzAgMCA2MTIgNzkyXSAvQ291bnQgMSAvS2lkcyBbIDEgMCBSIF0gPj4KZW5kb2JqCjUgMCBvYmoKPDwgL1R5cGUgL0NhdGFsb2cgL1BhZ2VzIDIgMCBSIC9WZXJzaW9uIC8xLjYgPj4KZW5kb2JqCjYgMCBvYmoKPDwgL1Byb2R1Y2VyICg+hz/VPIzD5l5qN4pcKVwwMTPlW8egiyolxXNcMDExc13/RUIhPbhcMDMyXDAzMY9r2HuSVazsfrH470Jg6evYc3RcMDMxZIthZaVcMDAycKXJXDAzM1wwMTFbmOLndq57eMhtck3z5bApCi9DcmVhdGlvbkRhdGUgKIOAImhhteMrIFwwMzdXOVwwMjBcXDi35ms7R6ZcMDEzejEvXDAxMKpcXHQrjDqd9lp98VTwajWr8n7+U1wwMzC5KQovTW9kRGF0ZSAoN1wwMDRr7IBcMDAx9ufzXnyUW1wwMjNxz1woPFnl6+ji2FstXDAyNWu7hfZcMDA3ueOhV3RcMDMw3qI/v5HMk240jCkKPj4KZW5kb2JqCjcgMCBvYmoKPDwgL0ZpbHRlciAvU3RhbmRhcmQgL1YgNCAvUiA0IC9MZW5ndGggMTI4IC9DRiA8PCAvU3RkQ0YgPDwgL0F1dGhFdmVudCAvRG9jT3BlbgovQ0ZNIC9BRVNWMiAvTGVuZ3RoIDE2ID4+ID4+IC9TdG1GIC9TdGRDRiAvU3RyRiAvU3RkQ0YgL0VuY3J5cHRNZXRhZGF0YSB0cnVlCi9PIDwyYzZmZDQyNWFiMzM3NDlhMjcwYjhmYmRjNTg4N2NmMzYxZWYxMmM3NDM2ZjRmNzhiNDg0MGIzNDhkOTFiNTRiPiAvVSA8ZGJkMWU5NzQzMDhiMDU2MmM5ODZkNmFlZDVjOTI3NDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMD4KL1AgLTQgPj4KZW5kb2JqCnhyZWYKMCA4CjAwMDAwMDAwMDAgNjU1MzUgZiAKMDAwMDAwMDEyNSAwMDAwMCBuIAowMDAwMDAwMjc4IDAwMDAwIG4gCjAwMDAwMDAyMzkgMDAwMDAgbiAKMDAwMDAwMDAyMiAwMDAwMCBuIAowMDAwMDAwMzYxIDAwMDAwIG4gCjAwMDAwMDA0MjQgMDAwMDAgbiAKMDAwMDAwMDcyNCAwMDAwMCBuIAp0cmFpbGVyCjw8IC9TaXplIDggL1Jvb3QgNSAwIFIgL0VuY3J5cHQgNyAwIFIgL0luZm8gNiAwIFIgL0lEIFsgPGJhMzJhN2JjOTMwMDI0OWI0NmEzZGI1MDUwMjFmYzRkPgo8YmEzMmE3YmM5MzAwMjQ5YjQ2YTNkYjUwNTAyMWZjNGQ+IF0gPj4Kc3RhcnR4cmVmCjEwNDUKJSVFT0YK";
    private const string OtherPassword = "JVBERi0xLjYKJcTl8uXrp/Og0MTGCjQgMCBvYmoKPDwgL0xlbmd0aCAzMiAvRmlsdGVyIC9GbGF0ZURlY29kZSA+PgpzdHJlYW0K0LnOvfU09lEP0ay8LmlqHln5/U/yYME/C308ciw920sKZW5kc3RyZWFtCmVuZG9iagoxIDAgb2JqCjw8IC9UeXBlIC9QYWdlIC9QYXJlbnQgMiAwIFIgL1Jlc291cmNlcyAzIDAgUiAvQ29udGVudHMgNCAwIFIgL01lZGlhQm94IFswIDAgNjEyIDc5Ml0KL1JvdGF0ZSAwID4+CmVuZG9iagozIDAgb2JqCjw8IC9Qcm9jU2V0IFsgL1BERiBdID4+CmVuZG9iagoyIDAgb2JqCjw8IC9UeXBlIC9QYWdlcyAvTWVkaWFCb3ggWzAgMCA2MTIgNzkyXSAvQ291bnQgMSAvS2lkcyBbIDEgMCBSIF0gPj4KZW5kb2JqCjUgMCBvYmoKPDwgL1R5cGUgL0NhdGFsb2cgL1BhZ2VzIDIgMCBSIC9WZXJzaW9uIC8xLjYgPj4KZW5kb2JqCjYgMCBvYmoKPDwgL1Byb2R1Y2VyICi2XDAzNz9yXDAwNknbT1wwMTF981wwMzROubiL8lwpXDAyNsz0MOCIcJWwXDAyM6FFOJM9mdSxpOpnPrJ8c5BcMDI1jVGEl4hcMDMypkprj0k2cOqI/2HJQcdcMDI3x3VgZX9cMDM0Vs3d93BwTyQpCi9DcmVhdGlvbkRhdGUgKN0xmcy6XDAxMM0tJGaJQfnPXbiTSVNjIMBcMDExqTG7xlGtkE9lSnaJllwwMzOc/7BcMDAz6lwwMzGsbGGQ3ykKL01vZERhdGUgKK3eXDAzNVIlX1wwMTNcMDA3a2ZSXCn011wwMzI6fFwwMjBcMDE0XDAxNc2UI76O4Wi8PaNcMDIzuoXh0Ut5lFT8jOiRQua0kiMpCj4+CmVuZG9iago3IDAgb2JqCjw8IC9GaWx0ZXIgL1N0YW5kYXJkIC9WIDQgL1IgNCAvTGVuZ3RoIDEyOCAvQ0YgPDwgL1N0ZENGIDw8IC9BdXRoRXZlbnQgL0RvY09wZW4KL0NGTSAvQUVTVjIgL0xlbmd0aCAxNiA+PiA+PiAvU3RtRiAvU3RkQ0YgL1N0ckYgL1N0ZENGIC9FbmNyeXB0TWV0YWRhdGEgdHJ1ZQovTyA8M2I2ZWQzMzFhYjI1M2M4NDI0MGI4ZmJkYzU4ODdjZjM2MWVmMTJjNzQzNmY0Zjc4YjQ4NDBiMzQ4ZDkxYjU0Yj4gL1UgPDliYWEwNzVmYzFhNTVmNjdkNWY1ZTAzZmY4MWY0NjFlMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDA+Ci9QIC00ID4+CmVuZG9iagp4cmVmCjAgOAowMDAwMDAwMDAwIDY1NTM1IGYgCjAwMDAwMDAxMjUgMDAwMDAgbiAKMDAwMDAwMDI3OCAwMDAwMCBuIAowMDAwMDAwMjM5IDAwMDAwIG4gCjAwMDAwMDAwMjIgMDAwMDAgbiAKMDAwMDAwMDM2MSAwMDAwMCBuIAowMDAwMDAwNDI0IDAwMDAwIG4gCjAwMDAwMDA3MzQgMDAwMDAgbiAKdHJhaWxlcgo8PCAvU2l6ZSA4IC9Sb290IDUgMCBSIC9FbmNyeXB0IDcgMCBSIC9JbmZvIDYgMCBSIC9JRCBbIDxiNDMzZDYwNjM0MzVhNWRiOTQzNzQ5MWM5NTMxYWQxMz4KPGI0MzNkNjA2MzQzNWE1ZGI5NDM3NDkxYzk1MzFhZDEzPiBdID4+CnN0YXJ0eHJlZgoxMDU1CiUlRU9GCg==";
    private const string Restricted = "JVBERi0xLjYKJcTl8uXrp/Og0MTGCjQgMCBvYmoKPDwgL0xlbmd0aCAzMiAvRmlsdGVyIC9GbGF0ZURlY29kZSA+PgpzdHJlYW0Kfb6tB8yDGlBklxyv7PP+HQS/K7ntYEsSGg11zfi2VxEKZW5kc3RyZWFtCmVuZG9iagoxIDAgb2JqCjw8IC9UeXBlIC9QYWdlIC9QYXJlbnQgMiAwIFIgL1Jlc291cmNlcyAzIDAgUiAvQ29udGVudHMgNCAwIFIgL01lZGlhQm94IFswIDAgNjEyIDc5Ml0KL1JvdGF0ZSAwID4+CmVuZG9iagozIDAgb2JqCjw8IC9Qcm9jU2V0IFsgL1BERiBdID4+CmVuZG9iagoyIDAgb2JqCjw8IC9UeXBlIC9QYWdlcyAvTWVkaWFCb3ggWzAgMCA2MTIgNzkyXSAvQ291bnQgMSAvS2lkcyBbIDEgMCBSIF0gPj4KZW5kb2JqCjUgMCBvYmoKPDwgL1R5cGUgL0NhdGFsb2cgL1BhZ2VzIDIgMCBSIC9WZXJzaW9uIC8xLjYgPj4KZW5kb2JqCjYgMCBvYmoKPDwgL1Byb2R1Y2VyIChcMDM2uoeAYFwwMTfPSVwwMzJiXDAwNaVJju5cMDAwnptcMDA39JRcMDIysVwwMTVcMDI2IcOxRprvzUi/XDAzMSCjXDAyN9ZcMDA0kIU/roFcMDA2I3B5OMRcMDMxf48wjEdwY1xcoLbjYEXMXDAxMypCi9nsIYfwXDAxM3dz6yApCi9DcmVhdGlvbkRhdGUgKCtcMDEwjlwwMDbokfVcMDExjz45h1wwMTWkVcnM72QnwYKnXCjP71GS5drzv7pcMDI0eZ1CuC2qm8o3Vo9ky7spCi9Nb2REYXRlIChcMDAyieqcVGSEwP7rPIC58a69Q+SIU7yBlmLMg0uWvVCGyVQn7UZQXDAxNZjZxOVHXDAyNlqp2FApID4+CmVuZG9iago3IDAgb2JqCjw8IC9GaWx0ZXIgL1N0YW5kYXJkIC9WIDQgL1IgNCAvTGVuZ3RoIDEyOCAvQ0YgPDwgL1N0ZENGIDw8IC9BdXRoRXZlbnQgL0RvY09wZW4KL0NGTSAvQUVTVjIgL0xlbmd0aCAxNiA+PiA+PiAvU3RtRiAvU3RkQ0YgL1N0ckYgL1N0ZENGIC9FbmNyeXB0TWV0YWRhdGEgdHJ1ZQovTyA8NzdiOGZiMDk4MDIyZDNhYjM0MjM3ZWE1NjQzYzA4NzEwZWE1MTIzZmM1Zjg4YmY5OTNhNjhjY2E1ZjEyYjQwZj4gL1UgPDhiNzVlOGU4OGM4YTFhM2VkNGZmZDIyOGVkN2JhYjgzMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDA+Ci9QIC00ID4+CmVuZG9iagp4cmVmCjAgOAowMDAwMDAwMDAwIDY1NTM1IGYgCjAwMDAwMDAxMjUgMDAwMDAgbiAKMDAwMDAwMDI3OCAwMDAwMCBuIAowMDAwMDAwMjM5IDAwMDAwIG4gCjAwMDAwMDAwMjIgMDAwMDAgbiAKMDAwMDAwMDM2MSAwMDAwMCBuIAowMDAwMDAwNDI0IDAwMDAwIG4gCjAwMDAwMDA3MzcgMDAwMDAgbiAKdHJhaWxlcgo8PCAvU2l6ZSA4IC9Sb290IDUgMCBSIC9FbmNyeXB0IDcgMCBSIC9JbmZvIDYgMCBSIC9JRCBbIDw0ODI3NmNiMzc0M2FmY2M3YTQ0NmZjNTRmMGJiNTI4Yj4KPDQ4Mjc2Y2IzNzQzYWZjYzdhNDQ2ZmM1NGYwYmI1MjhiPiBdID4+CnN0YXJ0eHJlZgoxMDU4CiUlRU9GCg==";

    private string Write(string name, string base64)
    {
        var path = _temp.File_(name);
        File.WriteAllBytes(path, Convert.FromBase64String(base64));
        return path;
    }

    [Fact]
    public void WrongPasswordKeepsThePdfLocked()
    {
        var path = Write("a.pdf", SharedPassword);
        Assert.IsType<PdfOpened.NeedsPassword>(PdfUnlocker.Open(path, ["nope"]));
        Assert.Null(PdfUnlocker.Open(path, "nope"));
    }

    [Fact]
    public void RememberedPasswordOpensSeveralFilesAndKeepsTheName()
    {
        var first = Write("Invoice-March.pdf", SharedPassword);
        var second = Write("Invoice-April.pdf", SharedPassword);
        var other = Write("Contract.pdf", OtherPassword);
        var typed = new List<string> { "shared-pw" };

        foreach (var path in new[] { first, second })
        {
            var opened = Assert.IsType<PdfOpened.Unlocked>(PdfUnlocker.Open(path, typed));
            try
            {
                Assert.Equal(Path.GetFileName(path), Path.GetFileName(opened.Copy));
                using var copy = PdfDocument.Open(opened.Copy); // no password needed any more
                Assert.False(copy.IsEncrypted);
                Assert.Equal(1, copy.NumberOfPages);
            }
            finally { Directory.Delete(Path.GetDirectoryName(opened.Copy)!, true); }
        }
        // A different password in the list does not open a file with another one.
        Assert.IsType<PdfOpened.NeedsPassword>(PdfUnlocker.Open(other, typed));
    }

    [Fact]
    public void PdfWithOnlyRestrictionsOpensWithoutAskingAndIsSavedWithoutThem()
    {
        var path = Write("Brochure.pdf", Restricted);
        var opened = Assert.IsType<PdfOpened.Unlocked>(PdfUnlocker.Open(path, []));
        try
        {
            Assert.Null(opened.Password);
            using var copy = PdfDocument.Open(opened.Copy);
            Assert.False(copy.IsEncrypted);
        }
        finally { Directory.Delete(Path.GetDirectoryName(opened.Copy)!, true); }
    }

    [Fact]
    public void PlainPdfIsLeftAlone()
    {
        var path = _temp.File_("plain.pdf");
        var builder = new UglyToad.PdfPig.Writer.PdfDocumentBuilder();
        builder.AddPage(200, 200);
        File.WriteAllBytes(path, builder.Build());
        Assert.IsType<PdfOpened.NotProtected>(PdfUnlocker.Open(path, []));
    }

    [Fact]
    public void MergeUsesTheUnlockedCopy()
    {
        var path = Write("Locked.pdf", SharedPassword);
        var opened = Assert.IsType<PdfOpened.Unlocked>(PdfUnlocker.Open(path, ["shared-pw"]));
        try
        {
            var output = _temp.File_("merged.pdf");
            var file = new FileDetector().Detect(opened.Copy);
            Assert.Equal(1, PdfMerger.Merge([file, file], MergePageSize.A4, output, _ => { }, CancellationToken.None) / 2);
        }
        finally { Directory.Delete(Path.GetDirectoryName(opened.Copy)!, true); }
    }

    [Fact]
    public async Task OnePasswordOpensEveryFileThatSharesIt()
    {
        var first = Write("Invoice-March.pdf", SharedPassword);
        var second = Write("Invoice-April.pdf", SharedPassword);
        var other = Write("Contract.pdf", OtherPassword);
        var model = new App.ViewModels.MainViewModel();
        int asked = 0;
        model.PasswordNeeded += () => asked++;
        await model.AddFilesAsync([first, second, other]);
        await WaitFor(() => model.Items.All(i => i.Lock != App.ViewModels.PdfLock.Checking));

        Assert.True(asked > 0);
        Assert.Equal(3, model.LockedCount);
        Assert.All(model.Items, i => Assert.False(i.CanConvert)); // blocked until opened

        var (opened, waiting) = await model.UnlockPdfsAsync("shared-pw");
        Assert.Equal((2, 3), (opened, waiting));
        Assert.Equal(1, model.LockedCount);
        Assert.True(model.Items.Single(i => i.NeedsPassword).Name == "Contract.pdf");
        Assert.All(model.Items.Where(i => i.IsUnlocked), i => Assert.True(i.IsOpenForMerge));
        Assert.Equal((0, 1), await model.UnlockPdfsAsync("wrong"));

        // A PDF added later with the same password opens without asking again.
        var third = Write("Invoice-May.pdf", SharedPassword);
        await model.AddFilesAsync([third]);
        await WaitFor(() => model.Items.All(i => i.Lock != App.ViewModels.PdfLock.Checking));
        Assert.True(model.Items.Single(i => i.Name == "Invoice-May.pdf").IsUnlocked);

        var unlocked = model.Items.First(i => i.IsUnlocked);
        var saved = model.SaveUnlockedCopy(unlocked);
        Assert.NotNull(saved);
        try { using var copy = PdfDocument.Open(saved!); Assert.False(copy.IsEncrypted); }
        finally { File.Delete(saved!); }

        var copies = model.Items.Where(i => i.UnlockedPath is not null).Select(i => i.UnlockedPath!).ToList();
        foreach (var item in model.Items.ToList()) model.Remove(item);
        Assert.All(copies, c => Assert.False(File.Exists(c)));
    }

    private static async Task WaitFor(Func<bool> done)
    {
        for (int i = 0; i < 200 && !done(); i++) await Task.Delay(50);
        Assert.True(done());
    }

    [Fact]
    public void DamagedFileIsNotReportedAsProtected()
    {
        var path = _temp.File_("broken.pdf");
        File.WriteAllText(path, "this is not a pdf");
        Assert.IsType<PdfOpened.NotProtected>(PdfUnlocker.Open(path, ["x"]));
    }

    [Fact]
    public void UnreadableEncryptedFileIsReportedAsProtectedWithoutAPasswordPrompt()
    {
        var path = _temp.File_("odd.pdf");
        File.WriteAllText(path, "%PDF-1.7\n1 0 obj\n<< /Filter /Standard /V 9 >>\nendobj\ntrailer\n<< /Encrypt 1 0 R >>\n%%EOF");
        Assert.IsType<PdfOpened.Unsupported>(PdfUnlocker.Open(path, ["x"]));
    }

    [Fact]
    public void UnlockedCopyKeepsTheTitle()
    {
        var path = Write("t.pdf", SharedPassword);
        var opened = Assert.IsType<PdfOpened.Unlocked>(PdfUnlocker.Open(path, ["shared-pw"]));
        try { using var copy = PdfDocument.Open(opened.Copy); Assert.NotNull(copy.Information); }
        finally { Directory.Delete(Path.GetDirectoryName(opened.Copy)!, true); }
    }
}
