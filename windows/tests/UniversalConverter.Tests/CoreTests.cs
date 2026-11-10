using System.Text;
using ImageMagick;
using UniversalConverter.Core;

namespace UniversalConverter.Tests;

public class DetectionTests
{
    private readonly FileDetector _detector = new();

    [SkippableTheory]
    [InlineData("images/sample.png", "png"), InlineData("images/sample.jpg", "jpg"), InlineData("images/sample.webp", "webp"),
     InlineData("images/sample.avif", "avif"), InlineData("documents/sample.pdf", "pdf"), InlineData("documents/sample.docx", "docx"),
     InlineData("documents/sample.odt", "odt"), InlineData("video/sample.mp4", "mp4"), InlineData("video/sample.mkv", "mkv"),
     InlineData("video/sample.webm", "webm"), InlineData("archives/sample.zip", "zip"), InlineData("archives/sample.7z", "7z"),
     InlineData("archives/sample.tar.gz", "targz"), InlineData("fonts/sample.ttf", "ttf"), InlineData("code/hello.py", "python"),
     InlineData("models/sample.obj", "obj"), InlineData("spreadsheets/sample.xlsx", "xlsx"), InlineData("markup/sample.md", "md")]
    public void SampleFilesAreRecognisedByTheirContent(string file, string expected)
    {
        Assert.Equal(expected, _detector.Detect(Samples.Path_(file)).FormatId);
    }

    [SkippableFact]
    public void ARenamedFileIsRecognisedByWhatItReallyIs()
    {
        using var temp = new TempFolder();
        var png = Samples.Picture(temp.Path);
        var disguised = temp.File_("holiday.jpg");
        File.Copy(png, disguised);
        var found = _detector.Detect(disguised);
        Assert.Equal("png", found.FormatId);
        Assert.True(found.ExtensionMismatch);
    }

    [SkippableFact]
    public void CameraRawIsToldApartByExtensionAndSignature()
    {
        var tiff = new byte[] { 0x49, 0x49, 0x2A, 0x00, 8, 0, 0, 0 };
        Assert.Equal("dng", _detector.Detect(tiff, "photo.dng").FormatId);
        Assert.Equal("nef", _detector.Detect(tiff, "photo.nrw").FormatId);
        Assert.Equal("tiff", _detector.Detect(tiff, "scan.tif").FormatId);
        Assert.Equal("raf", _detector.Detect(Encoding.ASCII.GetBytes("FUJIFILMCCD-RAW 0201"), "x.raf").FormatId);
        var cr3 = new byte[24];
        Encoding.ASCII.GetBytes("ftypcrx ").CopyTo(cr3, 4);
        Assert.Equal("cr3", _detector.Detect(cr3, "x.cr3").FormatId);
    }

    [SkippableFact]
    public void HeicBrandsAreRecognised()
    {
        var head = new byte[24];
        Encoding.ASCII.GetBytes("ftypheic").CopyTo(head, 4);
        Assert.Equal("heic", _detector.Detect(head, "IMG_0001.HEIC").FormatId);
    }

    [SkippableFact]
    public void ADoubleExtensionKeepsItsStem()
    {
        Assert.Equal("report", FileNames.Stem(Path.Combine("files", "report.tar.gz")));
        Assert.Equal("tar.gz", FileNames.EffectiveExtension("a.TAR.GZ"));
    }

    [SkippableFact]
    public void TextThatStartsWithBMIsNotABitmap()
    {
        Assert.Equal("txt", _detector.Detect(Encoding.UTF8.GetBytes("BM25 is a ranking function, used widely"), "notes.txt").FormatId);
    }

    [SkippableFact]
    public void AnEmptyFileDoesNotCrashDetection()
    {
        using var temp = new TempFolder();
        File.WriteAllBytes(temp.File_("empty.bin"), []);
        Assert.Equal(MediaCategory.Unknown, _detector.Detect(temp.File_("empty.bin")).Category);
    }
}

public class RoutingTests
{
    private static List<Route> RoutesFrom(string id, MediaCategory category) => FormatCatalog.RoutesFrom(id, category, _ => true);

    [SkippableFact]
    public void AVideoCanBecomeAudioAndOtherVideo()
    {
        var ids = RoutesFrom("mp4", MediaCategory.Video).Select(r => r.Id).ToList();
        Assert.Contains("mkv", ids); Assert.Contains("mp3", ids); Assert.DoesNotContain("mp4", ids);
    }

    [SkippableFact]
    public void MarkdownToPdfTakesTwoSteps()
    {
        var route = RoutesFrom("md", MediaCategory.Markup).Single(r => r.Id == "pdf");
        Assert.Equal(2, route.Steps.Count);
        Assert.Contains("via", route.Label);
    }

    [SkippableFact]
    public void ChainsNeverEndInTheSameKindOfFileTheyStartedWith()
    {
        var fonts = RoutesFrom("ttf", MediaCategory.Font);
        Assert.All(fonts, r => Assert.True(r.Steps.Count == 1 || FormatCatalog.OutputCategory(r.Id) != MediaCategory.Font));
    }

    [SkippableFact]
    public void CodeIsNeverAnIntermediateStep()
    {
        foreach (var route in RoutesFrom("python", MediaCategory.Code))
            Assert.All(route.Steps.Take(route.Steps.Count - 1), s => Assert.NotEqual(MediaCategory.Code, s.OutputCategory));
    }

    [SkippableFact]
    public void PageImagesCanOnlyBeTheLastStep()
    {
        foreach (var route in RoutesFrom("pdf", MediaCategory.Document))
            Assert.All(route.Steps.Take(route.Steps.Count - 1), s => Assert.False(s.ProducesPageImages));
    }

    [SkippableFact]
    public void ATargetWhoseToolIsMissingIsLeftOut()
    {
        var without = FormatCatalog.RoutesFrom("docx", MediaCategory.Document, e => e != Engine.LibreOffice);
        Assert.DoesNotContain(without, r => r.Engine == Engine.LibreOffice);
    }

    [SkippableFact]
    public void APictureCanStayInItsFormatAndBeAdjusted()
    {
        var routes = RoutesFrom("jpg", MediaCategory.Image);
        Assert.Contains(routes, r => r.Id == "jpg" && r.Target.Label.EndsWith("adjusted"));
        Assert.DoesNotContain(RoutesFrom("gif", MediaCategory.Image), r => r.Id == "gif");
    }

    [SkippableFact]
    public void HeicIsReadButNotOffered()
    {
        Assert.DoesNotContain(RoutesFrom("png", MediaCategory.Image), r => r.Id == "heic");
        Assert.Contains(RoutesFrom("heic", MediaCategory.Image), r => r.Id == "jpg");
    }

    [SkippableFact]
    public void TextFromPicturesNeedsTheSystemsTextRecognition()
    {
        Assert.DoesNotContain(FormatCatalog.RoutesFrom("png", MediaCategory.Image, e => e != Engine.Ocr), r => r.Id == "txt" && r.Engine == Engine.Ocr);
        Assert.Contains(FormatCatalog.RoutesFrom("png", MediaCategory.Image, _ => true), r => r.Id == "txt" && r.Engine == Engine.Ocr);
    }

    [SkippableFact]
    public void JavaClassNamesAreLegalIdentifiers()
    {
        Assert.Equal("my_file", FormatCatalog.JavaClassName("my-file"));
        Assert.Equal("_2024_report", FormatCatalog.JavaClassName("2024 report"));
        Assert.Equal("class_", FormatCatalog.JavaClassName("class"));
        Assert.Equal("Main", FormatCatalog.JavaClassName(""));
    }
}

public class SizeTests
{
    [SkippableTheory]
    [InlineData("2 MB", 2_000_000), InlineData("800kb", 800_000), InlineData("1.5mb", 1_500_000), InlineData("3", 3_000_000), InlineData("1 GB", 1_000_000_000)]
    public void SizesAreParsed(string text, long bytes) => Assert.Equal(bytes, FileSize.Parse(text));

    [SkippableTheory]
    [InlineData(""), InlineData("abc"), InlineData("0 MB"), InlineData("-5 MB"), InlineData("5 parsecs")]
    public void BadSizesAreRefused(string text) => Assert.Null(FileSize.Parse(text));

    [SkippableFact]
    public void ACustomPdfSizeTriesStrongerSettingsInOrder()
    {
        var attempts = new PdfCompression.Custom(500_000).Attempts;
        Assert.Equal("-dPDFSETTINGS=/printer", attempts[0][0]);
        Assert.True(attempts.Count > 5);
        Assert.Single(new PdfCompression.Medium().Attempts);
    }

    [SkippableFact]
    public void ProgressIsKeptBetweenZeroAndOne()
    {
        Assert.Equal(1, new ConversionProgress("x", 1.7).Fraction);
        Assert.Equal(0, new ConversionProgress("x", -0.2).Fraction);
        Assert.Null(new ConversionProgress("x").Fraction);
    }
}

public class CodeChunkerTests
{
    private const string JavaClass = """
        import java.util.List;

        public class Demo {
            private int count = 0;

            // Adds one.
            public void add() {
                count++;
            }

            public List<Integer> values() {
                return null;
            }
        }

        """;

    [SkippableFact]
    public void ALongPythonFileIsCutBetweenFunctions()
    {
        var source = string.Join("\n\n", Enumerable.Range(1, 400).Select(i => $"def f{i}(x):\n    return x * {i}"));
        var parts = CodeChunker.Split(source, 2000);
        Assert.True(parts.Count > 2);
        Assert.All(parts, p => Assert.StartsWith("def ", p.TrimStart()));
        Assert.Equal(400, parts.Sum(p => p.Split("def ").Length - 1));
    }

    [SkippableFact]
    public void JoinKeepsOneCopyOfEachImport()
    {
        var joined = CodeChunker.Join(["import os\nimport sys\n\ndef a(): pass", "import os\nimport re\n\ndef b(): pass"]);
        Assert.Equal(1, joined.Split("import os").Length - 1);
        Assert.Contains("import re", joined);
    }

    [SkippableFact]
    public void AJavaClassIsCutBetweenItsMembers()
    {
        var split = CodeChunker.SplitJavaClass(JavaClass.Replace("\r\n", "\n"), 40)!;
        Assert.Equal("Demo", split.ClassName);
        Assert.Contains("import java.util.List;", split.Header);
        Assert.True(split.Parts.Count >= 2);
        Assert.All(split.Parts, p => Assert.Equal(p.Count(c => c == '{'), p.Count(c => c == '}')));
    }

    [SkippableFact]
    public void AScriptIsNotTreatedAsAClass() => Assert.Null(CodeChunker.SplitJavaClass("print('hi')\n"));

    [SkippableFact]
    public void JoinedJavaMembersAreOneClassWithImportsOnTop()
    {
        var joined = CodeChunker.JoinJavaClass(["import a.B;\n\nint x() { return 1; }", "import a.B;\nimport c.D;\n\nint y() { return 2; }"], "Demo");
        Assert.Equal(1, joined.Split("import a.B;").Length - 1);
        Assert.True(joined.IndexOf("import c.D;") < joined.IndexOf("public class Demo {"));
        Assert.EndsWith("}\n", joined);
    }

    [SkippableFact]
    public void AWrapperTheModelAddsGoesButARealClassStays()
    {
        string[] parts =
        [
            "public class Wrapper {\n    public static int add(int a, int b) { return a + b; }\n}",
            "public class Point {\n    int x;\n}",
        ];
        var joined = CodeChunker.JoinJavaClass(parts, "Demo", new HashSet<string> { "Point" });
        Assert.DoesNotContain("class Wrapper", joined);
        Assert.Contains("static class Point", joined);
        Assert.Equal(joined.Count(c => c == '{'), joined.Count(c => c == '}'));
    }

    [SkippableFact]
    public void AWrapperThatEndsWithACommentIsStillClosed()
    {
        var joined = CodeChunker.JoinJavaClass(["class Wrapper {\n    int x;\n} // end\nint y() {\n    return 1;\n}"], "Demo");
        Assert.Equal(joined.Count(c => c == '{'), joined.Count(c => c == '}'));
    }

    [SkippableFact]
    public void ClassNamesAreFoundInAnyLanguage()
    {
        var names = CodeChunker.TypeNames("# the class of things\nclass Point:\n    pass\nclass Line(Point):\n    pass\npub struct Grid {\n}\npublic final class Box<T> {\n}\ndef run(): pass");
        Assert.Equal(new HashSet<string> { "Point", "Line", "Grid", "Box" }, names);
    }

    [SkippableFact]
    public void TheMembersPromptAsksForTopLevelCode()
    {
        var prompt = CodePrompt.Members(FormatCatalog.CodeLanguageForId("java")!, FormatCatalog.CodeLanguageForId("python")!, "int x;", "Demo", "import a.B;", 1, 2);
        Assert.Contains("no surrounding class", prompt);
        Assert.Contains("import a.B;", prompt);
    }

    [SkippableFact]
    public void ModelFencesAreRemoved() =>
        Assert.Equal("print(1)\n", CodeOutputCleaner.Clean("```python\nprint(1)\n```\n"));
}
