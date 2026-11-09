import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Vision

/// How much a JPEG or HEIC image is compressed. The presets set the encoder's quality. PNG is lossless,
/// so the presets do not change it.
public enum ImageCompression: Sendable, Equatable {
    case original, low, medium, high
    /// Aim for a size in bytes. The quality is lowered, then the picture is made smaller, until the file fits.
    case custom(bytes: Int)

    /// The encoder quality for a preset, from 0 (smallest) to 1 (best).
    var quality: Double {
        switch self {
        case .original, .custom: return 0.97
        case .low: return 0.85
        case .medium: return 0.65
        case .high: return 0.4
        }
    }
}

/// The size of the result in pixels.
public enum ImageResize: Sendable, Equatable {
    case original
    /// Each side scaled to this percentage.
    case percent(Int)
    /// The longest side set to this many pixels. The other side follows the shape. Never enlarges.
    case longestSide(Int)

    public func size(width: Int, height: Int) -> (width: Int, height: Int) {
        switch self {
        case .original:
            return (width, height)
        case .percent(let percent):
            return Self.scaled(width, height, by: Double(min(max(percent, 1), 100)) / 100)
        case .longestSide(let pixels):
            let longest = max(width, height)
            guard pixels > 0, pixels < longest else { return (width, height) }
            return Self.scaled(width, height, by: Double(pixels) / Double(longest))
        }
    }

    private static func scaled(_ width: Int, _ height: Int, by factor: Double) -> (width: Int, height: Int) {
        (max(1, Int((Double(width) * factor).rounded())), max(1, Int((Double(height) * factor).rounded())))
    }
}

/// A crop from the centre of the picture to a fixed shape.
public enum ImageCrop: String, CaseIterable, Sendable {
    case off, square, fourByThree, sixteenByNine, threeByFour

    /// Width divided by height. Nil when there is no crop.
    public var ratio: Double? {
        switch self {
        case .off: return nil
        case .square: return 1
        case .fourByThree: return 4.0 / 3.0
        case .sixteenByNine: return 16.0 / 9.0
        case .threeByFour: return 3.0 / 4.0
        }
    }

    /// The largest rectangle of this shape, centred in a picture of the given size, in pixels.
    public func rect(width: Int, height: Int) -> CGRect {
        let full = CGRect(x: 0, y: 0, width: width, height: height)
        guard let ratio, width > 0, height > 0 else { return full }
        let w = Double(width), h = Double(height)
        let wider = w / h > ratio
        let cropWidth = wider ? h * ratio : w
        let cropHeight = wider ? h : w / ratio
        return CGRect(x: ((w - cropWidth) / 2).rounded(), y: ((h - cropHeight) / 2).rounded(),
                      width: cropWidth.rounded(), height: cropHeight.rounded())
    }
}

/// A style applied to the whole picture.
public enum ImageEffect: String, CaseIterable, Sendable {
    case off, sketch
}

/// Everything the user can change about an image besides its format.
public struct ImageAdjustments: Sendable, Equatable {
    public var compression: ImageCompression
    public var resize: ImageResize
    public var crop: ImageCrop
    public var removeBackground: Bool
    public var effect: ImageEffect
    /// Keep the camera, date and location details. Turn off before sharing a picture publicly.
    public var keepMetadata: Bool

    public init(compression: ImageCompression = .original, resize: ImageResize = .original,
                crop: ImageCrop = .off, removeBackground: Bool = false, effect: ImageEffect = .off,
                keepMetadata: Bool = true) {
        self.compression = compression
        self.resize = resize
        self.crop = crop
        self.removeBackground = removeBackground
        self.effect = effect
        self.keepMetadata = keepMetadata
    }

    /// No change to the picture. The image is only converted.
    public static let unchanged = ImageAdjustments()

    public var changesPicture: Bool {
        resize != .original || crop != .off || removeBackground || effect != .off
    }
}

/// An encoded image, and any notes about how it was made.
public struct RenderedImage: Sendable {
    public let data: Data
    public let notes: [String]
}

/// Image work with the frameworks that ship with macOS. ImageIO reads and writes (including HEIC and camera RAW),
/// Core Graphics resizes and crops, Core Image draws the sketch, and Vision finds the subject for background removal.
public enum ImageProcessing {
    /// Formats whose size can be traded for quality.
    public static let lossyTargets: Set<String> = ["jpg", "heic"]
    /// Formats with no transparency. Any transparent area is filled with white before saving.
    public static let flattenedTargets: Set<String> = ["jpg", "bmp"]

    static func type(for targetID: String) -> UTType? {
        switch targetID {
        case "png": return .png
        case "jpg": return .jpeg
        case "heic": return .heic
        case "tiff": return .tiff
        case "gif": return .gif
        case "bmp": return .bmp
        default: return nil
        }
    }

    // MARK: Reading

    private static func openSource(_ url: URL) throws -> CGImageSource {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ConversionError.unsupported("This picture could not be read.")
        }
        return source
    }

    /// The main picture with its rotation applied. A HEIC file can hold several, and the main one is not always first.
    private static func decode(_ source: CGImageSource) throws -> CGImage {
        let index = CGImageSourceGetPrimaryImageIndex(source)
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        let longest = max(properties?[kCGImagePropertyPixelWidth] as? Int ?? 0,
                          properties?[kCGImagePropertyPixelHeight] as? Int ?? 0)
        // A thumbnail as large as the whole picture applies the rotation and keeps every pixel.
        if longest > 0 {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: longest,
            ]
            if let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) {
                return image
            }
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else {
            throw ConversionError.unsupported("This picture could not be decoded. If it is a camera RAW file, macOS may not support this camera yet.")
        }
        return image
    }

    /// Reads a picture with its rotation applied. ImageIO also decodes HEIC and camera RAW files.
    public static func load(_ url: URL) throws -> CGImage {
        try decode(openSource(url))
    }

    /// The camera, date and location details to copy to the result. The rotation is already part of the
    /// pixels, so the orientation becomes "upright". Sizes are left out because they may have changed.
    private static func metadata(of source: CGImageSource) -> [CFString: Any] {
        let index = CGImageSourceGetPrimaryImageIndex(source)
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] else {
            return [:]
        }
        var kept: [CFString: Any] = [kCGImagePropertyOrientation: 1]
        for key in [kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary] {
            if let value = properties[key] { kept[key] = value }
        }
        if var exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif.removeValue(forKey: kCGImagePropertyExifPixelXDimension)
            exif.removeValue(forKey: kCGImagePropertyExifPixelYDimension)
            kept[kCGImagePropertyExifDictionary] = exif
        }
        if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            kept[kCGImagePropertyTIFFDictionary] = tiff
        }
        return kept
    }

    // MARK: Changing the picture

    /// A drawing surface in the picture's own colours, so a wide-gamut photo from a phone stays wide-gamut.
    private static func canvas(width: Int, height: Int, like image: CGImage, bitmapInfo: UInt32) -> CGContext? {
        let spaces = [image.colorSpace, CGColorSpace(name: CGColorSpace.sRGB)].compactMap { $0 }
        for space in spaces where space.model == .rgb {
            if let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                       space: space, bitmapInfo: bitmapInfo) {
                return context
            }
        }
        return nil
    }

    public static func crop(_ image: CGImage, to shape: ImageCrop) -> CGImage? {
        image.cropping(to: shape.rect(width: image.width, height: image.height))
    }

    public static func resize(_ image: CGImage, to size: (width: Int, height: Int)) -> CGImage? {
        guard let context = canvas(width: size.width, height: size.height, like: image,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        return context.makeImage()
    }

    /// The picture on a white background, for results that cannot or should not hold transparency.
    public static func flattened(_ image: CGImage) -> CGImage? {
        guard let context = canvas(width: image.width, height: image.height, like: image,
                                   bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(rect)
        context.draw(image, in: rect)
        return context.makeImage()
    }

    /// Keeps the main subject and makes everything else transparent. Nil when Vision finds no subject.
    public static func removeBackground(_ image: CGImage) -> CGImage? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil,
              let observation = request.results?.first, !observation.allInstances.isEmpty,
              let mask = try? observation.generateScaledMaskForImage(forInstances: observation.allInstances,
                                                                     from: handler) else { return nil }
        let input = CIImage(cgImage: image)
        let extent = input.extent
        guard let filter = CIFilter(name: "CIBlendWithMask") else { return nil }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(CIImage(color: .clear).cropped(to: extent), forKey: kCIInputBackgroundImageKey)
        filter.setValue(CIImage(cvPixelBuffer: mask), forKey: kCIInputMaskImageKey)
        guard let output = filter.outputImage else { return nil }
        let space = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        return CIContext().createCGImage(output, from: extent, format: .RGBA8, colorSpace: space)
    }

    /// A pencil drawing on white paper. This is the classic method: a blurred negative is colour-dodged over
    /// the grey picture, so flat areas wash out to white and only the edges and shading stay dark.
    public static func sketch(_ image: CGImage) -> CGImage? {
        guard let paper = flattened(image) else { return nil }
        let input = CIImage(cgImage: paper)
        let extent = input.extent
        let grey = input.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
        let radius = max(2, Double(max(image.width, image.height)) / 120)
        let blurredNegative = grey.applyingFilter("CIColorInvert")
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
            .cropped(to: extent)
        let drawing = blurredNegative
            .applyingFilter("CIColorDodgeBlendMode", parameters: [kCIInputBackgroundImageKey: grey])
            .applyingFilter("CIGammaAdjust", parameters: ["inputPower": 1.6])
            .cropped(to: extent)
        // The blend is meant for the values as stored, not for linear light, so colour management stays off.
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        return context.createCGImage(drawing, from: extent, format: .RGBA8, colorSpace: space).flatMap(flattened)
    }

    // MARK: Writing

    /// Encodes the picture with the given quality and metadata.
    public static func encode(_ image: CGImage, type: UTType, quality: Double?,
                              metadata: [CFString: Any] = [:]) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else {
            return nil
        }
        var options = metadata
        if let quality { options[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    /// Applies the adjustments in order (crop, size, background, style, flattening) and encodes the result.
    public static func render(from url: URL, targetID: String, adjustments: ImageAdjustments) throws -> RenderedImage {
        guard let type = type(for: targetID) else {
            throw ConversionError.unsupported("Universal Converter cannot write \(targetID) pictures.")
        }
        func failed(_ step: String) -> ConversionError {
            .unsupported("The picture could not be \(step). Try a different format.")
        }
        var notes: [String] = []
        let source = try openSource(url)
        var image = try decode(source)
        let details = adjustments.keepMetadata ? metadata(of: source) : [:]

        // GIF frames and TIFF pages cannot all be kept, because the result holds one picture.
        let frames = CGImageSourceGetCount(source)
        if frames > 1, let kind = CGImageSourceGetType(source) as String?,
           [UTType.gif.identifier, UTType.tiff.identifier].contains(kind) {
            notes.append("This file holds \(frames) frames or pages. Only the first is saved.")
        }

        try Task.checkCancellation()
        if adjustments.crop != .off {
            guard let cropped = crop(image, to: adjustments.crop) else { throw failed("cropped") }
            image = cropped
        }
        let size = adjustments.resize.size(width: image.width, height: image.height)
        if size.width != image.width || size.height != image.height {
            guard let resized = resize(image, to: size) else { throw failed("resized") }
            image = resized
        }
        try Task.checkCancellation()
        if adjustments.removeBackground {
            if let cutOut = removeBackground(image) {
                image = cutOut
                if flattenedTargets.contains(targetID), adjustments.effect == .off {
                    notes.append("\(targetID.uppercased()) has no transparency, so the removed background is white. Choose PNG to keep it transparent.")
                }
            } else {
                notes.append("No clear subject was found, so the background was not removed.")
            }
        }
        try Task.checkCancellation()
        if adjustments.effect == .sketch {
            guard let drawn = sketch(image) else { throw failed("drawn as a sketch") }
            image = drawn
        }
        if flattenedTargets.contains(targetID) {
            guard let flat = flattened(image) else { throw failed("saved without transparency") }
            image = flat
        }
        try Task.checkCancellation()

        let lossy = lossyTargets.contains(targetID)
        guard case .custom(let goal) = adjustments.compression else {
            let quality = lossy ? adjustments.compression.quality : nil
            guard let data = encode(image, type: type, quality: quality, metadata: details) else {
                throw failed("saved as \(targetID.uppercased())")
            }
            return RenderedImage(data: data, notes: notes)
        }
        let data = try fit(image, type: type, lossy: lossy, goal: goal, metadata: details)
        if data.count > goal {
            notes.append("Could not get the file to \(FileSize.text(goal)). The smallest version is \(FileSize.text(data.count)).")
        }
        return RenderedImage(data: data, notes: notes)
    }

    /// The best encoding that fits the goal, found by lowering the quality and then the size. If nothing
    /// fits, the smallest encoding made is returned.
    static func fit(_ image: CGImage, type: UTType, lossy: Bool, goal: Int, metadata: [CFString: Any]) throws -> Data {
        var smallest: Data?
        func keep(_ data: Data) {
            if smallest == nil || data.count < smallest!.count { smallest = data }
        }
        if lossy {
            // A generous goal is met at once, with no search.
            if let best = encode(image, type: type, quality: 0.97, metadata: metadata) {
                if best.count <= goal { return best }
                keep(best)
            }
            // Eight steps narrow the quality to about one percent. Within a tenth of the goal is close enough.
            var low = 0.05, high = 0.97
            var fitting: Data?
            for _ in 0..<8 {
                try Task.checkCancellation()
                let middle = (low + high) / 2
                guard let data = encode(image, type: type, quality: middle, metadata: metadata) else { break }
                keep(data)
                if data.count <= goal {
                    fitting = data
                    low = middle
                    if data.count >= goal - goal / 10 { break }
                } else {
                    high = middle
                }
            }
            if let fitting { return fitting }
        } else if let whole = encode(image, type: type, quality: nil, metadata: metadata) {
            if whole.count <= goal { return whole }
            keep(whole)
        }
        // Quality alone is not enough, so the picture gets smaller too. Lossy formats keep a medium quality.
        for percent in [85, 70, 55, 40, 30, 20, 10] {
            try Task.checkCancellation()
            let size = ImageResize.percent(percent).size(width: image.width, height: image.height)
            guard let shrunk = resize(image, to: size),
                  let data = encode(shrunk, type: type, quality: lossy ? 0.6 : nil, metadata: metadata) else { continue }
            keep(data)
            if data.count <= goal { return data }
        }
        guard let result = smallest else {
            throw ConversionError.unsupported("The picture could not be saved.")
        }
        return result
    }
}

extension Converter {
    /// One image conversion with the frameworks that ship with macOS. The work runs off the caller's thread, and
    /// cancelling the conversion cancels it. When a picture stays in its own format and nothing would improve,
    /// the original is kept, because saving a JPEG again only loses quality.
    func runImageIO(input: DetectedFile, target: OutputFormat, adjustments: ImageAdjustments, workDir: URL,
                    log: inout [String], notes: inout [String]) async throws -> URL {
        let output = workDir.appendingPathComponent("out.\(target.fileExtension)")
        log.append("image \(input.url.lastPathComponent) -> \(target.id) (macOS ImageIO)")
        let originalSize = Int(Preflight.fileSize(input.url))
        let onlyCompressing = input.formatID == target.id && !adjustments.changesPicture && adjustments.keepMetadata
        func keepOriginal(_ note: String) throws -> URL {
            notes.append(note)
            try FileManager.default.copyItem(at: input.url, to: output)
            return output
        }

        if onlyCompressing {
            if case .custom(let goal) = adjustments.compression, originalSize <= goal {
                return try keepOriginal("The file is already \(FileSize.text(goal)) or smaller, so it was not changed.")
            }
            if adjustments.compression == .original {
                return try keepOriginal("Nothing was changed, so this is an exact copy. Choose a change under Adjust.")
            }
        }

        let url = input.url
        let targetID = target.id
        let work = Task.detached(priority: .userInitiated) {
            try ImageProcessing.render(from: url, targetID: targetID, adjustments: adjustments)
        }
        let rendered = try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
        notes.append(contentsOf: rendered.notes)
        if onlyCompressing, rendered.data.count >= originalSize {
            return try keepOriginal("Compression did not make this file smaller, so the original was kept.")
        }
        try rendered.data.write(to: output)
        return output
    }
}
