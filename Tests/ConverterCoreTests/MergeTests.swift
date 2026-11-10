import XCTest
import PDFKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import ConverterCore

/// Merging several files into one: pictures and PDFs into a PDF, audio, video and text documents.
final class MergeTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("fc-merge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: Helpers

    private func detect(_ url: URL) throws -> DetectedFile { try FileDetector().detect(url: url) }

    /// A solid-colour picture of the given size, as a PNG or JPEG file.
    private func picture(_ name: String, red: CGFloat, green: CGFloat, blue: CGFloat, width: Int = 300, height: Int = 400,
                         type: UTType = .png) throws -> DetectedFile {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let url = dir.appendingPathComponent(name)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return try detect(url)
    }

    private func pdf(_ name: String, pages: Int) throws -> DetectedFile {
        let url = dir.appendingPathComponent(name)
        try TestPDF.text(pages: pages).write(to: url)
        return try detect(url)
    }

    /// The colour at the middle of a page, as red, green and blue from 0 to 1.
    private func centre(of page: PDFPage) throws -> (r: Double, g: Double, b: Double) {
        let size = CGSize(width: 40, height: 40)
        let image = page.thumbnail(of: size, for: .mediaBox)
        let cg = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let context = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg, in: CGRect(x: -CGFloat(cg.width) / 2 + 0.5, y: -CGFloat(cg.height) / 2 + 0.5,
                                    width: CGFloat(cg.width), height: CGFloat(cg.height)))
        let pixel = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        return (Double(pixel[0]) / 255, Double(pixel[1]) / 255, Double(pixel[2]) / 255)
    }

    private func request(_ kind: MergeKind, _ files: [DetectedFile], target: String, name: String = "Merged",
                         pageSize: MergePageSize = .a4, folder: String = "out") -> MergeRequest {
        let group = MergePlanner.groups(for: files).first { $0.kind == kind }
        let format = group?.targets.first { $0.id == target }
            ?? OutputFormat(id: target, label: target, fileExtension: target, engine: .builtin)
        return MergeRequest(kind: kind, inputs: files, target: format, outputDirectory: dir.appendingPathComponent(folder),
                            name: name, pageSize: pageSize)
    }

    /// Merges and opens the result.
    private func mergedPDF(_ request: MergeRequest) async throws -> PDFDocument {
        let result = try await Converter().merge(request)
        return try XCTUnwrap(PDFDocument(url: result.outputURL))
    }

    private func ffmpeg(_ arguments: [String]) async throws {
        guard let tool = ToolLocator().locate(["ffmpeg"]) else { throw XCTSkip("FFmpeg is not installed") }
        let result = try await ProcessRunner.run(tool, arguments: ["-hide_banner", "-loglevel", "error", "-y"] + arguments)
        XCTAssertEqual(result.exitCode, 0, result.stderr)
    }

    private func duration(_ url: URL) async throws -> Double {
        let probe = try XCTUnwrap(ToolLocator().locate(["ffprobe"]))
        let result = try await ProcessRunner.run(probe, arguments: ["-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", url.path])
        return try XCTUnwrap(Double(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    private func probe(_ url: URL, _ entries: String, stream: String) async throws -> String {
        let probe = try XCTUnwrap(ToolLocator().locate(["ffprobe"]))
        let result = try await ProcessRunner.run(probe, arguments: ["-v", "error", "-select_streams", stream, "-show_entries", entries, "-of", "csv=p=0", url.path])
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: What can be merged

    func testTwoPicturesOrPDFsOfferOneMergeIntoAPDF() throws {
        let a = try picture("a.png", red: 1, green: 0, blue: 0), b = try picture("b.jpg", red: 0, green: 1, blue: 0, type: .jpeg)
        let groups = MergePlanner.groups(for: [a, b])
        XCTAssertEqual(groups.map(\.kind), [.pdf])
        XCTAssertEqual(groups[0].title, "2 pictures into one PDF")
        let p = try pdf("p.pdf", pages: 1)
        XCTAssertEqual(MergePlanner.groups(for: [a, p]).first?.title, "1 picture and 1 PDF into one PDF", "pictures and PDFs can be mixed")
        XCTAssertEqual(MergePlanner.groups(for: [p, try pdf("q.pdf", pages: 2)]).first?.title, "2 PDFs into one PDF")
    }

    func testOneFileOffersNoMerge() throws {
        XCTAssertTrue(MergePlanner.groups(for: [try picture("a.png", red: 1, green: 0, blue: 0)]).isEmpty)
        XCTAssertTrue(MergePlanner.groups(for: []).isEmpty)
    }

    func testEachKindOfFileIsGroupedWithItsOwnKind() throws {
        let a = try picture("a.png", red: 1, green: 0, blue: 0), b = try picture("b.png", red: 0, green: 1, blue: 0)
        let notes1 = dir.appendingPathComponent("one.md"), notes2 = dir.appendingPathComponent("two.html")
        try "# One".write(to: notes1, atomically: true, encoding: .utf8)
        try "<h1>Two</h1>".write(to: notes2, atomically: true, encoding: .utf8)
        let code = dir.appendingPathComponent("x.py"); try "print(1)".write(to: code, atomically: true, encoding: .utf8)
        let files = [a, b, try detect(notes1), try detect(notes2), try detect(code)]
        let kinds = MergePlanner.groups(for: files).map(\.kind)
        XCTAssertEqual(kinds, [.pdf, .document], "code is never merged, and pictures are not documents")
        let docs = try XCTUnwrap(MergePlanner.groups(for: files).first { $0.kind == .document })
        XCTAssertEqual(docs.files.count, 2)
        XCTAssertTrue(docs.targets.map(\.id).contains("docx"))
    }

    func testTheSuggestedFormatIsTheFirstFilesOwn() throws {
        let one = dir.appendingPathComponent("a.flac"), two = dir.appendingPathComponent("b.mp3")
        let flac = DetectedFile(url: one, category: .audio, formatID: "flac", mimeType: "audio/flac", method: .magicBytes, extensionMismatch: false)
        let mp3 = DetectedFile(url: two, category: .audio, formatID: "mp3", mimeType: "audio/mpeg", method: .magicBytes, extensionMismatch: false)
        let group = try XCTUnwrap(MergePlanner.groups(for: [flac, mp3]).first)
        XCTAssertEqual(MergePlanner.suggestedTarget(for: group)?.id, "flac")
        XCTAssertEqual(MergePlanner.groups(for: [mp3, flac]).first.flatMap(MergePlanner.suggestedTarget)?.id, "mp3")
    }

    // MARK: PDF

    func testPDFsAreJoinedPageForPageInTheOrderGiven() async throws {
        let first = try pdf("two.pdf", pages: 2), second = try pdf("three.pdf", pages: 3)
        let result = try await Converter().merge(request(.pdf, [first, second], target: "pdf"))
        let merged = try XCTUnwrap(PDFDocument(url: result.outputURL))
        XCTAssertEqual(merged.pageCount, 5)
        let text = (0..<5).map { merged.page(at: $0)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        XCTAssertEqual(text, ["Page 1", "Page 2", "Page 1", "Page 2", "Page 3"])
        // The order can be changed.
        let reversed = try await Converter().merge(request(.pdf, [second, first], target: "pdf", folder: "rev"))
        let again = try XCTUnwrap(PDFDocument(url: reversed.outputURL))
        XCTAssertEqual(again.page(at: 2)?.string?.trimmingCharacters(in: .whitespacesAndNewlines), "Page 3")
        XCTAssertEqual(again.pageCount, 5)
    }

    func testPicturesBecomeOnePagePerPictureInOrder() async throws {
        let red = try picture("1.png", red: 1, green: 0, blue: 0), green = try picture("2.png", red: 0, green: 1, blue: 0)
        let blue = try picture("3.jpg", red: 0, green: 0, blue: 1, type: .jpeg)
        let result = try await Converter().merge(request(.pdf, [red, green, blue], target: "pdf"))
        let merged = try XCTUnwrap(PDFDocument(url: result.outputURL))
        XCTAssertEqual(merged.pageCount, 3)
        let colours = try (0..<3).map { try centre(of: XCTUnwrap(merged.page(at: $0))) }
        XCTAssertGreaterThan(colours[0].r, 0.8); XCTAssertLessThan(colours[0].g, 0.2)
        XCTAssertGreaterThan(colours[1].g, 0.8); XCTAssertLessThan(colours[1].r, 0.2)
        XCTAssertGreaterThan(colours[2].b, 0.8); XCTAssertLessThan(colours[2].r, 0.2)
    }

    func testPicturePagesAreA4AndTurnForAWidePicture() async throws {
        let tall = try picture("t.png", red: 1, green: 0, blue: 0, width: 300, height: 400)
        let wide = try picture("w.png", red: 0, green: 1, blue: 0, width: 400, height: 300)
        let merged = try await mergedPDF(request(.pdf, [tall, wide], target: "pdf"))
        let first = try XCTUnwrap(merged.page(at: 0)).bounds(for: .mediaBox), second = try XCTUnwrap(merged.page(at: 1)).bounds(for: .mediaBox)
        XCTAssertEqual(first.width, 595.28, accuracy: 0.5); XCTAssertEqual(first.height, 841.89, accuracy: 0.5)
        XCTAssertEqual(second.width, 841.89, accuracy: 0.5); XCTAssertEqual(second.height, 595.28, accuracy: 0.5)
        let letter = try await mergedPDF(request(.pdf, [tall, wide], target: "pdf", pageSize: .letter, folder: "l"))
        XCTAssertEqual(try XCTUnwrap(letter.page(at: 0)).bounds(for: .mediaBox).width, 612, accuracy: 0.5)
    }

    func testAPictureKeepsItsProportionsAndSitsInTheMiddleOfThePage() async throws {
        // Red on a page with white margins: the corner is white, and the middle is red.
        let red = try picture("r.png", red: 1, green: 0, blue: 0, width: 300, height: 400)
        let second = try picture("s.png", red: 1, green: 0, blue: 0, width: 300, height: 400)
        let merged = try await mergedPDF(request(.pdf, [red, second], target: "pdf"))
        let page = try XCTUnwrap(merged.page(at: 0))
        let thumbnail = page.thumbnail(of: CGSize(width: 200, height: 283), for: .mediaBox)
        let cg = try XCTUnwrap(thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil))
        func pixel(_ x: Int, _ y: Int) throws -> (Double, Double) {
            let context = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cg, in: CGRect(x: -x, y: -(cg.height - 1 - y), width: cg.width, height: cg.height))
            let p = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
            return (Double(p[0]) / 255, Double(p[1]) / 255)
        }
        let corner = try pixel(2, 2), middle = try pixel(cg.width / 2, cg.height / 2)
        XCTAssertGreaterThan(corner.1, 0.9, "the margin is white")
        XCTAssertLessThan(middle.1, 0.2, "the picture is red in the middle")
    }

    func testAPageCanTakeTheSizeOfItsPicture() async throws {
        let small = try picture("s.png", red: 1, green: 0, blue: 0, width: 300, height: 150)
        let big = try picture("b.png", red: 0, green: 0, blue: 1, width: 1500, height: 750)
        let merged = try await mergedPDF(request(.pdf, [small, big], target: "pdf", pageSize: .fitPicture))
        let a = try XCTUnwrap(merged.page(at: 0)).bounds(for: .mediaBox), b = try XCTUnwrap(merged.page(at: 1)).bounds(for: .mediaBox)
        XCTAssertEqual(a.width, 144, accuracy: 0.5); XCTAssertEqual(a.height, 72, accuracy: 0.5)
        XCTAssertEqual(b.width / b.height, 2, accuracy: 0.01)
        XCTAssertGreaterThan(b.width, a.width)
        XCTAssertGreaterThan(try centre(of: XCTUnwrap(merged.page(at: 1))).b, 0.8, "the picture fills its page")
    }

    func testPicturesAndPDFsCanBeMixedAndKeepTheirOrder() async throws {
        let red = try picture("r.png", red: 1, green: 0, blue: 0), pages = try pdf("two.pdf", pages: 2)
        let blue = try picture("b.jpg", red: 0, green: 0, blue: 1, type: .jpeg)
        let merged = try await mergedPDF(request(.pdf, [red, pages, blue], target: "pdf"))
        XCTAssertEqual(merged.pageCount, 4)
        XCTAssertGreaterThan(try centre(of: XCTUnwrap(merged.page(at: 0))).r, 0.8)
        XCTAssertEqual(merged.page(at: 1)?.string?.trimmingCharacters(in: .whitespacesAndNewlines), "Page 1")
        XCTAssertEqual(merged.page(at: 2)?.string?.trimmingCharacters(in: .whitespacesAndNewlines), "Page 2")
        XCTAssertGreaterThan(try centre(of: XCTUnwrap(merged.page(at: 3))).b, 0.8)
    }

    func testAPhotoThatIsTurnedIsStoodUpInThePDF() async throws {
        // A 400 x 300 picture marked "rotate 90" is really 300 x 400, so its page is portrait.
        let source = try picture("p.jpg", red: 1, green: 0, blue: 0, width: 400, height: 300, type: .jpeg)
        let url = dir.appendingPathComponent("turned.jpg")
        let image = try XCTUnwrap(CGImageSourceCreateWithURL(source.url as CFURL, nil))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImageFromSource(destination, image, 0, [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let other = try picture("o.png", red: 0, green: 1, blue: 0)
        let merged = try await mergedPDF(request(.pdf, [try detect(url), other], target: "pdf"))
        let bounds = try XCTUnwrap(merged.page(at: 0)).bounds(for: .mediaBox)
        XCTAssertLessThan(bounds.width, bounds.height, "the picture was stood up, so its page is portrait")
    }

    func testAPasswordProtectedPDFIsRefusedByName() async throws {
        let plain = try pdf("plain.pdf", pages: 1)
        let locked = dir.appendingPathComponent("locked.pdf")
        let document = try XCTUnwrap(PDFDocument(url: plain.url))
        XCTAssertTrue(document.write(to: locked, withOptions: [.userPasswordOption: "secret", .ownerPasswordOption: "secret"]))
        do {
            _ = try await Converter().merge(request(.pdf, [plain, try detect(locked)], target: "pdf"))
            XCTFail("a locked PDF cannot be merged")
        } catch let error as ConversionError {
            XCTAssertTrue(error.localizedDescription.contains("locked.pdf"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("password"), error.localizedDescription)
        }
    }

    func testAPictureThatCannotBeReadIsNamedAndNothingIsSaved() async throws {
        let good = try picture("good.png", red: 1, green: 0, blue: 0)
        let bad = dir.appendingPathComponent("bad.png")
        try Data("this is not a picture".utf8).write(to: bad)
        let badFile = DetectedFile(url: bad, category: .image, formatID: "png", mimeType: "image/png", method: .extensionOnly, extensionMismatch: false)
        do {
            _ = try await Converter().merge(request(.pdf, [good, badFile], target: "pdf"))
            XCTFail("an unreadable picture stops the merge")
        } catch let error as ConversionError {
            XCTAssertTrue(error.localizedDescription.contains("bad.png"), error.localizedDescription)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("out").path), "no half-made file is left")
    }

    func testMergingNeedsAtLeastTwoFiles() async throws {
        let one = try picture("a.png", red: 1, green: 0, blue: 0)
        do { _ = try await Converter().merge(request(.pdf, [one], target: "pdf")); XCTFail() } catch let error as ConversionError {
            XCTAssertTrue(error.localizedDescription.contains("at least two"))
        }
    }

    func testTheNameCannotPointOutsideTheOutputFolderAndNothingIsOverwritten() async throws {
        let a = try picture("a.png", red: 1, green: 0, blue: 0), b = try picture("b.png", red: 0, green: 1, blue: 0)
        let evil = try await Converter().merge(request(.pdf, [a, b], target: "pdf", name: "../../evil"))
        XCTAssertEqual(evil.outputURL.deletingLastPathComponent().standardized.path, dir.appendingPathComponent("out").standardized.path)
        let first = try await Converter().merge(request(.pdf, [a, b], target: "pdf", name: "Report"))
        let second = try await Converter().merge(request(.pdf, [a, b], target: "pdf", name: "Report"))
        XCTAssertEqual(first.outputURL.lastPathComponent, "Report.pdf")
        XCTAssertEqual(second.outputURL.lastPathComponent, "Report (2).pdf")
    }

    func testTheMergedPDFReportsItsProgressFromZeroToOne() async throws {
        var files: [DetectedFile] = []
        for index in 0..<6 { files.append(try picture("p\(index).png", red: 1, green: 0, blue: 0)) }
        let log = ProgressLog()
        _ = try await Converter(progress: { log.add($0) }).merge(request(.pdf, files, target: "pdf"))
        let fractions = log.all.compactMap(\.fraction)
        XCTAssertEqual(fractions.count, 6)
        XCTAssertEqual(fractions, fractions.sorted())
        XCTAssertTrue(fractions.allSatisfy { (0...1).contains($0) })
    }

    // MARK: Audio and video

    func testAudioFilesAreJoinedEndToEndEvenWhenTheirFormatsDiffer() async throws {
        try await ffmpeg(["-f", "lavfi", "-i", "sine=frequency=440:duration=1", dir.appendingPathComponent("a.wav").path])
        try await ffmpeg(["-f", "lavfi", "-i", "sine=frequency=880:duration=2", "-ac", "1", "-ar", "22050", dir.appendingPathComponent("b.flac").path])
        try await ffmpeg(["-f", "lavfi", "-i", "sine=frequency=660:duration=1.5", dir.appendingPathComponent("c.mp3").path])
        let files = try ["a.wav", "b.flac", "c.mp3"].map { try detect(dir.appendingPathComponent($0)) }
        let result = try await Converter().merge(request(.audio, files, target: "mp3"))
        XCTAssertEqual(try detect(result.outputURL).formatID, "mp3")
        let length = try await duration(result.outputURL)
        XCTAssertEqual(length, 4.5, accuracy: 0.2, "the lengths add up")
        // A WAV result has the same length and the common sample rate.
        let wav = try await Converter().merge(request(.audio, files, target: "wav", folder: "wav"))
        let rate = try await probe(wav.outputURL, "stream=sample_rate", stream: "a:0")
        XCTAssertEqual(rate, "44100")
    }

    func testAVideoWithNoSoundIsRefusedForAnAudioMerge() async throws {
        try await ffmpeg(["-f", "lavfi", "-i", "sine=duration=1", dir.appendingPathComponent("a.wav").path])
        try await ffmpeg(["-f", "lavfi", "-i", "testsrc=duration=1:size=160x120:rate=10", "-pix_fmt", "yuv420p", dir.appendingPathComponent("silent.mp4").path])
        let files = [try detect(dir.appendingPathComponent("a.wav")), try detect(dir.appendingPathComponent("silent.mp4"))]
        let audio = MergeRequest(kind: .audio, inputs: files, target: OutputFormat(id: "mp3", label: "MP3", fileExtension: "mp3", engine: .ffmpeg), outputDirectory: dir.appendingPathComponent("out"))
        do { _ = try await Converter().merge(audio); XCTFail() } catch let error as ConversionError {
            XCTAssertTrue(error.localizedDescription.contains("silent.mp4"))
            XCTAssertTrue(error.localizedDescription.contains("no sound track"))
        }
    }

    func testVideosOfDifferentSizesAreJoinedAtTheFirstOnesSize() async throws {
        try await ffmpeg(["-f", "lavfi", "-i", "testsrc=duration=1:size=320x240:rate=25", "-f", "lavfi", "-i", "sine=duration=1", "-shortest", "-pix_fmt", "yuv420p", "-c:v", "libx264", dir.appendingPathComponent("a.mp4").path])
        try await ffmpeg(["-f", "lavfi", "-i", "testsrc=duration=2:size=640x360:rate=30", "-f", "lavfi", "-i", "sine=duration=2", "-shortest", "-pix_fmt", "yuv420p", "-c:v", "libx264", dir.appendingPathComponent("b.mp4").path])
        let files = try ["a.mp4", "b.mp4"].map { try detect(dir.appendingPathComponent($0)) }
        let log = ProgressLog()
        let result = try await Converter(progress: { log.add($0) }).merge(request(.video, files, target: "mp4"))
        XCTAssertEqual(try detect(result.outputURL).formatID, "mp4")
        let length = try await duration(result.outputURL)
        XCTAssertEqual(length, 3, accuracy: 0.3)
        let size = try await probe(result.outputURL, "stream=width,height", stream: "v:0")
        XCTAssertEqual(size, "320,240", "both are joined at the first video's size")
        let audio = try await probe(result.outputURL, "stream=codec_type", stream: "a:0")
        XCTAssertEqual(audio, "audio")
        let fractions = log.all.compactMap(\.fraction)
        XCTAssertFalse(fractions.isEmpty)
        XCTAssertGreaterThan(fractions.max() ?? 0, 0.5)
        XCTAssertTrue(result.notes.isEmpty)
    }

    func testVideosWhereOneHasNoSoundAreJoinedWithoutSoundAndTheUserIsTold() async throws {
        try await ffmpeg(["-f", "lavfi", "-i", "testsrc=duration=1:size=160x120:rate=10", "-f", "lavfi", "-i", "sine=duration=1", "-shortest", "-pix_fmt", "yuv420p", dir.appendingPathComponent("a.mp4").path])
        try await ffmpeg(["-f", "lavfi", "-i", "testsrc=duration=1:size=160x120:rate=10", "-pix_fmt", "yuv420p", dir.appendingPathComponent("silent.mp4").path])
        let files = try ["a.mp4", "silent.mp4"].map { try detect(dir.appendingPathComponent($0)) }
        let result = try await Converter().merge(request(.video, files, target: "mp4"))
        XCTAssertTrue(result.notes.contains { $0.contains("no sound") })
        let audio = try await probe(result.outputURL, "stream=codec_type", stream: "a:0")
        XCTAssertEqual(audio, "", "there is no audio stream in the result")
        let length = try await duration(result.outputURL)
        XCTAssertEqual(length, 2, accuracy: 0.3)
    }

    func testTheJoinCommandMatchesEveryInputAndLeavesOutSoundThatIsNotThere() {
        let inputs = (1...3).map { URL(fileURLWithPath: "/tmp/in\($0).mp4") }
        let withSound = FFmpegMerge.arguments(inputs: inputs, targetID: "mp4", isVideo: true, width: 321, height: 241, frameRate: 29.97,
                                              keepAudio: true, output: URL(fileURLWithPath: "/tmp/out.mp4"), threads: 4)
        let graph = withSound[withSound.firstIndex(of: "-filter_complex")! + 1]
        XCTAssertTrue(graph.contains("concat=n=3:v=1:a=1[v][a]"))
        XCTAssertTrue(graph.contains("scale=320:240"), "sizes are made even")
        XCTAssertTrue(graph.contains("fps=29.97"))
        XCTAssertEqual(withSound.filter { $0 == "-i" }.count, 3)
        XCTAssertEqual(withSound.last, "/tmp/out.mp4")
        let silent = FFmpegMerge.arguments(inputs: inputs, targetID: "mp4", isVideo: true, width: nil, height: nil, frameRate: nil,
                                           keepAudio: false, output: URL(fileURLWithPath: "/tmp/out.mp4"), threads: 2)
        let silentGraph = silent[silent.firstIndex(of: "-filter_complex")! + 1]
        XCTAssertTrue(silentGraph.contains("concat=n=3:v=1:a=0[v]"))
        XCTAssertFalse(silentGraph.contains("aresample"))
        XCTAssertTrue(silentGraph.contains("scale=1280:720"), "with no size known, 720p is used")
        let audio = FFmpegMerge.arguments(inputs: inputs, targetID: "mp3", isVideo: false, width: nil, height: nil, frameRate: nil,
                                          keepAudio: true, output: URL(fileURLWithPath: "/tmp/out.mp3"), threads: 2)
        let audioGraph = audio[audio.firstIndex(of: "-filter_complex")! + 1]
        XCTAssertTrue(audioGraph.contains("concat=n=3:v=0:a=1[a]"))
        XCTAssertFalse(audioGraph.contains("scale"))
    }

    func testCancellingAMediaMergeStopsFFmpegAndSavesNothing() async throws {
        try await ffmpeg(["-f", "lavfi", "-i", "testsrc=duration=40:size=1280x720:rate=30", "-f", "lavfi", "-i", "sine=duration=40", "-shortest", "-pix_fmt", "yuv420p", "-preset", "ultrafast", dir.appendingPathComponent("a.mp4").path])
        let files = [try detect(dir.appendingPathComponent("a.mp4")), try detect(dir.appendingPathComponent("a.mp4"))]
        let cancelled = request(.video, files, target: "webm")
        let task = Task { try await Converter().merge(cancelled) }
        try await Task.sleep(nanoseconds: 1_500_000_000)
        task.cancel()
        do { _ = try await task.value; XCTFail("a cancelled merge throws") } catch is CancellationError {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("out").path))
    }

    // MARK: Documents

    private func plainText(_ url: URL) async throws -> String {
        let pandoc = try XCTUnwrap(ToolLocator().locate(["pandoc"]))
        let from = url.pathExtension == "docx" ? "docx" : (url.pathExtension == "html" ? "html" : "markdown")
        return try await ProcessRunner.run(pandoc, arguments: ["--from", from, "--to", "plain", url.path]).stdout
    }

    func testMarkdownFilesAreJoinedInOrder() async throws {
        guard ToolLocator().locate(["pandoc"]) != nil else { throw XCTSkip("Pandoc is not installed") }
        let one = dir.appendingPathComponent("one.md"), two = dir.appendingPathComponent("two.md"), three = dir.appendingPathComponent("three.md")
        try "# Alpha\n\nFirst chapter.".write(to: one, atomically: true, encoding: .utf8)
        try "# Beta\n\nSecond chapter.".write(to: two, atomically: true, encoding: .utf8)
        try "# Gamma\n\nThird chapter.".write(to: three, atomically: true, encoding: .utf8)
        let files = try [one, two, three].map(detect)
        let result = try await Converter().merge(request(.document, files, target: "md"))
        let text = try String(contentsOf: result.outputURL, encoding: .utf8)
        let order = ["Alpha", "Beta", "Gamma"].compactMap { text.range(of: $0)?.lowerBound }
        XCTAssertEqual(order.count, 3)
        XCTAssertEqual(order, order.sorted(), "the chapters come in the order given")
        XCTAssertTrue(result.notes.isEmpty, "files of one kind need no warning")
        // A Word document of the same files holds all three too.
        let docx = try await Converter().merge(request(.document, files, target: "docx", folder: "w"))
        let words = try await plainText(docx.outputURL)
        XCTAssertTrue(words.contains("Alpha") && words.contains("Beta") && words.contains("Gamma"))
        XCTAssertLessThan(try XCTUnwrap(words.range(of: "Alpha")).lowerBound, try XCTUnwrap(words.range(of: "Gamma")).lowerBound)
    }

    func testDocumentsOfDifferentKindsAreJoinedAndTheUserIsTold() async throws {
        guard ToolLocator().locate(["pandoc"]) != nil else { throw XCTSkip("Pandoc is not installed") }
        let md = dir.appendingPathComponent("notes.md"), html = dir.appendingPathComponent("page.html")
        try "# Notes\n\nFrom markdown.".write(to: md, atomically: true, encoding: .utf8)
        try "<h1>Page</h1><p>From html.</p>".write(to: html, atomically: true, encoding: .utf8)
        let first = try detect(md), second = try detect(html)
        let result = try await Converter().merge(request(.document, [first, second], target: "docx"))
        let text = try await plainText(result.outputURL)
        XCTAssertTrue(text.contains("From markdown") && text.contains("From html"))
        XCTAssertLessThan(try XCTUnwrap(text.range(of: "From markdown")).lowerBound, try XCTUnwrap(text.range(of: "From html")).lowerBound)
        XCTAssertTrue(result.notes.contains { $0.contains("different kinds") })
        // A Word file and a Markdown file also mix.
        let mixed = try await Converter().merge(request(.document, [try detect(result.outputURL), first], target: "txt", folder: "t"))
        let joined = try String(contentsOf: mixed.outputURL, encoding: .utf8)
        XCTAssertTrue(joined.contains("From html") && joined.contains("From markdown"))
    }

    private final class ProgressLog: @unchecked Sendable {
        private let lock = NSLock(); private var stored: [ConversionProgress] = []
        func add(_ update: ConversionProgress) { lock.lock(); stored.append(update); lock.unlock() }
        var all: [ConversionProgress] { lock.lock(); defer { lock.unlock() }; return stored }
    }
}
