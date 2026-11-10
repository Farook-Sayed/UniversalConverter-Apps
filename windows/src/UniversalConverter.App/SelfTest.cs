using System.Reflection;
using System.Text;
using ImageMagick;
using UniversalConverter.Core;

namespace UniversalConverter.App;

/// <summary>Checks that everything built into the program works on this PC: the picture library, the background model,
/// PDF, archives, 3D models and text recognition. Run it with <c>UniversalConverter.exe --selftest</c>. The report is
/// printed and also saved as UniversalConverter-selftest.txt in the temp folder, because a Windows program has no console.</summary>
public static class SelfTest
{
    public static int Run()
    {
        var report = new StringBuilder();
        int failed = 0;
        void Check(string name, Func<string> test)
        {
            try { var result = test(); report.AppendLine($"OK     {name}: {result}"); }
            catch (SkipTest skip) { report.AppendLine($"SKIP   {name}: {skip.Message}"); }
            catch (Exception ex) { failed++; report.AppendLine($"FAIL   {name}: {ex.GetType().Name}: {ex.Message.Split('\n')[0]}"); }
        }
        var work = Path.Combine(Path.GetTempPath(), "uc-selftest-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(work);
        report.AppendLine($"Universal Converter self-test on {System.Runtime.InteropServices.RuntimeInformation.OSDescription} ({System.Runtime.InteropServices.RuntimeInformation.OSArchitecture})");

        var picture = Path.Combine(work, "subject.png");
        using (var image = new MagickImage(new MagickColor("#203040"), 512, 512))
        {
            new ImageMagick.Drawing.Drawables().FillColor(MagickColors.OrangeRed).Circle(256, 256, 256, 400).Draw(image);
            image.Write(picture);
        }

        Check("pictures", () =>
        {
            var sizes = new List<string>();
            foreach (var id in new[] { "jpg", "png", "webp", "avif", "tiff", "bmp", "gif", "pdf" })
                sizes.Add($"{id} {ImageProcessing.Render(picture, id, ImageAdjustments.Unchanged).Data.Length / 1024} KB");
            return string.Join(", ", sizes);
        });
        Check("crop, size, sketch", () =>
        {
            var a = ImageProcessing.Render(picture, "png", new ImageAdjustments { CropRect = new FractionRect(0.25, 0.25, 0.5, 0.5), Resize = ResizeMode.Percent, ResizeValue = 50, Effect = ImageEffect.Sketch });
            using var result = new MagickImage(a.Data);
            return result.Width == 128 && result.Height == 128 ? "128 x 128" : throw new Exception($"got {result.Width} x {result.Height}");
        });
        Check("compress to a size", () =>
        {
            var a = ImageProcessing.Render(picture, "jpg", new ImageAdjustments { Compression = CompressionPreset.Custom, CustomBytes = 8_000 });
            return a.Data.Length <= 8_000 ? $"{a.Data.Length} bytes" : throw new Exception($"{a.Data.Length} bytes is over 8000");
        });
        Check("background removal", () =>
        {
            var a = ImageProcessing.Render(picture, "png", new ImageAdjustments { RemoveBackground = true });
            using var result = new MagickImage(a.Data);
            var corner = result.GetPixels().GetPixel(3, 3)!.ToColor()!;
            var middle = result.GetPixels().GetPixel(256, 256)!.ToColor()!;
            return corner.A < 30_000 && middle.A > 30_000 ? "the subject was kept and the background removed" : throw new Exception($"corner alpha {corner.A}, middle alpha {middle.A}");
        });
        Check("PDF", () =>
        {
            var pdf = Path.Combine(work, "page.pdf");
            using (var page = new MagickImage(picture)) page.Write(pdf, MagickFormat.Pdf);
            var bytes = File.ReadAllBytes(pdf);
            int pages = PDFtoImage.Conversion.GetPageCount(bytes);
            var png = Path.Combine(work, "page.png");
            PDFtoImage.Conversion.SavePng(png, bytes, 0, options: new PDFtoImage.RenderOptions(Dpi: 72));
            using var doc = UglyToad.PdfPig.PdfDocument.Open(bytes);
            return $"{pages} page drawn, {new FileInfo(png).Length / 1024} KB, {doc.NumberOfPages} page read for text";
        });
        Check("archives", () =>
        {
            var folder = Directory.CreateDirectory(Path.Combine(work, "files")).FullName;
            File.WriteAllText(Path.Combine(folder, "a.txt"), "hello");
            var zip = Path.Combine(work, "a.zip");
            Archives.Pack(folder, "zip", zip);
            var tgz = Path.Combine(work, "a.tar.gz");
            Archives.Pack(folder, "targz", tgz);
            var back = Directory.CreateDirectory(Path.Combine(work, "back")).FullName;
            Archives.Extract(tgz, "targz", back, CancellationToken.None);
            return File.ReadAllText(Path.Combine(back, "a.txt")) == "hello" ? "zip and tar.gz written, tar.gz read" : throw new Exception("the file did not survive");
        });
        Check("3D models", () =>
        {
            var obj = Path.Combine(work, "tri.obj");
            File.WriteAllText(obj, "v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n");
            var stl = Path.Combine(work, "tri.stl");
            try
            {
                using var context = new Assimp.AssimpContext();
                var scene = context.ImportFile(obj, Assimp.PostProcessSteps.None);
                if (!context.ExportFile(scene, stl, "stl")) throw new Exception("export refused");
            }
            catch (DllNotFoundException) { throw new SkipTest("the 3D library is only bundled for Windows"); }
            catch (Assimp.AssimpException ex) when (ex.Message.Contains("unmanaged library")) { throw new SkipTest("the 3D library is only bundled for Windows"); }
            return $"OBJ to STL, {new FileInfo(stl).Length} bytes";
        });
        Check("text recognition", () =>
        {
            if (Ocr.Engine is null) throw new SkipTest("Windows text recognition is not available here");
            using var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("ocr-test.png")!;
            using var memory = new MemoryStream();
            stream.CopyTo(memory);
            var text = Ocr.Engine.RecognizeAsync(memory.ToArray(), CancellationToken.None).GetAwaiter().GetResult();
            return text.Contains("HELLO", StringComparison.OrdinalIgnoreCase) ? $"read \"{text.Trim()}\"" : throw new Exception($"read \"{text.Trim()}\" instead of HELLO WORLD");
        });
        Check("tools found", () =>
        {
            var tools = new ToolLocator();
            return string.Join(", ", new[] { "ffmpeg", "soffice", "pandoc", "ebook-convert", "7z", "ollama" }.Select(n => $"{n} {(tools.Locate(n == "7z" ? "7zz" : n, n) is not null ? "yes" : "no")}"))
                   + $", Ghostscript {(ToolLocator.GhostscriptPath(tools) is not null ? "yes" : "no")}";
        });

        try { Directory.Delete(work, true); } catch { }
        report.AppendLine(failed == 0 ? "All checks passed." : $"{failed} check(s) failed.");
        var text = report.ToString();
        Console.Write(text);
        try { File.WriteAllText(Path.Combine(Path.GetTempPath(), "UniversalConverter-selftest.txt"), text); } catch { }
        return failed == 0 ? 0 : 1;
    }

    private sealed class SkipTest(string message) : Exception(message);
}
