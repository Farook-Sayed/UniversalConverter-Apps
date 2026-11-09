import XCTest
import CoreGraphics
import CoreText
import PDFKit
import ConverterCore

/// The features added after the first release: progress, the crop box, text recognition and Java output.
final class FeatureTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fc-feature-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Collects progress updates from the converter, which may call it from other threads.
    private final class ProgressLog: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [ConversionProgress] = []
        func add(_ update: ConversionProgress) {
            lock.lock()
            stored.append(update)
            lock.unlock()
        }
        var all: [ConversionProgress] {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }

    // MARK: Progress

    /// FFmpeg reports how far it has got. The queue shows that as a percentage, which must rise to the end.
    func testVideoConversionReportsAPercentageThatRises() async throws {
        guard let ffmpeg = ToolLocator().locate(["ffmpeg"]) else { throw XCTSkip("FFmpeg is not installed") }
        let clip = dir.appendingPathComponent("clip.mp4")
        let made = try await ProcessRunner.run(ffmpeg, arguments: [
            "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc=duration=4:size=320x240:rate=25",
            "-c:v", "libx264", "-pix_fmt", "yuv420p", "-y", clip.path,
        ])
        XCTAssertEqual(made.exitCode, 0)

        let detected = try FileDetector().detect(url: clip)
        let route = try XCTUnwrap(FormatCatalog.targets(for: detected, available: { _ in true }).first { $0.id == "mkv" })
        let log = ProgressLog()
        _ = try await Converter(progress: { log.add($0) }).convert(ConversionRequest(
            input: detected, route: route, outputDirectory: dir.appendingPathComponent("out")))

        let fractions = log.all.compactMap(\.fraction)
        XCTAssertFalse(fractions.isEmpty, "a measured conversion should report a fraction")
        XCTAssertTrue(fractions.allSatisfy { (0...1).contains($0) })
        XCTAssertGreaterThan(fractions.max() ?? 0, 0.5, "the percentage should get past the halfway point")
    }

    /// A job that cannot be measured must show a spinner, not a bar stuck at 0%.
    func testAnUnmeasuredConversionReportsNoFraction() async throws {
        let url = try writePNG(try blankPicture(width: 40, height: 40).makeImage()!, named: "plain.png")
        let detected = try FileDetector().detect(url: url)
        let route = try XCTUnwrap(FormatCatalog.targets(for: detected, available: { _ in true }).first { $0.id == "jpg" })
        let log = ProgressLog()
        _ = try await Converter(progress: { log.add($0) }).convert(ConversionRequest(
            input: detected, route: route, outputDirectory: dir.appendingPathComponent("plain")))
        XCTAssertFalse(log.all.isEmpty)
        XCTAssertTrue(log.all.allSatisfy { $0.fraction == nil }, "\(log.all)")
    }

    /// In a route of several steps, the bar must never move backwards.
    func testARouteOfSeveralStepsOnlyMovesForward() async throws {
        guard let ffmpeg = ToolLocator().locate(["ffmpeg"]) else { throw XCTSkip("FFmpeg is not installed") }
        let clip = dir.appendingPathComponent("tone.wav")
        let made = try await ProcessRunner.run(ffmpeg, arguments: [
            "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "sine=duration=3", "-y", clip.path,
        ])
        XCTAssertEqual(made.exitCode, 0)
        let detected = try FileDetector().detect(url: clip)
        let first = RouteStep(inputFormatID: "wav", inputCategory: .audio,
                              output: OutputFormat(id: "flac", label: "FLAC", fileExtension: "flac", engine: .ffmpeg),
                              outputCategory: .audio)
        let second = RouteStep(inputFormatID: "flac", inputCategory: .audio,
                               output: OutputFormat(id: "mp3", label: "MP3", fileExtension: "mp3", engine: .ffmpeg),
                               outputCategory: .audio)
        let log = ProgressLog()
        _ = try await Converter(progress: { log.add($0) }).convert(ConversionRequest(
            input: detected, route: Route(steps: [first, second]), outputDirectory: dir.appendingPathComponent("two")))
        let fractions = log.all.compactMap(\.fraction)
        XCTAssertGreaterThan(fractions.max() ?? 0, 0.5, "the second step should fill the second half")
        for (earlier, later) in zip(fractions, fractions.dropFirst()) {
            XCTAssertLessThanOrEqual(earlier, later + 0.001, "\(fractions)")
        }
    }

    func testProgressFractionsAreKeptBetweenZeroAndOne() {
        XCTAssertEqual(ConversionProgress("x", fraction: 1.7).fraction, 1)
        XCTAssertEqual(ConversionProgress("x", fraction: -0.2).fraction, 0)
        XCTAssertNil(ConversionProgress("x").fraction)
    }

    // MARK: Helpers for the picture and PDF tests

    private func blankPicture(width: Int, height: Int) throws -> CGContext {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context
    }

    /// A white picture with large black text, as a scanner would make it.
    private func textPicture(_ text: String) throws -> CGImage {
        let context = try blankPicture(width: 1000, height: 260)
        let font = CTFontCreateWithName("Helvetica" as CFString, 84, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
        context.textPosition = CGPoint(x: 50, y: 90)
        CTLineDraw(line, context)
        return try XCTUnwrap(context.makeImage())
    }

    private func writePNG(_ image: CGImage, named name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    // MARK: Crop box

    func testADrawnCropKeepsThatPartOfThePicture() throws {
        let picture = try blankPicture(width: 400, height: 300).makeImage()
        let cropped = try XCTUnwrap(ImageProcessing.crop(XCTUnwrap(picture), to: CGRect(x: 0.25, y: 0, width: 0.5, height: 1)))
        XCTAssertEqual(cropped.width, 200)
        XCTAssertEqual(cropped.height, 300)
    }

    func testShapesGiveTheRectangleTheyCover() {
        let square = ImageCrop.square.fractionRect(aspect: 1.5)
        XCTAssertEqual(Double(square?.width ?? 0), 1 / 1.5, accuracy: 0.0001)
        XCTAssertEqual(Double(square?.minX ?? 0), (1 - 1 / 1.5) / 2, accuracy: 0.0001)
        let tall = ImageCrop.square.fractionRect(aspect: 0.5)
        XCTAssertEqual(Double(tall?.height ?? 0), 0.5, accuracy: 0.0001)
        XCTAssertNil(ImageCrop.off.fractionRect(aspect: 1.5))
    }

    func testTheCropBoxIsUsedWhenRendering() throws {
        let source = try writePNG(try blankPicture(width: 400, height: 300).makeImage()!, named: "box.png")
        let adjustments = ImageAdjustments(cropRect: CGRect(x: 0, y: 0, width: 0.5, height: 0.5))
        let rendered = try ImageProcessing.render(from: source, targetID: "png", adjustments: adjustments)
        let image = try XCTUnwrap(CGImageSourceCreateWithData(rendered.data as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 200)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 150)
    }

    // MARK: Text recognition

    func testTextInAPictureIsRecognised() async throws {
        let url = try writePNG(try textPicture("HELLO WORLD"), named: "words.png")
        let detected = try FileDetector().detect(url: url)
        let route = try XCTUnwrap(FormatCatalog.targets(for: detected, available: { _ in true })
            .first { $0.id == "txt" })
        let result = try await Converter().convert(ConversionRequest(
            input: detected, route: route, outputDirectory: dir.appendingPathComponent("text")))
        let text = try String(contentsOf: result.outputURL, encoding: .utf8)
        XCTAssertTrue(text.uppercased().contains("HELLO"), "recognised: \(text)")
    }

    /// A scanned page: the text is only in the picture, so the PDF has no text layer.
    func testScannedPDFIsReadWithRecognition() async throws {
        let image = try textPicture("SCANNED PAGE")
        let url = dir.appendingPathComponent("scan.pdf")
        var box = CGRect(x: 0, y: 0, width: 500, height: 130)
        let data = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: data as CFMutableData))
        let pdf = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        pdf.beginPDFPage(nil)
        pdf.draw(image, in: box)
        pdf.endPDFPage()
        pdf.closePDF()
        try (data as Data).write(to: url)

        let detected = try FileDetector().detect(url: url)
        guard let route = FormatCatalog.targets(for: detected, available: { _ in true }).first(where: { $0.id == "txt" }) else {
            throw XCTSkip("text from a PDF needs Poppler")
        }
        let result: ConversionResult
        do {
            result = try await Converter().convert(ConversionRequest(
                input: detected, route: route, outputDirectory: dir.appendingPathComponent("scan-text")))
        } catch ConversionError.toolNotFound {
            throw XCTSkip("Poppler is not installed")
        }
        let text = try String(contentsOf: result.outputURL, encoding: .utf8)
        XCTAssertTrue(text.uppercased().contains("SCANNED"), "recognised: \(text)")
        XCTAssertTrue(result.notes.contains { $0.contains("no text layer") }, "the user should be told")
    }

    /// Black text on a transparent background reads as black on black unless it is put on white first.
    func testTextOnATransparentPictureIsRead() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 1000, height: 260, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let font = CTFontCreateWithName("Helvetica" as CFString, 84, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: "HELLO CLEAR", attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
        context.textPosition = CGPoint(x: 50, y: 90)
        CTLineDraw(line, context)
        let text = try TextRecognition.recognize(try XCTUnwrap(context.makeImage()))
        XCTAssertTrue(text.uppercased().contains("HELLO"), "recognised: \(text)")
    }

    /// One PDF page per picture, with an optional rotation, and nothing in a text layer.
    private func scannedPDF(_ pictures: [CGImage], named name: String, rotation: Int = 0) throws -> URL {
        var box = CGRect(x: 0, y: 0, width: 500, height: 130)
        let data = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: data as CFMutableData))
        let pdf = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        for picture in pictures {
            pdf.beginPDFPage(nil)
            pdf.draw(picture, in: box)
            pdf.endPDFPage()
        }
        pdf.closePDF()
        let document = try XCTUnwrap(PDFDocument(data: data as Data))
        for index in 0..<document.pageCount { document.page(at: index)?.rotation = rotation }
        let url = dir.appendingPathComponent(name)
        XCTAssertTrue(document.write(to: url))
        return url
    }

    /// A scanner often saves a page sideways and marks it as rotated.
    func testRotatedScannedPagesAreRead() throws {
        for rotation in [90, 180, 270] {
            let url = try scannedPDF([try textPicture("SCANNED PAGE")], named: "turned-\(rotation).pdf", rotation: rotation)
            let result = try TextRecognition.recognize(pdf: url)
            XCTAssertEqual(result.scannedPages, 1)
            XCTAssertTrue(result.text.uppercased().contains("SCANNED PAGE"), "rotation \(rotation) read as: \(result.text)")
        }
    }

    /// A long scan can be stopped. The check runs before each page.
    func testCancellingStopsReadingAScan() async throws {
        let url = try scannedPDF([try textPicture("SCANNED PAGE")], named: "cancel.pdf")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try TextRecognition.recognize(pdf: url)
        }
        do {
            _ = try await task.value
            XCTFail("a cancelled scan should stop")
        } catch is CancellationError {
            // Expected.
        }
    }

    /// A PDF can mix typed and scanned pages. The scanned ones must not be lost.
    func testAPDFWithSomeScannedPagesKeepsThemAll() async throws {
        let typedDocument = try XCTUnwrap(PDFDocument(data: TestPDF.text(pages: 1)))
        let scanned = try XCTUnwrap(PDFDocument(url: try scannedPDF([try textPicture("SCANNED PAGE")], named: "part.pdf")))
        typedDocument.insert(try XCTUnwrap(scanned.page(at: 0)), at: 1)
        let url = dir.appendingPathComponent("mixed.pdf")
        XCTAssertTrue(typedDocument.write(to: url))

        let detected = try FileDetector().detect(url: url)
        guard ToolLocator().locate(["pdftotext"]) != nil,
              let route = FormatCatalog.targets(for: detected, available: { _ in true }).first(where: { $0.id == "txt" }) else {
            throw XCTSkip("Poppler is not installed")
        }
        let result = try await Converter().convert(ConversionRequest(
            input: detected, route: route, outputDirectory: dir.appendingPathComponent("mixed")))
        let text = try String(contentsOf: result.outputURL, encoding: .utf8).uppercased()
        XCTAssertTrue(text.contains("PAGE 1"), text)
        XCTAssertTrue(text.contains("SCANNED"), text)
        XCTAssertTrue(result.notes.contains { $0.contains("1 page(s)") }, "\(result.notes)")
    }

    /// Text in two columns stays in its columns, not one line from each.
    func testColumnsAreReadOneAfterTheOther() throws {
        let context = try blankPicture(width: 1400, height: 700)
        let font = CTFontCreateWithName("Helvetica" as CFString, 40, nil)
        func draw(_ text: String, x: CGFloat, y: CGFloat) {
            let line = CTLineCreateWithAttributedString(NSAttributedString(
                string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
            context.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(line, context)
        }
        for (index, word) in ["one", "two", "three"].enumerated() {
            let y = 500 - CGFloat(index) * 110
            draw("Left column line \(word)", x: 40, y: y)
            draw("Right side sentence \(word)", x: 760, y: y)
        }
        let text = try TextRecognition.recognize(try XCTUnwrap(context.makeImage()))
        let lines = text.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 6, text)
        XCTAssertTrue(lines.prefix(3).allSatisfy { $0.hasPrefix("Left") }, text)
    }

    // MARK: Java

    private let javaClass = """
    import java.util.List;

    public class Demo {
        private int count = 0;

        // Adds one.
        public void add() {
            count++;
        }

        public List<Integer> values() {
            return null;
        }
    }

    """

    func testAJavaClassIsCutBetweenItsMembers() throws {
        let split = try XCTUnwrap(CodeChunker.splitJavaClass(javaClass, limit: 40))
        XCTAssertEqual(split.className, "Demo")
        XCTAssertTrue(split.header.contains("import java.util.List;"))
        XCTAssertGreaterThanOrEqual(split.parts.count, 2)
        for part in split.parts {
            XCTAssertEqual(part.components(separatedBy: "{").count, part.components(separatedBy: "}").count,
                           "every part holds whole members:\n\(part)")
        }
    }

    /// Splitting a Java class and joining it back must still compile: this is the check for the member boundaries.
    func testJoinedJavaMembersCompileAsOneClass() async throws {
        let split = try XCTUnwrap(CodeChunker.splitJavaClass(javaClass, limit: 60))
        let rejoined = CodeChunker.joinJavaClass([split.header] + split.parts, className: "Demo")
        XCTAssertTrue(rejoined.contains("public class Demo {"))
        XCTAssertEqual(rejoined.components(separatedBy: "import java.util.List;").count - 1, 1)
        let java = try XCTUnwrap(FormatCatalog.codeLanguage(forID: "java"))
        let result = try await CodeValidator(tools: ToolLocator()).validate(
            code: rejoined, language: java, fileName: "Demo.java", workDir: dir)
        switch result {
        case .passed: break
        case .notChecked(let reason): throw XCTSkip(reason)
        case .failed(_, let messages): XCTFail("javac rejected the joined class: \(messages)")
        }
    }

    func testJoinKeepsOneCopyOfEachImportAndWrapsTheMembers() {
        let joined = CodeChunker.joinJavaClass(["import a.B;\n\nint x() { return 1; }",
                                                "import a.B;\nimport c.D;\n\nint y() { return 2; }"], className: "Demo")
        XCTAssertEqual(joined.components(separatedBy: "import a.B;").count - 1, 1)
        XCTAssertTrue(joined.contains("import c.D;"))
        let classStart = joined.range(of: "public class Demo {")
        XCTAssertNotNil(classStart)
        XCTAssertTrue(joined.hasSuffix("}\n"))
        XCTAssertLessThan(joined.range(of: "import c.D;")!.lowerBound, classStart!.lowerBound, "imports come first")
    }

    /// The model's own wrapper around a part goes, but a class the source really has stays, and it must compile.
    func testARealClassStaysAndAWrapperGoes() async throws {
        let parts = [
            "public class Wrapper {\n    public static int add(int a, int b) { return a + b; }\n}",
            "public class Point {\n    int x;\n    public Point(int x) { this.x = x; }\n}",
            "static Point origin() {\n    return new Point(add(0, 0));\n}",
        ]
        let joined = CodeChunker.joinJavaClass(parts, className: "Demo", keeping: ["Point"])
        XCTAssertFalse(joined.contains("class Wrapper"), joined)
        XCTAssertTrue(joined.contains("public static class Point {"), joined)
        XCTAssertEqual(joined.components(separatedBy: "public class").count - 1, 1, joined)

        let java = try XCTUnwrap(FormatCatalog.codeLanguage(forID: "java"))
        let result = try await CodeValidator(tools: ToolLocator()).validate(
            code: joined, language: java, fileName: "Demo.java", workDir: dir)
        switch result {
        case .passed: break
        case .notChecked(let reason): throw XCTSkip(reason)
        case .failed(_, let messages): XCTFail("javac rejected it: \(messages)\n\(joined)")
        }
    }

    /// A closing brace with a comment after it still ends the wrapper, so later braces are kept.
    func testAWrapperThatEndsWithACommentIsStillClosed() {
        let joined = CodeChunker.joinJavaClass(
            ["class Wrapper {\n    int x;\n} // end\nint y() {\n    return 1;\n}"], className: "Demo")
        XCTAssertEqual(joined.components(separatedBy: "{").count, joined.components(separatedBy: "}").count, joined)
    }

    func testClassNamesAreFoundInTheSource() {
        let names = CodeChunker.typeNames(in: """
        # the class of things
        class Point:
            pass
        class Line(Point):
            pass
        pub struct Grid {
        }
        public final class Box<T> {
        }
        def run(): pass
        """)
        XCTAssertEqual(names, ["Point", "Line", "Grid", "Box"])
    }

    func testTheMembersPromptAsksForTopLevelCode() {
        let java = FormatCatalog.codeLanguage(forID: "java")!
        let python = FormatCatalog.codeLanguage(forID: "python")!
        let prompt = CodePrompt.members(source: java, target: python, code: "int x;", className: "Demo",
                                        imports: "import a.B;", index: 1, count: 2)
        XCTAssertTrue(prompt.contains("no surrounding class"))
        XCTAssertTrue(prompt.contains("import a.B;"))
    }

    func testAScriptIsNotTreatedAsAClass() {
        XCTAssertNil(CodeChunker.splitJavaClass("print('hi')\n"))
    }

    /// A long Python file becomes one Java class, and its functions stay in it.
    func testLongPythonFileBecomesOneJavaClass() async throws {
        guard await OllamaClient().isRunning() else { throw XCTSkip("Ollama is not running") }
        let py = dir.appendingPathComponent("Long.py")
        let source = (1...200).map { "def compute_\($0)(x):\n    return x * \($0) + \($0)\n" }.joined(separator: "\n")
        try source.write(to: py, atomically: true, encoding: .utf8)
        let detected = try FileDetector().detect(url: py)
        let route = try XCTUnwrap(FormatCatalog.targets(for: detected).first { $0.id == "java" })
        let result = try await Converter().convert(ConversionRequest(
            input: detected, route: route, outputDirectory: dir.appendingPathComponent("java")))
        let code = try String(contentsOf: result.outputURL, encoding: .utf8)
        XCTAssertTrue(code.contains("public class Long {"))
        XCTAssertEqual(code.components(separatedBy: "public class").count - 1, 1, "one class, not one per part")
    }
}
