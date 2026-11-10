using System.Reflection;
using ImageMagick;
using ImageMagick.Formats;
using Microsoft.ML.OnnxRuntime;
using Microsoft.ML.OnnxRuntime.Tensors;

namespace UniversalConverter.Core;

public enum CompressionPreset { Original, Low, Medium, High, Custom }
public enum ResizeMode { Original, Percent, LongestSide }
public enum ImageCrop { Off, Square, FourByThree, SixteenByNine, ThreeByFour }
public enum ImageEffect { Off, Sketch }

/// <summary>A rectangle as fractions of a picture (0..1), so the same rectangle works at any size.</summary>
public readonly record struct FractionRect(double X, double Y, double Width, double Height)
{
    public double Right => X + Width;
    public double Bottom => Y + Height;
}

public static class ImageCropExtensions
{
    /// <summary>Width divided by height. Null when there is no crop.</summary>
    public static double? Ratio(this ImageCrop crop) => crop switch
    {
        ImageCrop.Square => 1.0,
        ImageCrop.FourByThree => 4.0 / 3,
        ImageCrop.SixteenByNine => 16.0 / 9,
        ImageCrop.ThreeByFour => 3.0 / 4,
        _ => null,
    };

    /// <summary>The largest rectangle of this shape, centred, as fractions of a picture with the given width-to-height ratio.</summary>
    public static FractionRect? FractionRect(this ImageCrop crop, double aspect)
    {
        if (crop.Ratio() is not { } ratio || aspect <= 0) return null;
        if (aspect > ratio)
        {
            var width = ratio / aspect;
            return new FractionRect((1 - width) / 2, 0, width, 1);
        }
        var height = aspect / ratio;
        return new FractionRect(0, (1 - height) / 2, 1, height);
    }

    public static string Title(this ImageCrop crop) => crop switch
    {
        ImageCrop.Off => "None", ImageCrop.Square => "Square", ImageCrop.FourByThree => "4:3",
        ImageCrop.SixteenByNine => "16:9", _ => "3:4",
    };
}

/// <summary>What the user changed about a picture: size, crop, background, style and compression.</summary>
public sealed record ImageAdjustments
{
    public CompressionPreset Compression { get; init; } = CompressionPreset.Original;
    public long CustomBytes { get; init; }
    public ResizeMode Resize { get; init; } = ResizeMode.Original;
    public int ResizeValue { get; init; }
    public ImageCrop Crop { get; init; } = ImageCrop.Off;
    /// <summary>A crop the user drew. When set, it replaces the crop shape.</summary>
    public FractionRect? CropRect { get; init; }
    public bool RemoveBackground { get; init; }
    public ImageEffect Effect { get; init; } = ImageEffect.Off;
    /// <summary>Keep the camera, date and location details. Turn off before sharing a picture publicly.</summary>
    public bool KeepMetadata { get; init; } = true;

    public static readonly ImageAdjustments Unchanged = new();

    public bool ChangesPicture => Resize != ResizeMode.Original || Crop != ImageCrop.Off || CropRect is not null
                                  || RemoveBackground || Effect != ImageEffect.Off;

    /// <summary>The encoder quality for a preset, from 1 (smallest) to 100 (best).</summary>
    public int Quality => Compression switch
    {
        CompressionPreset.Low => 85, CompressionPreset.Medium => 65, CompressionPreset.High => 40, _ => 97,
    };

    /// <summary>The size after resizing, in pixels. Never larger than the picture.</summary>
    public (int Width, int Height) SizeFor(int width, int height)
    {
        static (int, int) Scaled(int w, int h, double f) => (Math.Max(1, (int)Math.Round(w * f)), Math.Max(1, (int)Math.Round(h * f)));
        switch (Resize)
        {
            case ResizeMode.Percent:
                return Scaled(width, height, Math.Clamp(ResizeValue, 1, 100) / 100.0);
            case ResizeMode.LongestSide:
                int longest = Math.Max(width, height);
                if (ResizeValue <= 0 || ResizeValue >= longest) return (width, height);
                return Scaled(width, height, (double)ResizeValue / longest);
            default:
                return (width, height);
        }
    }
}

public sealed record RenderedImage(byte[] Data, List<string> Notes);

/// <summary>Reads, changes and writes pictures with Magick.NET. Everything runs on this PC.</summary>
public static class ImageProcessing
{
    /// <summary>Picture formats whose size is shaped by a quality setting. The others keep every detail.</summary>
    public static readonly IReadOnlySet<string> LossyTargets = new HashSet<string> { "jpg", "webp", "avif" };
    /// <summary>Formats that cannot hold transparency, so a picture is put on white before saving.</summary>
    public static readonly IReadOnlySet<string> FlattenedTargets = new HashSet<string> { "jpg", "bmp", "pdf" };

    private static MagickFormat? FormatFor(string id) => id switch
    {
        "png" => MagickFormat.Png, "jpg" => MagickFormat.Jpeg, "tiff" => MagickFormat.Tiff, "gif" => MagickFormat.Gif,
        "bmp" => MagickFormat.Bmp, "webp" => MagickFormat.WebP, "avif" => MagickFormat.Avif, "pdf" => MagickFormat.Pdf,
        _ => null,
    };

    // MARK: Reading

    /// <summary>The main picture with its rotation applied. Camera RAW files fall back to the preview inside them.</summary>
    public static MagickImage Load(string path, int? maxSide = null)
    {
        var ext = FileNames.EffectiveExtension(path);
        var settings = new MagickReadSettings { FrameIndex = 0, FrameCount = 1 };
        if (ext == "svg") settings.Density = new Density(300);
        MagickImage image;
        try
        {
            image = new MagickImage(path, settings);
        }
        catch (MagickException) when (FormatCatalog.RawFormatForExtension(ext) is not null || FormatCatalog.RawFormats.Contains(ext))
        {
            image = LoadRawPreview(path);
        }
        catch (MagickException ex)
        {
            throw ConversionException.Unsupported($"This picture could not be read. {FirstLine(ex.Message)}");
        }
        image.AutoOrient();
        FixExifOrientation(image);
        if (maxSide is int limit && Math.Max(image.Width, image.Height) > limit)
            image.Resize(new MagickGeometry((uint)limit, (uint)limit));
        return image;
    }

    /// <summary>A small copy of the picture, rotated, for the crop editor.</summary>
    public static MagickImage Preview(string path, int maxSide)
    {
        var image = Load(path, maxSide);
        image.ResetPage();
        return image;
    }

    private static string FirstLine(string text) => text.Split('\n')[0].Trim();

    private static void FixExifOrientation(MagickImage image)
    {
        try { image.GetExifProfile()?.SetValue(ExifTag.Orientation, (ushort)1); } catch { /* no details to fix */ }
    }

    /// <summary>The largest JPEG inside a camera RAW file. Nearly every RAW format keeps one as its preview.</summary>
    private static MagickImage LoadRawPreview(string path)
    {
        var data = File.ReadAllBytes(path);
        (int start, int length) best = (-1, 0);
        for (int i = 0; i + 3 < data.Length; i++)
        {
            if (data[i] != 0xFF || data[i + 1] != 0xD8 || data[i + 2] != 0xFF) continue;
            int end = i + 3;
            // The image ends at the next FFD9 that is followed by another marker or the end of the file.
            while (end + 1 < data.Length && !(data[end] == 0xFF && data[end + 1] == 0xD9)) end++;
            int length = Math.Min(end + 2, data.Length) - i;
            if (length > best.length) best = (i, length);
            i = end;
        }
        if (best.start < 0 || best.length < 20_000)
            throw ConversionException.Unsupported("This camera RAW file could not be read. Windows may need the camera's codec, or the camera is not supported yet.");
        try { return new MagickImage(data.AsSpan(best.start, best.length)); }
        catch (MagickException) { throw ConversionException.Unsupported("This camera RAW file could not be read."); }
    }

    // MARK: Changing the picture

    /// <summary>Crops to a rectangle given as fractions of the picture.</summary>
    public static bool Crop(MagickImage image, FractionRect fractions)
    {
        double width = image.Width, height = image.Height;
        int x = (int)Math.Round(Math.Clamp(fractions.X, 0, 1) * width), y = (int)Math.Round(Math.Clamp(fractions.Y, 0, 1) * height);
        int w = (int)Math.Round(fractions.Width * width), h = (int)Math.Round(fractions.Height * height);
        w = Math.Min(w, (int)width - x);
        h = Math.Min(h, (int)height - y);
        if (w < 1 || h < 1) return false;
        image.Crop(new MagickGeometry(x, y, (uint)w, (uint)h));
        image.ResetPage();
        return true;
    }

    private static void Flatten(MagickImage image) => image.ColorAlpha(MagickColors.White);

    /// <summary>A pencil drawing on white paper. A blurred negative is colour-dodged over the grey picture, so flat
    /// areas wash out to white and only the edges and shading stay dark.</summary>
    public static void Sketch(MagickImage image)
    {
        Flatten(image);
        image.Grayscale();
        using var negative = (MagickImage)image.Clone();
        negative.Negate();
        negative.Blur(0, Math.Max(2.0, Math.Max(image.Width, image.Height) / 120.0));
        image.Composite(negative, CompositeOperator.ColorDodge);
        image.GammaCorrect(1 / 1.6);
        Flatten(image);
    }

    // MARK: Writing

    private static byte[]? Encode(MagickImage image, MagickFormat format, int? quality, bool keepMetadata)
    {
        try
        {
            using var copy = (MagickImage)image.Clone();
            copy.Format = format;
            if (quality is int q) copy.Quality = (uint)q;
            if (!keepMetadata) StripDetails(copy);
            if (format == MagickFormat.Avif) copy.Settings.SetDefine(MagickFormat.Avif, "speed", "8");
            if (format == MagickFormat.Png) copy.Settings.SetDefine(MagickFormat.Png, "compression-level", "9");
            return copy.ToByteArray();
        }
        catch (MagickException) { return null; }
    }

    private static void StripDetails(MagickImage image)
    {
        foreach (var name in new[] { "exif", "iptc", "xmp", "8bim" }) image.RemoveProfile(name);
    }

    /// <summary>Applies the adjustments in order (crop, size, background, style, flattening) and encodes the result.</summary>
    public static RenderedImage Render(string path, string targetId, ImageAdjustments adjustments, CancellationToken cancellation = default)
    {
        var format = FormatFor(targetId) ?? throw ConversionException.Unsupported($"Universal Converter cannot write {targetId} pictures.");
        static ConversionException Failed(string step) => ConversionException.Unsupported($"The picture could not be {step}. Try a different format.");
        var notes = new List<string>();

        using var image = Load(path);
        // GIF frames and TIFF pages cannot all be kept, because the result holds one picture.
        var sourceExt = FileNames.EffectiveExtension(path);
        if (sourceExt is "gif" or "tif" or "tiff")
        {
            try { using var all = new MagickImageCollection(path); if (all.Count > 1) notes.Add($"This file holds {all.Count} frames or pages. Only the first is saved."); }
            catch (MagickException) { /* the count is only a note */ }
        }

        cancellation.ThrowIfCancellationRequested();
        if (adjustments.CropRect is { } box)
        {
            if (!Crop(image, box)) throw Failed("cropped");
        }
        else if (adjustments.Crop != ImageCrop.Off)
        {
            var shape = adjustments.Crop.FractionRect((double)image.Width / image.Height);
            if (shape is null || !Crop(image, shape.Value)) throw Failed("cropped");
        }
        var (w, h) = adjustments.SizeFor((int)image.Width, (int)image.Height);
        if (w != image.Width || h != image.Height) image.Resize(new MagickGeometry((uint)w, (uint)h) { IgnoreAspectRatio = true });

        cancellation.ThrowIfCancellationRequested();
        if (adjustments.RemoveBackground)
        {
            if (BackgroundRemover.Apply(image))
            {
                if (FlattenedTargets.Contains(targetId) && adjustments.Effect == ImageEffect.Off)
                    notes.Add($"{targetId.ToUpperInvariant()} has no transparency, so the removed background is white. Choose PNG to keep it transparent.");
            }
            else notes.Add("No clear subject was found, so the background was not removed.");
        }

        cancellation.ThrowIfCancellationRequested();
        if (adjustments.Effect == ImageEffect.Sketch) Sketch(image);
        if (FlattenedTargets.Contains(targetId)) Flatten(image);
        cancellation.ThrowIfCancellationRequested();

        bool lossy = LossyTargets.Contains(targetId);
        if (adjustments.Compression != CompressionPreset.Custom)
        {
            var data = Encode(image, format, lossy ? adjustments.Quality : null, adjustments.KeepMetadata)
                       ?? throw Failed($"saved as {targetId.ToUpperInvariant()}");
            return new RenderedImage(data, notes);
        }
        long goal = adjustments.CustomBytes;
        var fitted = Fit(image, format, lossy, goal, adjustments.KeepMetadata, cancellation);
        if (fitted.Length > goal)
            notes.Add($"Could not get the file to {FileSize.Text(goal)}. The smallest version is {FileSize.Text(fitted.Length)}.");
        return new RenderedImage(fitted, notes);
    }

    /// <summary>The best encoding that fits the goal, found by lowering the quality and then the size. If nothing fits,
    /// the smallest encoding made is returned.</summary>
    public static byte[] Fit(MagickImage image, MagickFormat format, bool lossy, long goal, bool keepMetadata, CancellationToken cancellation)
    {
        byte[]? smallest = null;
        void Keep(byte[] data) { if (smallest is null || data.Length < smallest.Length) smallest = data; }

        if (lossy)
        {
            // A generous goal is met at once, with no search.
            if (Encode(image, format, 97, keepMetadata) is { } best)
            {
                if (best.Length <= goal) return best;
                Keep(best);
            }
            // Eight steps narrow the quality to about one percent. Within a tenth of the goal is close enough.
            int low = 5, high = 97;
            byte[]? fitting = null;
            for (int i = 0; i < 8; i++)
            {
                cancellation.ThrowIfCancellationRequested();
                int middle = (low + high) / 2;
                if (Encode(image, format, middle, keepMetadata) is not { } data) break;
                Keep(data);
                if (data.Length <= goal)
                {
                    fitting = data;
                    low = middle;
                    if (data.Length >= goal - goal / 10) break;
                }
                else high = middle;
            }
            if (fitting is not null) return fitting;
        }
        else if (Encode(image, format, null, keepMetadata) is { } whole)
        {
            if (whole.Length <= goal) return whole;
            Keep(whole);
        }

        // Quality alone is not enough, so the picture gets smaller too. Lossy formats keep a medium quality.
        foreach (int percent in new[] { 85, 70, 55, 40, 30, 20, 10 })
        {
            cancellation.ThrowIfCancellationRequested();
            using var shrunk = (MagickImage)image.Clone();
            shrunk.Resize(new Percentage(percent));
            if (Encode(shrunk, format, lossy ? 60 : null, keepMetadata) is not { } data) continue;
            Keep(data);
            if (data.Length <= goal) return data;
        }
        return smallest ?? throw ConversionException.Unsupported("The picture could not be saved.");
    }
}

/// <summary>Keeps the main subject of a picture and makes the rest transparent. The model is U2-Net (small), which is
/// part of the app, so nothing is downloaded and nothing leaves the PC.</summary>
public static class BackgroundRemover
{
    private const int Side = 320;
    private static readonly Lazy<byte[]> Model = new(() =>
    {
        using var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("u2netp.onnx")
                           ?? throw ConversionException.Unsupported("The background model is missing from the app.");
        using var memory = new MemoryStream();
        stream.CopyTo(memory);
        return memory.ToArray();
    });
    private static InferenceSession? _session;
    private static readonly object Gate = new();

    /// <summary>The foreground as a grey picture the size of the input: white is subject, black is background.</summary>
    public static byte[] Mask(MagickImage image)
    {
        using var small = (MagickImage)image.Clone();
        // The model was trained on pictures on a plain background, so transparency goes to white first.
        small.ColorAlpha(MagickColors.White);
        small.Resize(new MagickGeometry(Side, Side) { IgnoreAspectRatio = true });
        // One byte per colour value. A picture held with 16 bits per value would give twice the bytes.
        small.Depth = 8;
        var rgb = small.ToByteArray(MagickFormat.Rgb);
        var input = new DenseTensor<float>([1, 3, Side, Side]);
        float[] mean = [0.485f, 0.456f, 0.406f], std = [0.229f, 0.224f, 0.225f];
        // The model expects each value divided by the picture's largest, then shifted by the training averages.
        float max = 1;
        for (int i = 0; i < rgb.Length; i++) max = Math.Max(max, rgb[i]);
        for (int y = 0; y < Side; y++)
            for (int x = 0; x < Side; x++)
                for (int c = 0; c < 3; c++)
                    input[0, c, y, x] = (rgb[(y * Side + x) * 3 + c] / max - mean[c]) / std[c];

        float[] result;
        lock (Gate)
        {
            _session ??= new InferenceSession(Model.Value);
            using var outputs = _session.Run([NamedOnnxValue.CreateFromTensor(_session.InputMetadata.Keys.First(), input)]);
            result = outputs.First().AsEnumerable<float>().ToArray();
        }
        float low = result.Min(), high = result.Max();
        var grey = new byte[Side * Side];
        for (int i = 0; i < grey.Length; i++) grey[i] = (byte)Math.Round(255 * (result[i] - low) / Math.Max(high - low, 1e-6f));
        using var mask = new MagickImage(grey, new PixelReadSettings(Side, Side, StorageType.Char, "R"));
        mask.Resize(new MagickGeometry(image.Width, image.Height) { IgnoreAspectRatio = true });
        mask.Depth = 8;
        return mask.ToByteArray(MagickFormat.Gray);
    }

    /// <summary>Makes everything but the subject transparent. False when no clear subject is found.</summary>
    public static bool Apply(MagickImage image)
    {
        var mask = Mask(image);
        // A picture that is almost all subject or all background has no cut-out to make.
        double share = mask.Count(v => v > 127) / (double)mask.Length;
        if (share < 0.01 || share > 0.995) return false;
        using var alpha = new MagickImage(mask, new PixelReadSettings(image.Width, image.Height, StorageType.Char, "R"));
        image.HasAlpha = true;
        image.Composite(alpha, CompositeOperator.CopyAlpha);
        return true;
    }
}

/// <summary>Reads text from a picture. The Windows app supplies the system's text recognition.</summary>
public interface IOcrEngine
{
    /// <summary>The text in a PNG picture, in reading order. Empty when there is none.</summary>
    Task<string> RecognizeAsync(byte[] png, CancellationToken cancellation);
}

public static class Ocr
{
    /// <summary>Set once at start-up by the app. Null when text recognition is not available.</summary>
    public static IOcrEngine? Engine { get; set; }
}
