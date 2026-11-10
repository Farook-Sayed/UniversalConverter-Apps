using System.Text.Json;

namespace UniversalConverter.Core;

/// <summary>What the user chose in Settings. Saved as a small JSON file in the user's AppData folder.</summary>
public sealed class AppSettings
{
    public string OutputFolder { get; set; } =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), "Universal Converter");
    public string OllamaModel { get; set; } = "";
    public int RepairAttempts { get; set; } = 1;
    public PageOutput PageOutput { get; set; } = PageOutput.Folder;

    private static string FilePath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Universal Converter", "settings.json");

    private static readonly JsonSerializerOptions Options = new() { WriteIndented = true };

    /// <summary>The settings in use. Changing them and calling Save keeps them for the next start.</summary>
    public static AppSettings Current { get; set; } = Load();

    public static AppSettings Load()
    {
        try
        {
            if (File.Exists(FilePath))
                return JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(FilePath), Options) ?? new AppSettings();
        }
        catch { /* a damaged file means the defaults are used */ }
        return new AppSettings();
    }

    public void Save()
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
            File.WriteAllText(FilePath, JsonSerializer.Serialize(this, Options));
        }
        catch { /* settings that cannot be saved are used until the app closes */ }
    }
}

/// <summary>A local model for code translation. It runs through Ollama, on this PC.</summary>
public sealed record CodeModel(string Name, string Title, string Detail, string Download, int MemoryGb)
{
    public bool IsInstalled => CodeModels.IsInstalled(Name);
    public bool FitsThisPc => CodeModels.PhysicalMemoryGb >= MemoryGb;
}

public static class CodeModels
{
    public const string DefaultName = "qwen2.5-coder:7b";

    public static readonly IReadOnlyList<CodeModel> Catalog =
    [
        new("qwen2.5-coder:1.5b", "Qwen 2.5 Coder 1.5B", "The smallest and fastest. Good for short, simple files.", "About 1 GB", 8),
        new("qwen2.5-coder:3b", "Qwen 2.5 Coder 3B", "Small and quick, with reasonable results.", "About 2 GB", 8),
        new("qwen2.5-coder:7b", "Qwen 2.5 Coder 7B", "A balance of speed and quality. The default, and a good choice for most files.", "About 4.7 GB", 16),
        new("qwen2.5-coder:14b", "Qwen 2.5 Coder 14B", "More careful with larger files. Slower.", "About 9 GB", 24),
        new("deepseek-coder-v2:16b", "DeepSeek Coder V2 16B", "A large model with broad coverage of programming languages. Slower.", "About 9 GB", 32),
        new("codellama:7b", "Code Llama 7B", "An older, widely used model. Good for common languages.", "About 4 GB", 16),
    ];

    /// <summary>The model the app uses, chosen in Settings.</summary>
    public static string Selected => string.IsNullOrWhiteSpace(AppSettings.Current.OllamaModel) ? DefaultName : AppSettings.Current.OllamaModel;

    /// <summary>Where Ollama keeps its models. OLLAMA_MODELS moves them.</summary>
    private static string ModelsFolder =>
        Environment.GetEnvironmentVariable("OLLAMA_MODELS") is { Length: > 0 } custom
            ? custom
            : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".ollama", "models");

    /// <summary>Where Ollama keeps a model's manifest. Its presence means the model is downloaded.</summary>
    public static string ManifestPath(string name)
    {
        var parts = name.Split(':', 2);
        var model = parts[0];
        var tag = parts.Length > 1 ? parts[1] : "latest";
        var location = model.Contains('/') ? model : "library/" + model;
        return Path.Combine(ModelsFolder, "manifests", "registry.ollama.ai", location.Replace('/', Path.DirectorySeparatorChar), tag);
    }

    public static bool IsInstalled(string name) => File.Exists(ManifestPath(name));

    public static int PhysicalMemoryGb => (int)(GC.GetGCMemoryInfo().TotalAvailableMemoryBytes / 1_073_741_824L);
}
