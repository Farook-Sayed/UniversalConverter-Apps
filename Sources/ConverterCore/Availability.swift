import Foundation

extension ToolLocator {
    /// Whether the tool an engine needs is installed and ready. Built-in conversions need nothing.
    public func isAvailable(_ engine: Engine) -> Bool {
        switch engine {
        case .builtin: return true
        case .ffmpeg: return locate(["ffmpeg"]) != nil
        case .imagemagick: return locate(["magick", "convert"]) != nil
        case .libreoffice: return locate(["soffice"]) != nil
        case .pandoc: return locate(["pandoc"]) != nil
        case .ollama:
            // Code translation needs both the server program and the chosen model.
            return locate(["ollama"]) != nil && FileManager.default.fileExists(atPath: ToolFeature.codeModelManifest.path)
        case .archiver: return locate(["7z", "7zz"]) != nil
        case .fonttools: return Converter.fontPython(tools: self) != nil
        case .poppler: return locate(["pdftotext"]) != nil && locate(["pdftoppm"]) != nil
        case .ghostscript: return locate(["gs"]) != nil
        case .assimp: return locate(["assimp"]) != nil
        case .calibre: return locate(["ebook-convert"]) != nil
        }
    }
}
