using CommunityToolkit.Mvvm.ComponentModel;
using UniversalConverter.Core;

namespace UniversalConverter.App.ViewModels;

public enum SizeChoice { Original, ThreeQuarters, Half, Quarter, Pixels }

/// <summary>What the user changed about one picture. Typed sizes are kept as text, because they can be wrong.</summary>
public partial class ImageEditsViewModel : ObservableObject
{
    public static readonly string[] CompressionTitles = ["Original", "Low", "Medium", "High", "Custom"];
    public static readonly string[] SizeTitles = ["Original", "75%", "50%", "25%", "Pixels"];
    public static readonly string[] CropTitles = ["None", "Square", "4:3", "16:9", "3:4"];
    public static readonly string[] EffectTitles = ["None", "Sketch"];

    [ObservableProperty] private int _compressionIndex;
    [ObservableProperty] private string _customSize = "";
    [ObservableProperty] private int _sizeIndex;
    [ObservableProperty] private string _customPixels = "";
    [ObservableProperty] private int _cropIndex;
    /// <summary>A box the user drew, as fractions of the picture. It replaces the crop shape when set.</summary>
    [ObservableProperty] private FractionRect? _cropRect;
    [ObservableProperty] private bool _removeBackground;
    [ObservableProperty] private int _effectIndex;
    [ObservableProperty] private bool _keepMetadata = true;

    /// <summary>Raised after any change, so the row can refresh its summary and its Convert button.</summary>
    public event Action? Changed;

    public CompressionPreset Compression => (CompressionPreset)CompressionIndex;
    public SizeChoice Size => (SizeChoice)SizeIndex;
    public ImageCrop Crop => (ImageCrop)CropIndex;
    public ImageEffect Effect => (ImageEffect)EffectIndex;
    public bool IsCustomCompression => Compression == CompressionPreset.Custom;
    public bool IsPixelSize => Size == SizeChoice.Pixels;
    public bool CustomSizeInvalid => IsCustomCompression && FileSize.Parse(CustomSize) is null;
    public bool PixelsInvalid => IsPixelSize && !(int.TryParse(CustomPixels.Trim(), out var px) && px > 0);
    public bool HasCrop => CropRect is not null || Crop != ImageCrop.Off;
    /// <summary>True when something typed is missing or not understood, so the conversion cannot start.</summary>
    public bool IsInvalid => CustomSizeInvalid || PixelsInvalid;

    partial void OnCompressionIndexChanged(int value) => Touch(nameof(IsCustomCompression), nameof(CustomSizeInvalid));
    partial void OnCustomSizeChanged(string value) => Touch(nameof(CustomSizeInvalid));
    partial void OnSizeIndexChanged(int value) => Touch(nameof(IsPixelSize), nameof(PixelsInvalid));
    partial void OnCustomPixelsChanged(string value) => Touch(nameof(PixelsInvalid));
    partial void OnCropIndexChanged(int value) => Touch(nameof(HasCrop));
    partial void OnCropRectChanged(FractionRect? value) => Touch(nameof(HasCrop));
    partial void OnRemoveBackgroundChanged(bool value) => Touch();
    partial void OnEffectIndexChanged(int value) => Touch();
    partial void OnKeepMetadataChanged(bool value) => Touch();

    private void Touch(params string[] names)
    {
        foreach (var name in names) OnPropertyChanged(name);
        OnPropertyChanged(nameof(IsInvalid));
        Changed?.Invoke();
    }

    /// <summary>Choosing a shape replaces any box the user drew.</summary>
    public void ChooseShape(int index)
    {
        CropRect = null;
        CropIndex = index;
    }

    /// <summary>Drawing a box replaces any shape. A box dragged back over the whole picture is no crop at all.</summary>
    public void DrawBox(FractionRect box)
    {
        bool whole = box.Width > 0.999 && box.Height > 0.999;
        CropIndex = 0;
        CropRect = whole ? null : box;
    }

    public void ResetCrop()
    {
        CropIndex = 0;
        CropRect = null;
    }

    /// <summary>The adjustments to run. Null when a typed size or pixel count is missing or not understood.</summary>
    public ImageAdjustments? ToAdjustments(bool lossy)
    {
        if (IsInvalid) return null;
        var compression = lossy || Compression == CompressionPreset.Custom ? Compression : CompressionPreset.Original;
        return new ImageAdjustments
        {
            Compression = compression,
            CustomBytes = compression == CompressionPreset.Custom ? FileSize.Parse(CustomSize) ?? 0 : 0,
            Resize = Size switch { SizeChoice.Original => ResizeMode.Original, SizeChoice.Pixels => ResizeMode.LongestSide, _ => ResizeMode.Percent },
            ResizeValue = Size switch
            {
                SizeChoice.ThreeQuarters => 75, SizeChoice.Half => 50, SizeChoice.Quarter => 25,
                SizeChoice.Pixels => int.Parse(CustomPixels.Trim()), _ => 0,
            },
            Crop = Crop,
            CropRect = CropRect,
            RemoveBackground = RemoveBackground,
            Effect = Effect,
            KeepMetadata = KeepMetadata,
        };
    }

    /// <summary>A short description for the row, such as "50%, square crop, sketch". Empty when nothing is changed.</summary>
    public string Summary(bool lossy)
    {
        var parts = new List<string>();
        var shown = lossy || Compression == CompressionPreset.Custom ? Compression : CompressionPreset.Original;
        if (shown == CompressionPreset.Custom) parts.Add($"under {CustomSize}");
        else if (shown != CompressionPreset.Original) parts.Add(CompressionTitles[(int)shown].ToLowerInvariant() + " compression");
        if (Size != SizeChoice.Original) parts.Add(Size == SizeChoice.Pixels ? $"longest side {CustomPixels} px" : SizeTitles[SizeIndex]);
        if (CropRect is not null) parts.Add("custom crop");
        else if (Crop != ImageCrop.Off) parts.Add(CropTitles[CropIndex].ToLowerInvariant() + " crop");
        if (RemoveBackground) parts.Add("background removed");
        if (Effect != ImageEffect.Off) parts.Add(EffectTitles[EffectIndex].ToLowerInvariant());
        if (!KeepMetadata) parts.Add("no camera details");
        var text = string.Join(", ", parts);
        return text.Length == 0 ? "" : char.ToUpperInvariant(text[0]) + text[1..];
    }
}
