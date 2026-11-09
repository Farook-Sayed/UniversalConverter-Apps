import XCTest
import ConverterCore

/// Making a PDF smaller: the levels, the custom size, and the size text the user types.
final class CompressionTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fc-compress-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func size(_ url: URL) -> Int {
        Int(Preflight.fileSize(url))
    }

    private func write(_ data: Data, named name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    /// Runs the PDF-to-smaller-PDF route with the given compression.
    private func compress(_ input: URL, _ compression: PDFCompression) async throws -> ConversionResult {
        let detected = try FileDetector().detect(url: input)
        guard let route = FormatCatalog.targets(for: detected, available: { _ in true })
            .first(where: { $0.id == "pdf" && $0.engine == .ghostscript }) else {
            XCTFail("a PDF should offer a smaller PDF")
            throw ConversionError.unsupported("no route")
        }
        do {
            return try await Converter().convert(ConversionRequest(
                input: detected, route: route, outputDirectory: dir.appendingPathComponent("out"),
                pdfCompression: compression))
        } catch ConversionError.toolNotFound(let tool) {
            throw XCTSkip("\(tool) is not installed")
        }
    }

    func testEveryPresetGivesAPDFNoLargerThanTheOriginal() async throws {
        let original = try write(TestPDF.text(pages: 3), named: "text.pdf")
        for level in [PDFCompression.original, .low, .medium, .high] {
            let result = try await compress(original, level)
            let data = try Data(contentsOf: result.outputURL)
            XCTAssertTrue(data.starts(with: Data("%PDF".utf8)), "\(level) should give a PDF")
            XCTAssertLessThanOrEqual(size(result.outputURL), size(original), "\(level) should not grow the file")
        }
    }

    func testHighCompressionShrinksAnImageHeavyPDF() async throws {
        let original = try write(TestPDF.imageHeavy(), named: "photos.pdf")
        let result = try await compress(original, .high)
        XCTAssertLessThan(size(result.outputURL), size(original) / 2)
    }

    func testCustomSizeThatAlreadyFitsKeepsTheFile() async throws {
        let original = try write(TestPDF.text(pages: 1), named: "small.pdf")
        let result = try await compress(original, .custom(bytes: 10_000_000))
        XCTAssertEqual(size(result.outputURL), size(original))
        XCTAssertTrue(result.notes.contains { $0.contains("already") })
    }

    func testUnreachableCustomSizeKeepsTheSmallestAndSaysSo() async throws {
        let original = try write(TestPDF.imageHeavy(), named: "photos-big.pdf")
        let result = try await compress(original, .custom(bytes: 1_000))
        XCTAssertFalse(result.notes.isEmpty, "the user should be told the size was not reached")
        XCTAssertLessThan(size(result.outputURL), size(original))
    }

    func testOnlyPDFsOfferASmallerPDF() throws {
        let pdf = try write(TestPDF.text(pages: 1), named: "offer.pdf")
        let detected = try FileDetector().detect(url: pdf)
        let withGhostscript = FormatCatalog.targets(for: detected, available: { _ in true })
        XCTAssertTrue(withGhostscript.contains { $0.id == "pdf" && $0.engine == .ghostscript })
        let withoutGhostscript = FormatCatalog.targets(for: detected, available: { $0 != .ghostscript })
        XCTAssertFalse(withoutGhostscript.contains { $0.id == "pdf" })
    }

    func testSizesAreParsedAsTypedAndRejectedWhenUnclear() {
        XCTAssertEqual(FileSize.parse("2 MB"), 2_000_000)
        XCTAssertEqual(FileSize.parse("800kb"), 800_000)
        XCTAssertEqual(FileSize.parse("1.5 mb"), 1_500_000)
        XCTAssertEqual(FileSize.parse("3"), 3_000_000, "a bare number means megabytes")
        XCTAssertEqual(FileSize.parse("1 GB"), 1_000_000_000)
        XCTAssertNil(FileSize.parse(""))
        XCTAssertNil(FileSize.parse("0 MB"))
        XCTAssertNil(FileSize.parse("2 furlongs"))
        XCTAssertNil(FileSize.parse("abc"))
    }
}
