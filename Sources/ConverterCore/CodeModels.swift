import Foundation

/// A local model for code translation. It runs through Ollama, on this Mac. Sizes and memory are rough guides.
public struct CodeModel: Identifiable, Sendable, Hashable {
    /// The name Ollama uses, such as "qwen2.5-coder:7b".
    public let name: String
    public let title: String
    /// What the model is good for, in plain words.
    public let detail: String
    /// Roughly how much to download.
    public let download: String
    /// Memory that works well with this model, in gigabytes.
    public let memoryGB: Int

    public var id: String { name }

    public var isInstalled: Bool {
        FileManager.default.fileExists(atPath: CodeModels.manifestURL(for: name).path)
    }

    /// Whether this Mac has enough memory for the model to run comfortably.
    public var fitsThisMac: Bool {
        CodeModels.physicalMemoryGB >= memoryGB
    }
}

public enum CodeModels {
    /// The key the app stores the chosen model under. Settings uses the same key.
    public static let defaultsKey = "ollamaModel"
    public static let defaultName = "qwen2.5-coder:7b"

    public static let catalog: [CodeModel] = [
        CodeModel(name: "qwen2.5-coder:1.5b", title: "Qwen 2.5 Coder 1.5B",
                  detail: "The smallest and fastest. Good for short, simple files.",
                  download: "About 1 GB", memoryGB: 8),
        CodeModel(name: "qwen2.5-coder:3b", title: "Qwen 2.5 Coder 3B",
                  detail: "Small and quick, with reasonable results.",
                  download: "About 2 GB", memoryGB: 8),
        CodeModel(name: "qwen2.5-coder:7b", title: "Qwen 2.5 Coder 7B",
                  detail: "A balance of speed and quality. The default, and a good choice for most files.",
                  download: "About 4.7 GB", memoryGB: 16),
        CodeModel(name: "qwen2.5-coder:14b", title: "Qwen 2.5 Coder 14B",
                  detail: "More careful with larger files. Slower.",
                  download: "About 9 GB", memoryGB: 24),
        CodeModel(name: "deepseek-coder-v2:16b", title: "DeepSeek Coder V2 16B",
                  detail: "A large model with broad coverage of programming languages. Slower.",
                  download: "About 9 GB", memoryGB: 32),
        CodeModel(name: "codellama:7b", title: "Code Llama 7B",
                  detail: "An older, widely used model. Good for common languages.",
                  download: "About 4 GB", memoryGB: 16),
    ]

    /// The model the app uses, chosen in Settings → Code.
    public static var selected: String {
        let name = UserDefaults.standard.string(forKey: defaultsKey) ?? ""
        return name.isEmpty ? defaultName : name
    }

    /// Where Ollama keeps a model's manifest. Its presence means the model is downloaded.
    /// "qwen2.5-coder:7b" is stored under library/qwen2.5-coder/7b. A name without a tag means "latest".
    public static func manifestURL(for name: String) -> URL {
        let parts = name.split(separator: ":", maxSplits: 1).map(String.init)
        let model = parts.first ?? name
        let tag = parts.count > 1 ? parts[1] : "latest"
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".ollama/models/manifests/registry.ollama.ai/library/\(model)/\(tag)")
    }

    public static var physicalMemoryGB: Int {
        Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)
    }
}
