import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import ConverterCore

/// Pictures: sizes, crops, compression to a size, background removal, sketches, HEIC and camera RAW.
final class ImageTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fc-image-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// A picture with a gradient, a bright disc (a clear subject), and fine noise, so it is large until compressed.
    private func makePicture(width: Int, height: Int, named name: String, type: UTType = .png) throws -> URL {
        let space = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let gradient = CGGradient(colorsSpace: space, colors: [
                  CGColor(red: 0.1, green: 0.2, blue: 0.6, alpha: 1),
                  CGColor(red: 0.9, green: 0.5, blue: 0.1, alpha: 1),
              ] as CFArray, locations: [0, 1]) else { throw XCTSkip("could not draw a picture") }
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        context.setFillColor(CGColor(red: 1, green: 1, blue: 0.9, alpha: 1))
        context.fillEllipse(in: CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2))
        var seed: UInt32 = 7
        func next() -> CGFloat {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return CGFloat(seed >> 8) / CGFloat(1 << 24)
        }
        for _ in 0..<(width * height / 64) {
            context.setFillColor(CGColor(red: next(), green: next(), blue: next(), alpha: 1))
            context.fill(CGRect(x: next() * CGFloat(width), y: next() * CGFloat(height), width: 2, height: 2))
        }
        guard let image = context.makeImage() else { throw XCTSkip("could not make a picture") }
        let url = dir.appendingPathComponent(name)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw XCTSkip("\(type.identifier) cannot be written on this Mac")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw XCTSkip("could not save the picture") }
        return url
    }

    private func dimensions(_ data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (width, height)
    }

    private func render(_ url: URL, to targetID: String, _ adjustments: ImageAdjustments) throws -> RenderedImage {
        try ImageProcessing.render(from: url, targetID: targetID, adjustments: adjustments)
    }

    // MARK: Sizes and crops

    func testResizeScalesAndNeverEnlarges() {
        XCTAssertEqual(ImageResize.percent(50).size(width: 1200, height: 800).width, 600)
        XCTAssertEqual(ImageResize.percent(50).size(width: 1200, height: 800).height, 400)
        XCTAssertEqual(ImageResize.longestSide(600).size(width: 1200, height: 800).width, 600)
        XCTAssertEqual(ImageResize.longestSide(600).size(width: 1200, height: 800).height, 400)
        XCTAssertEqual(ImageResize.longestSide(5000).size(width: 1200, height: 800).width, 1200, "never enlarges")
        XCTAssertEqual(ImageResize.percent(0).size(width: 1200, height: 800).width, 12, "a percentage is at least 1%")
    }

    func testCropsAreCentredAndKeepTheShape() {
        XCTAssertEqual(ImageCrop.square.rect(width: 4000, height: 3000), CGRect(x: 500, y: 0, width: 3000, height: 3000))
        XCTAssertEqual(ImageCrop.fourByThree.rect(width: 4000, height: 3000), CGRect(x: 0, y: 0, width: 4000, height: 3000))
        XCTAssertEqual(ImageCrop.sixteenByNine.rect(width: 4000, height: 3000), CGRect(x: 0, y: 375, width: 4000, height: 2250))
        XCTAssertEqual(ImageCrop.threeByFour.rect(width: 4000, height: 3000), CGRect(x: 875, y: 0, width: 2250, height: 3000))
        XCTAssertEqual(ImageCrop.off.rect(width: 40, height: 30), CGRect(x: 0, y: 0, width: 40, height: 30))
    }

    func testHalfSizeGivesHalfTheSize() throws {
        let url = try makePicture(width: 1200, height: 800, named: "half.png")
        let result = try render(url, to: "png", ImageAdjustments(resize: .percent(50)))
        XCTAssertEqual(dimensions(result.data)?.width, 600)
        XCTAssertEqual(dimensions(result.data)?.height, 400)
    }

    func testSquareCropKeepsTheCentre() throws {
        let url = try makePicture(width: 1200, height: 800, named: "crop.png")
        let result = try render(url, to: "png", ImageAdjustments(crop: .square))
        XCTAssertEqual(dimensions(result.data)?.width, 800)
        XCTAssertEqual(dimensions(result.data)?.height, 800)
    }

    // MARK: Compression to a size

    func testJPEGAtACustomSizeFitsOrSaysSo() throws {
        let url = try makePicture(width: 1200, height: 800, named: "size.png")
        let goal = 60_000
        let result = try render(url, to: "jpg", ImageAdjustments(compression: .custom(bytes: goal)))
        if result.data.count > goal {
            XCTAssertTrue(result.notes.contains { $0.contains("Could not get") }, "the user should be told")
        } else {
            XCTAssertLessThanOrEqual(result.data.count, goal)
        }
        XCTAssertNotNil(dimensions(result.data), "the result is still a readable picture")
    }

    func testPNGAtACustomSizeIsMadeSmallerByResizing() throws {
        let url = try makePicture(width: 1200, height: 800, named: "small.png")
        let full = try render(url, to: "png", ImageAdjustments())
        let goal = full.data.count / 3
        let result = try render(url, to: "png", ImageAdjustments(compression: .custom(bytes: goal)))
        XCTAssertLessThan(result.data.count, full.data.count, "PNG cannot lose quality, so the size must come down")
    }

    func testLowerCompressionKeepsMoreBytes() throws {
        let url = try makePicture(width: 1200, height: 800, named: "levels.jpg", type: .jpeg)
        let high = try render(url, to: "jpg", ImageAdjustments(compression: .high))
        let original = try render(url, to: "jpg", ImageAdjustments(compression: .original))
        XCTAssertLessThan(high.data.count, original.data.count)
    }

    // MARK: Effects and background

    func testSketchChangesThePictureAndKeepsItsSize() throws {
        let url = try makePicture(width: 800, height: 600, named: "sketch.png")
        let plain = try render(url, to: "png", ImageAdjustments())
        let drawn = try render(url, to: "png", ImageAdjustments(effect: .sketch))
        XCTAssertNotEqual(plain.data, drawn.data)
        XCTAssertEqual(dimensions(drawn.data)?.width, 800)
        XCTAssertEqual(dimensions(drawn.data)?.height, 600)
    }

    func testBackgroundRemovalGivesTransparencyOrSaysThereIsNoSubject() throws {
        let url = try makePicture(width: 800, height: 600, named: "cutout.png")
        let result = try render(url, to: "png", ImageAdjustments(removeBackground: true))
        if result.notes.contains(where: { $0.contains("No clear subject") }) { return }
        let source = try XCTUnwrap(CGImageSourceCreateWithData(result.data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertNotEqual(image.alphaInfo, .none, "the background should be transparent")
    }

    func testJPEGHasNoTransparencySoBackgroundIsFilledWithWhite() throws {
        let url = try makePicture(width: 400, height: 300, named: "white.png")
        let result = try render(url, to: "jpg", ImageAdjustments())
        let source = try XCTUnwrap(CGImageSourceCreateWithData(result.data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertTrue([CGImageAlphaInfo.none, .noneSkipLast, .noneSkipFirst].contains(image.alphaInfo),
                      "a JPEG has no alpha channel")
    }

    // MARK: HEIC

    /// Writes a HEIC copy of a picture. Skipped when this Mac cannot write HEIC.
    private func makeHEIC(from png: URL, named name: String) throws -> URL {
        let image = try ImageProcessing.load(png)
        let url = dir.appendingPathComponent(name)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.heic.identifier as CFString, 1, nil) else {
            throw XCTSkip("HEIC cannot be written on this Mac")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw XCTSkip("could not write HEIC") }
        return url
    }

    func testHEICPictureConvertsToPNGAndJPGWithoutImageMagick() async throws {
        let png = try makePicture(width: 640, height: 480, named: "source.png")
        let heic = try makeHEIC(from: png, named: "photo.heic")
        let detected = try FileDetector().detect(url: heic)
        XCTAssertEqual(detected.formatID, "heic")
        XCTAssertEqual(detected.category, .image)

        for targetID in ["png", "jpg"] {
            let route = try XCTUnwrap(FormatCatalog.targets(for: detected, available: { _ in true })
                .first { $0.id == targetID })
            XCTAssertEqual(route.engine, .imageio, "HEIC should not need ImageMagick")
            let result = try await Converter().convert(ConversionRequest(
                input: detected, route: route, outputDirectory: dir.appendingPathComponent("out-\(targetID)")))
            XCTAssertEqual(dimensions(try Data(contentsOf: result.outputURL))?.width, 640, targetID)
        }
    }

    // MARK: Camera RAW

    /// The first bytes of a TIFF-based RAW file, then the brand marker that Canon uses at byte 8.
    private func tiffHeader(_ extra: String = "") -> Data {
        var data = Data([0x49, 0x49, 0x2A, 0x00, 0x10, 0x00, 0x00, 0x00])
        data.append(Data(extra.utf8))
        data.append(Data(repeating: 0, count: 64))
        return data
    }

    func testCameraRAWFilesAreIdentifiedByTheirBrand() {
        let detector = FileDetector()
        XCTAssertEqual(detector.detect(head: tiffHeader("CR"), url: URL(fileURLWithPath: "/tmp/IMG_0001.CR2")).formatID, "cr2")
        XCTAssertEqual(detector.detect(head: tiffHeader(), url: URL(fileURLWithPath: "/tmp/shot.nef")).formatID, "nef")
        XCTAssertEqual(detector.detect(head: tiffHeader(), url: URL(fileURLWithPath: "/tmp/scan.dng")).formatID, "dng")
        XCTAssertEqual(detector.detect(head: tiffHeader(), url: URL(fileURLWithPath: "/tmp/scan.tif")).formatID, "tiff",
                       "an ordinary TIFF stays a TIFF")
        XCTAssertEqual(detector.detect(head: Data("FUJIFILMCCD-RAW 0201".utf8), url: URL(fileURLWithPath: "/tmp/a.raf")).formatID, "raf")
        XCTAssertEqual(detector.detect(head: Data("IIRO".utf8) + Data(repeating: 0, count: 60),
                                       url: URL(fileURLWithPath: "/tmp/a.orf")).formatID, "orf")
        XCTAssertEqual(detector.detect(head: Data([0x49, 0x49, 0x55, 0x00]) + Data(repeating: 0, count: 60),
                                       url: URL(fileURLWithPath: "/tmp/a.rw2")).formatID, "rw2")
        let cr3 = Data([0, 0, 0, 0x18]) + Data("ftyp".utf8) + Data("crx ".utf8) + Data(repeating: 0, count: 60)
        XCTAssertEqual(detector.detect(head: cr3, url: URL(fileURLWithPath: "/tmp/a.cr3")).formatID, "cr3")
    }

    func testCameraRAWFilesOfferPNGAndJPGWithoutImageMagick() {
        let raw = FileDetector().detect(head: tiffHeader("CR"), url: URL(fileURLWithPath: "/tmp/IMG_0001.cr2"))
        let targets = FormatCatalog.targets(for: raw, available: { _ in true })
        XCTAssertEqual(targets.first { $0.id == "jpg" }?.engine, .imageio)
        XCTAssertEqual(targets.first { $0.id == "png" }?.engine, .imageio)
    }

    /// Converts a real RAW file. Set FC_RAW_SAMPLE to a RAW file on this Mac to run it.
    func testRealCameraRAWFileConvertsToJPG() async throws {
        guard let path = ProcessInfo.processInfo.environment["FC_RAW_SAMPLE"] else {
            throw XCTSkip("Set FC_RAW_SAMPLE to a camera RAW file to run this test")
        }
        let input = URL(fileURLWithPath: path)
        let detected = try FileDetector().detect(url: input)
        XCTAssertEqual(detected.category, .image)
        let route = try XCTUnwrap(FormatCatalog.targets(for: detected, available: { _ in true }).first { $0.id == "jpg" })
        let result = try await Converter().convert(ConversionRequest(
            input: detected, route: route, outputDirectory: dir.appendingPathComponent("raw")))
        XCTAssertGreaterThan(dimensions(try Data(contentsOf: result.outputURL))?.width ?? 0, 0)
    }

    // MARK: Helpers for the checks below

    private func write(_ image: CGImage, named name: String, type: UTType = .jpeg,
                       properties: [CFString: Any] = [:]) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func picture(_ data: Data) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    private func properties(_ data: Data) throws -> [CFString: Any] {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    }

    /// The picture shrunk to a few pixels, as red, green, blue and alpha bytes from the top-left.
    private func thumbnail(_ image: CGImage, side: Int = 8) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                                  bytesPerRow: side * 4, space: space,
                                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        }
        return bytes
    }

    private func brightness(_ image: CGImage) throws -> Double {
        let bytes = try thumbnail(image)
        let colours = stride(from: 0, to: bytes.count, by: 4).map { Int(bytes[$0]) + Int(bytes[$0 + 1]) + Int(bytes[$0 + 2]) }
        return Double(colours.reduce(0, +)) / Double(colours.count) / 3
    }

    private func convert(_ url: URL, to targetID: String, _ adjustments: ImageAdjustments,
                         into folder: URL? = nil) async throws -> ConversionResult {
        let detected = try FileDetector().detect(url: url)
        let route = try XCTUnwrap(FormatCatalog.targets(for: detected, available: { _ in true })
            .first { $0.id == targetID && $0.engine == .imageio })
        return try await Converter().convert(ConversionRequest(
            input: detected, route: route, outputDirectory: folder ?? dir.appendingPathComponent("out"),
            imageAdjustments: adjustments))
    }

    private let flowerPhoto = URL(fileURLWithPath: "/System/Library/Templates/Data/Library/User Pictures/Flowers/Dahlia.heic")

    // MARK: Sketch and background on real pictures

    /// The first sketch filter gave harsh black noise on real photos, and transparent paper.
    func testSketchIsALightDrawingOnSolidPaper() throws {
        let url = try makePicture(width: 800, height: 600, named: "paper.png")
        let plain = try picture(render(url, to: "png", ImageAdjustments()).data)
        let drawn = try picture(render(url, to: "png", ImageAdjustments(effect: .sketch)).data)
        XCTAssertTrue([CGImageAlphaInfo.none, .noneSkipLast, .noneSkipFirst].contains(drawn.alphaInfo), "the paper is solid")
        XCTAssertGreaterThan(try brightness(drawn), try brightness(plain), "a sketch is mostly white paper")
    }

    func testBackgroundRemovalOnARealPhotoLeavesATransparentBackground() throws {
        guard FileManager.default.fileExists(atPath: flowerPhoto.path) else { throw XCTSkip("no sample photo") }
        let result = try render(flowerPhoto, to: "png", ImageAdjustments(removeBackground: true))
        guard !result.notes.contains(where: { $0.contains("No clear subject") }) else {
            throw XCTSkip("Vision found no subject on this Mac")
        }
        let bytes = try thumbnail(try picture(result.data), side: 32)
        let alphas = stride(from: 3, to: bytes.count, by: 4).map { bytes[$0] }
        XCTAssertTrue(alphas.contains(0), "some of the picture should be fully transparent")
        XCTAssertTrue(alphas.contains(255), "the subject should stay solid")

        let jpeg = try render(flowerPhoto, to: "jpg", ImageAdjustments(removeBackground: true))
        XCTAssertTrue(jpeg.notes.contains { $0.contains("no transparency") }, "the user should be told it became white")
    }

    // MARK: Metadata and rotation

    /// Every conversion used to lose the date a photo was taken and where.
    func testCameraDetailsAreKeptUnlessTheUserRemovesThem() throws {
        let base = try ImageProcessing.load(try makePicture(width: 300, height: 200, named: "base.png"))
        let url = try write(base, named: "camera.jpg", properties: [
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2024:05:01 10:00:00"],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 12.5, kCGImagePropertyGPSLatitudeRef: "N"],
        ])
        let kept = try properties(render(url, to: "jpg", ImageAdjustments(compression: .medium)).data)
        let exif = kept[kCGImagePropertyExifDictionary] as? [CFString: Any]
        XCTAssertEqual(exif?[kCGImagePropertyExifDateTimeOriginal] as? String, "2024:05:01 10:00:00")
        XCTAssertNotNil(kept[kCGImagePropertyGPSDictionary])

        let removed = try properties(render(url, to: "jpg", ImageAdjustments(compression: .medium, keepMetadata: false)).data)
        XCTAssertNil(removed[kCGImagePropertyGPSDictionary], "the location must be gone")
        XCTAssertNil((removed[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifDateTimeOriginal])
    }

    /// The rotation goes into the pixels, so the result must not also say "rotate me".
    func testARotatedPhotoComesOutUprightAndIsNotRotatedTwice() throws {
        let base = try ImageProcessing.load(try makePicture(width: 400, height: 300, named: "turn.png"))
        let url = try write(base, named: "turned.jpg", properties: [kCGImagePropertyOrientation: 6])
        let result = try render(url, to: "jpg", ImageAdjustments(compression: .medium))
        XCTAssertEqual(dimensions(result.data)?.width, 300)
        XCTAssertEqual(dimensions(result.data)?.height, 400)
        XCTAssertEqual(try properties(result.data)[kCGImagePropertyOrientation] as? Int ?? 1, 1)
    }

    /// Phone photos and camera RAW files use wide colour. Resizing used to squeeze them into plain RGB.
    func testWideColourStaysWideAfterResizing() throws {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        let context = try XCTUnwrap(CGContext(data: nil, width: 200, height: 200, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(colorSpace: space, components: [1, 0, 0, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        let url = try write(try XCTUnwrap(context.makeImage()), named: "wide.png", type: .png)
        let result = try render(url, to: "png", ImageAdjustments(resize: .percent(50)))
        XCTAssertEqual(try picture(result.data).colorSpace?.name, CGColorSpace.displayP3)
    }

    // MARK: Staying in the same format

    /// The main use of compression, "this website wants a JPEG under 200 KB", was not possible for a JPEG.
    func testAPictureCanStayInItsOwnFormat() throws {
        for (name, id) in [("a.jpg", "jpg"), ("a.png", "png")] {
            let url = try makePicture(width: 50, height: 50, named: name, type: id == "jpg" ? .jpeg : .png)
            let targets = FormatCatalog.targets(for: try FileDetector().detect(url: url), available: { _ in true })
            let own = try XCTUnwrap(targets.first { $0.id == id }, id)
            XCTAssertEqual(own.engine, .imageio)
            XCTAssertTrue(own.target.label.contains("adjusted"))
            XCTAssertNotEqual(targets.first?.id, id, "the usual first choice stays another format")
        }
        let gif = try makePicture(width: 50, height: 50, named: "a.gif", type: .gif)
        let targets = FormatCatalog.targets(for: try FileDetector().detect(url: gif), available: { _ in true })
        XCTAssertNil(targets.first { $0.id == "gif" }, "saving a GIF again would lose its animation")
    }

    func testCompressingAJPEGToASizeKeepsItAJPEGAndLeavesTheOriginal() async throws {
        let url = try makePicture(width: 1200, height: 800, named: "upload.jpg", type: .jpeg)
        let before = try Data(contentsOf: url)
        let goal = before.count / 3
        let result = try await convert(url, to: "jpg", ImageAdjustments(compression: .custom(bytes: goal)), into: dir)
        let after = try Data(contentsOf: result.outputURL)
        XCTAssertEqual(result.outputURL.lastPathComponent, "upload (2).jpg", "the original is never overwritten")
        XCTAssertLessThanOrEqual(after.count, goal)
        XCTAssertEqual(try FileDetector().detect(url: result.outputURL).formatID, "jpg")
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testNothingToDoGivesAnExactCopy() async throws {
        let url = try makePicture(width: 300, height: 200, named: "same.jpg", type: .jpeg)
        let result = try await convert(url, to: "jpg", .unchanged)
        XCTAssertEqual(try Data(contentsOf: result.outputURL), try Data(contentsOf: url))
        XCTAssertTrue(result.notes.contains { $0.contains("exact copy") })
    }

    func testAFileAlreadyUnderTheGoalIsNotSavedAgain() async throws {
        let url = try makePicture(width: 300, height: 200, named: "fits.jpg", type: .jpeg)
        let result = try await convert(url, to: "jpg", ImageAdjustments(compression: .custom(bytes: 50_000_000)))
        XCTAssertEqual(try Data(contentsOf: result.outputURL), try Data(contentsOf: url))
        XCTAssertTrue(result.notes.contains { $0.contains("already") })
    }

    func testCompressionThatWouldGrowTheFileKeepsTheOriginal() async throws {
        let base = try ImageProcessing.load(try makePicture(width: 600, height: 400, named: "rough.png"))
        let url = try write(base, named: "rough.jpg", properties: [kCGImageDestinationLossyCompressionQuality: 0.05])
        let result = try await convert(url, to: "jpg", ImageAdjustments(compression: .low))
        XCTAssertEqual(try Data(contentsOf: result.outputURL), try Data(contentsOf: url))
        XCTAssertTrue(result.notes.contains { $0.contains("did not make this file smaller") })
    }

    // MARK: Formats

    func testEveryBuiltInFormatIsReallyWritten() throws {
        let url = try makePicture(width: 200, height: 150, named: "all.png")
        for target in FormatCatalog.imageIOTargets.sorted() {
            let result = try render(url, to: target, ImageAdjustments())
            let found = FileDetector().detect(head: result.data.prefix(4096), url: URL(fileURLWithPath: "/tmp/x.\(target)"))
            XCTAssertEqual(found.formatID, target)
            XCTAssertEqual(dimensions(result.data)?.width, 200, target)
        }
    }

    func testOnlyTheFirstFrameIsSavedAndTheUserIsTold() throws {
        let base = try ImageProcessing.load(try makePicture(width: 60, height: 60, named: "frame.png"))
        let url = dir.appendingPathComponent("moving.gif")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, 2, nil))
        CGImageDestinationAddImage(destination, base, nil)
        CGImageDestinationAddImage(destination, base, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let result = try render(url, to: "png", ImageAdjustments())
        XCTAssertTrue(result.notes.contains { $0.contains("2 frames") })
    }

    func testLessCommonRAWNamesAndHEIFBrandsAreRecognised() {
        let detector = FileDetector()
        XCTAssertEqual(detector.detect(head: tiffHeader(), url: URL(fileURLWithPath: "/tmp/a.nrw")).formatID, "nef")
        XCTAssertEqual(detector.detect(head: tiffHeader(), url: URL(fileURLWithPath: "/tmp/a.srf")).formatID, "arw")
        let burst = Data([0, 0, 0, 0x18]) + Data("ftyp".utf8) + Data("hevc".utf8) + Data(repeating: 0, count: 60)
        XCTAssertEqual(detector.detect(head: burst, url: URL(fileURLWithPath: "/tmp/a.heic")).formatID, "heic")
    }

    /// A real DNG, built by hand and read by the macOS RAW decoder: red rises to the right and green rises downward.
    private func makeDNG(width: Int, height: Int, named name: String) throws -> URL {
        var pixels = Data(capacity: width * height * 6)
        func put16(_ value: Int) {
            pixels.append(UInt8(value & 0xFF))
            pixels.append(UInt8(value >> 8))
        }
        for y in 0..<height {
            for x in 0..<width {
                put16(x * 65535 / width)
                put16(y * 65535 / height)
                put16(32768)
            }
        }
        func bytes<T: FixedWidthInteger>(_ value: T) -> [UInt8] { withUnsafeBytes(of: value.littleEndian) { Array($0) } }
        let count = 20, start = 8 + 2 + count * 12 + 4
        var blob = Data()
        func add(_ data: Data) -> UInt32 {
            let offset = UInt32(start + blob.count)
            blob.append(data)
            if blob.count % 2 == 1 { blob.append(0) }
            return offset
        }
        var entries = Data()
        func entry(_ tag: UInt16, _ type: UInt16, _ items: Int, _ value: UInt32) {
            entries.append(contentsOf: bytes(tag) + bytes(type) + bytes(UInt32(items)) + bytes(value))
        }
        func text(_ tag: UInt16, _ string: String) {
            let data = Data(string.utf8) + Data([0])
            entry(tag, 2, data.count, add(data))
        }
        entry(254, 4, 1, 0)
        entry(256, 4, 1, UInt32(width))
        entry(257, 4, 1, UInt32(height))
        entry(258, 3, 3, add(Data(bytes(UInt16(16)) + bytes(UInt16(16)) + bytes(UInt16(16)))))
        entry(259, 3, 1, 1)
        entry(262, 3, 1, 34892)   // linear raw
        text(271, "Test")
        text(272, "Synthetic")
        let matrix = [32406, -15372, -4986, -9689, 18758, 415, 557, -2040, 10570].flatMap { bytes(Int32($0)) + bytes(Int32(10000)) }
        let matrixOffset = add(Data(matrix))
        let neutralOffset = add(Data((0..<3).flatMap { _ in bytes(UInt32(1)) + bytes(UInt32(1)) }))
        let whiteOffset = add(Data((0..<3).flatMap { _ in bytes(UInt32(65535)) }))
        let modelData = Data("Test Synthetic".utf8) + Data([0])
        let modelOffset = add(modelData)
        let stripOffset = add(pixels)
        entry(273, 4, 1, stripOffset)
        entry(274, 3, 1, 1)
        entry(277, 3, 1, 3)
        entry(278, 4, 1, UInt32(height))
        entry(279, 4, 1, UInt32(pixels.count))
        entry(284, 3, 1, 1)
        entries.append(contentsOf: bytes(UInt16(50706)) + bytes(UInt16(1)) + bytes(UInt32(4)) + [1, 4, 0, 0])
        entries.append(contentsOf: bytes(UInt16(50707)) + bytes(UInt16(1)) + bytes(UInt32(4)) + [1, 1, 0, 0])
        entry(50708, 2, modelData.count, modelOffset)
        entry(50717, 4, 3, whiteOffset)
        entry(50721, 10, 9, matrixOffset)
        entry(50728, 5, 3, neutralOffset)

        var file = Data([0x49, 0x49, 0x2A, 0x00] + bytes(UInt32(8)) + bytes(UInt16(count)))
        file.append(entries)
        file.append(contentsOf: bytes(UInt32(0)))
        file.append(blob)
        let url = dir.appendingPathComponent(name)
        try file.write(to: url)
        return url
    }

    func testACameraRAWFileIsDecodedToRealPixels() async throws {
        let url = try makeDNG(width: 300, height: 200, named: "shot.dng")
        XCTAssertEqual(try FileDetector().detect(url: url).formatID, "dng")
        let result = try await convert(url, to: "jpg", ImageAdjustments(compression: .low))
        let data = try Data(contentsOf: result.outputURL)
        XCTAssertEqual(dimensions(data)?.width, 300)
        XCTAssertEqual(dimensions(data)?.height, 200)
        let side = 8
        let bytes = try thumbnail(try picture(data), side: side)
        func at(_ x: Int, _ y: Int, _ channel: Int) -> Int { Int(bytes[(y * side + x) * 4 + channel]) }
        XCTAssertGreaterThan(at(side - 1, 0, 0), at(0, 0, 0) + 40, "red should rise to the right")
        XCTAssertGreaterThan(at(0, side - 1, 1), at(0, 0, 1) + 40, "green should rise downward")
    }

    // MARK: Cancelling

    func testCancellingStopsAPictureThatIsBeingWorkedOn() async throws {
        let url = try makePicture(width: 3000, height: 2000, named: "long.png")
        let detected = try FileDetector().detect(url: url)
        let route = try XCTUnwrap(FormatCatalog.targets(for: detected, available: { _ in true }).first { $0.id == "jpg" })
        let request = ConversionRequest(input: detected, route: route, outputDirectory: dir.appendingPathComponent("out"),
                                        imageAdjustments: ImageAdjustments(compression: .custom(bytes: 1000)))
        let task = Task { try await Converter().convert(request) }
        try await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()
        do {
            _ = try await task.value
            throw XCTSkip("the work finished before it could be cancelled")
        } catch is CancellationError {
            // The expected result.
        }
    }

    // MARK: Previews

    /// Writes sketch, background and crop previews of a real HEIC photo. Set FC_IMAGE_PREVIEW to a folder to run it.
    func testWritePreviewsOfARealPhoto() throws {
        guard let folder = ProcessInfo.processInfo.environment["FC_IMAGE_PREVIEW"] else {
            throw XCTSkip("Set FC_IMAGE_PREVIEW to a folder to write previews")
        }
        let env = ProcessInfo.processInfo.environment
        let photo = URL(fileURLWithPath: env["FC_IMAGE_PREVIEW_SOURCE"] ?? "/System/Library/Desktop Pictures/Mac Blue.heic")
        guard FileManager.default.fileExists(atPath: photo.path) else { throw XCTSkip("no sample photo") }
        let out = URL(fileURLWithPath: folder, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let cases: [(String, ImageAdjustments)] = [
            ("plain.png", ImageAdjustments()),
            ("sketch.png", ImageAdjustments(effect: .sketch)),
            ("cutout.png", ImageAdjustments(removeBackground: true)),
            ("square.png", ImageAdjustments(crop: .square)),
            ("half.jpg", ImageAdjustments(compression: .high, resize: .percent(50))),
        ]
        for (name, adjustments) in cases {
            let rendered = try render(photo, to: name.hasSuffix("jpg") ? "jpg" : "png", adjustments)
            try rendered.data.write(to: out.appendingPathComponent(name))
            print("PREVIEW \(name): \(rendered.data.count) bytes, notes: \(rendered.notes)")
        }
    }
}
