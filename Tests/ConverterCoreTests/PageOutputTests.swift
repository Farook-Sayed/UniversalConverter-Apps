import XCTest
import ConverterCore

/// PDF pages become one image each. One page gives one file. Several pages give a folder, or a ZIP file.
final class PageOutputTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fc-pages-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makePDF(pages: Int, named name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try TestPDF.text(pages: pages).write(to: url)
        return url
    }

    /// Converts a file to a format, using the first route that offers it.
    private func convert(_ input: URL, to targetID: String, pages: PageOutput) async throws -> ConversionResult {
        let detected = try FileDetector().detect(url: input)
        guard let route = FormatCatalog.targets(for: detected, available: { _ in true })
            .first(where: { $0.id == targetID }) else {
            XCTFail("no route from PDF to \(targetID)")
            throw ConversionError.unsupported("no route")
        }
        do {
            return try await Converter(pageOutput: pages).convert(
                ConversionRequest(input: detected, route: route, outputDirectory: dir.appendingPathComponent("out")))
        } catch ConversionError.toolNotFound(let tool) {
            throw XCTSkip("\(tool) is not installed")
        }
    }

    private func isFolder(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func contents(of folder: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
    }

    func testOnePageBecomesOneImage() async throws {
        let pdf = try makePDF(pages: 1, named: "one.pdf")
        let result = try await convert(pdf, to: "png", pages: .folder)
        XCTAssertEqual(result.outputURL.lastPathComponent, "one.png")
        XCTAssertFalse(isFolder(result.outputURL))
    }

    func testEveryPageBecomesAnImageInAFolder() async throws {
        let pdf = try makePDF(pages: 3, named: "three.pdf")
        let result = try await convert(pdf, to: "png", pages: .folder)
        XCTAssertEqual(result.outputURL.lastPathComponent, "three")
        XCTAssertTrue(isFolder(result.outputURL))
        let images = try contents(of: result.outputURL)
        XCTAssertEqual(images.filter { $0.pathExtension == "png" }.count, 3)
    }

    func testJPEGPagesKeepTheirExtension() async throws {
        let pdf = try makePDF(pages: 2, named: "two.pdf")
        let result = try await convert(pdf, to: "jpg", pages: .folder)
        XCTAssertEqual(try contents(of: result.outputURL).map(\.pathExtension).sorted(), ["jpg", "jpg"])
    }

    func testEveryPageCanGoIntoAZIPFile() async throws {
        let pdf = try makePDF(pages: 3, named: "zipped.pdf")
        let result = try await convert(pdf, to: "png", pages: .zip)
        XCTAssertEqual(result.outputURL.lastPathComponent, "zipped.zip")
        let listing = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/unzip"),
                                                  arguments: ["-Z1", result.outputURL.path])
        let entries = listing.stdout.split(separator: "\n").filter { $0.hasSuffix(".png") }
        XCTAssertEqual(entries.count, 3)
        XCTAssertFalse(listing.stdout.contains("__MACOSX"), "the ZIP should hold only the page images")
    }

    func testPageImagesAreNeverAnIntermediateStep() throws {
        let pdf = try makePDF(pages: 2, named: "chain.pdf")
        let detected = try FileDetector().detect(url: pdf)
        for route in FormatCatalog.targets(for: detected, available: { _ in true }) {
            for step in route.steps.dropLast() {
                XCTAssertFalse(step.producesPageImages, "\(route.label) would pass several page files on")
            }
        }
    }
}
