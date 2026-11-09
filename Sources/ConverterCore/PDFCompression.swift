import Foundation

/// How hard a PDF is compressed. Each preset is a Ghostscript setting that sets the image resolution.
public enum PDFCompression: Sendable, Equatable {
    /// Images keep their full resolution. The file is only rewritten.
    case original
    /// Light compression. Images are kept near 300 dpi.
    case low
    /// Balanced. Images are kept near 150 dpi.
    case medium
    /// The smallest file. Images are reduced to about 72 dpi, so print quality drops.
    case high
    /// Aim for a size in bytes. Stronger settings are tried until the file fits.
    case custom(bytes: Int)

    /// The settings to try, in order. A preset tries one. A custom size tries stronger settings until the file fits.
    var attempts: [[String]] {
        switch self {
        case .original: return [["-dPDFSETTINGS=/prepress"]]
        case .low: return [["-dPDFSETTINGS=/printer"]]
        case .medium: return [["-dPDFSETTINGS=/ebook"]]
        case .high: return [["-dPDFSETTINGS=/screen"]]
        case .custom:
            let presets = [["-dPDFSETTINGS=/printer"], ["-dPDFSETTINGS=/ebook"], ["-dPDFSETTINGS=/screen"]]
            let resolutions = [96, 72, 60, 48, 36].map { dpi in
                ["-dPDFSETTINGS=/screen", "-dDownsampleColorImages=true",
                 "-dColorImageResolution=\(dpi)", "-dGrayImageResolution=\(dpi)", "-dMonoImageResolution=\(dpi)"]
            }
            return presets + resolutions
        }
    }

    /// The size the file must fit in. Nil for the presets.
    public var goalBytes: Int? {
        if case .custom(let bytes) = self { return bytes }
        return nil
    }
}

/// Sizes such as "2 MB", "800 KB" or "1.5mb". A bare number means megabytes. Units are decimal
/// (1 MB = 1,000,000 bytes), the same as Finder uses.
public enum FileSize {
    public static func parse(_ text: String) -> Int? {
        var number = ""
        var unit = ""
        for character in text.lowercased() where character != " " {
            if character.isNumber || character == "." {
                guard unit.isEmpty else { return nil }
                number.append(character)
            } else if character.isLetter {
                unit.append(character)
            } else {
                return nil
            }
        }
        guard let value = Double(number), value > 0 else { return nil }
        let multiplier: Double
        switch unit {
        case "", "m", "mb": multiplier = 1_000_000
        case "k", "kb": multiplier = 1_000
        case "g", "gb": multiplier = 1_000_000_000
        case "b", "bytes", "byte": multiplier = 1
        default: return nil
        }
        let bytes = Int((value * multiplier).rounded())
        return bytes > 0 ? bytes : nil
    }

    /// A size in the style Finder uses, such as "2.1 MB".
    public static func text(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
