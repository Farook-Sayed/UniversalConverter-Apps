import XCTest
import ConverterCore

/// Tests the multi-step routes: which chains exist, and the rules that keep them sensible.
final class RouteTests: XCTestCase {

    private func detected(_ formatID: String, _ category: MediaCategory, ext: String) -> DetectedFile {
        DetectedFile(url: URL(fileURLWithPath: "/tmp/input.\(ext)"), category: category, formatID: formatID,
                     mimeType: "application/octet-stream", method: .magicBytes, extensionMismatch: false)
    }

    private func route(_ id: String, in routes: [Route]) -> Route? {
        routes.first { $0.id == id }
    }

    func testMarkdownToPDFIsTwoSteps() throws {
        let routes = FormatCatalog.targets(for: detected("md", .markup, ext: "md"))
        let pdf = try XCTUnwrap(route("pdf", in: routes))
        // Word first: LibreOffice makes a more faithful PDF from a Word file than from HTML.
        XCTAssertEqual(pdf.steps.map { $0.output.id }, ["docx", "pdf"])
        XCTAssertEqual(pdf.engines, [.pandoc, .libreoffice])
        XCTAssertEqual(pdf.label, "PDF document (via DOCX)")
    }

    func testDirectConversionsStayOneStep() throws {
        let routes = FormatCatalog.targets(for: detected("md", .markup, ext: "md"))
        let docx = try XCTUnwrap(route("docx", in: routes))
        XCTAssertFalse(docx.isMultiStep)
        XCTAssertEqual(docx.label, docx.target.label)
    }

    func testEbookReachesHTMLThroughEPUB() throws {
        let routes = FormatCatalog.targets(for: detected("mobi", .ebook, ext: "mobi"))
        let html = try XCTUnwrap(route("html", in: routes))
        XCTAssertEqual(html.steps.map { $0.output.id }, ["epub", "html"])
        XCTAssertEqual(html.engines, [.calibre, .pandoc])
    }

    func testFontsNeverChainIntoOtherFonts() {
        // A TrueType font must not reach OTF through a web font. Both are fonts, so no chain is offered.
        let routes = FormatCatalog.targets(for: detected("ttf", .font, ext: "ttf"))
        XCTAssertEqual(routes.map(\.id).sorted(), ["woff", "woff2"])
        XCTAssertTrue(routes.allSatisfy { !$0.isMultiStep })
    }

    func testChainsEndInADifferentKindOfFormat() {
        let sources: [(String, MediaCategory, String)] = [
            ("md", .markup, "md"), ("mobi", .ebook, "mobi"), ("pdf", .document, "pdf"),
            ("eps", .postscript, "eps"), ("docx", .document, "docx"), ("txt", .markup, "txt"),
        ]
        for (formatID, category, ext) in sources {
            for route in FormatCatalog.targets(for: detected(formatID, category, ext: ext)) where route.isMultiStep {
                XCTAssertNotEqual(route.target.id, formatID)
                XCTAssertNotEqual(route.steps.last?.outputCategory, category,
                                  "\(formatID) -> \(route.id) should change kind of format")
            }
        }
    }

    func testCodeIsNeverAnIntermediateStep() {
        for route in FormatCatalog.targets(for: detected("python", .code, ext: "py")) {
            XCTAssertFalse(route.steps.dropLast().contains { $0.output.engine == .ollama })
        }
        // Code routes are direct only.
        XCTAssertTrue(FormatCatalog.targets(for: detected("python", .code, ext: "py")).allSatisfy { !$0.isMultiStep })
    }

    func testEveryRouteHasAtMostThreeSteps() {
        for route in FormatCatalog.targets(for: detected("eps", .postscript, ext: "eps")) {
            XCTAssertLessThanOrEqual(route.steps.count, 3)
        }
    }
}
