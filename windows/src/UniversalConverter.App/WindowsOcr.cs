#if WINDOWS
using System.Runtime.InteropServices.WindowsRuntime;
using UniversalConverter.Core;
using Windows.Globalization;
using Windows.Graphics.Imaging;
using Windows.Media.Ocr;
using Windows.Storage.Streams;

namespace UniversalConverter.App;

/// <summary>Text recognition from Windows itself (Windows.Media.Ocr). It runs on this PC and needs no download. It reads
/// the languages of the user's profile. More languages come from Windows Settings, under Time and language.</summary>
public sealed class WindowsOcr : IOcrEngine
{
    public static bool IsSupported
    {
        get { try { return CreateEngine() is not null; } catch { return false; } }
    }

    private static OcrEngine? CreateEngine() =>
        OcrEngine.TryCreateFromUserProfileLanguages() ?? OcrEngine.TryCreateFromLanguage(new Language("en-US"));

    public async Task<string> RecognizeAsync(byte[] png, CancellationToken cancellation)
    {
        var engine = CreateEngine() ?? throw ConversionException.Unsupported("Windows has no text recognition language installed. Add one in Windows Settings, under Time and language.");
        using var stream = new InMemoryRandomAccessStream();
        await stream.WriteAsync(png.AsBuffer());
        stream.Seek(0);
        var decoder = await BitmapDecoder.CreateAsync(stream);
        // The recogniser refuses pictures larger than its limit, so a larger one is scaled down.
        uint limit = OcrEngine.MaxImageDimension;
        var transform = new BitmapTransform();
        double scale = Math.Min(1.0, (double)limit / Math.Max(decoder.PixelWidth, decoder.PixelHeight));
        if (scale < 1.0)
        {
            transform.ScaledWidth = (uint)(decoder.PixelWidth * scale);
            transform.ScaledHeight = (uint)(decoder.PixelHeight * scale);
        }
        using var bitmap = await decoder.GetSoftwareBitmapAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied, transform,
                                                                ExifOrientationMode.IgnoreExifOrientation, ColorManagementMode.DoNotColorManage);
        cancellation.ThrowIfCancellationRequested();
        var result = await engine.RecognizeAsync(bitmap);
        return string.Join("\n", result.Lines.Select(l => l.Text));
    }
}
#endif
