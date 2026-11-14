import XCTest
import PDFKit
@testable import ConverterCore

final class PDFUnlockTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("unlock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    private func makePDF(named name: String, user: String?, owner: String?) throws -> URL {
        let document = PDFDocument()
        let page = PDFPage()
        document.insert(page, at: 0)
        document.insert(PDFPage(), at: 1)
        var options: [PDFDocumentWriteOption: Any] = [:]
        if let user { options[.userPasswordOption] = user }
        if let owner { options[.ownerPasswordOption] = owner }
        let url = folder.appendingPathComponent(name)
        XCTAssertTrue(document.write(to: url, withOptions: options))
        return url
    }

    func testPlainPDFIsNotProtected() throws {
        XCTAssertEqual(PDFUnlocker.protection(of: try makePDF(named: "a.pdf", user: nil, owner: nil)), .none)
    }

    func testPasswordPDFNeedsPassword() throws {
        let url = try makePDF(named: "b.pdf", user: "open-me", owner: "owner-pw")
        XCTAssertEqual(PDFUnlocker.protection(of: url), .needsPassword)
        XCTAssertFalse(PDFUnlocker.accepts("wrong", for: url))
        XCTAssertTrue(PDFUnlocker.accepts("open-me", for: url))
    }

    func testOwnerOnlyPDFOpensWithoutPassword() throws {
        let url = try makePDF(named: "c.pdf", user: nil, owner: "owner-pw")
        XCTAssertEqual(PDFUnlocker.protection(of: url), .restricted)
        let output = folder.appendingPathComponent("c-open.pdf")
        try PDFUnlocker.writeUnlocked(url, password: "", to: output)
        XCTAssertEqual(PDFUnlocker.protection(of: output), .none)
        XCTAssertEqual(PDFDocument(url: output)?.pageCount, 2)
    }

    func testWritesUnlockedCopyWithRightPassword() throws {
        let url = try makePDF(named: "d.pdf", user: "open-me", owner: "owner-pw")
        let output = folder.appendingPathComponent("out/d.pdf")
        XCTAssertThrowsError(try PDFUnlocker.writeUnlocked(url, password: "nope", to: output)) {
            XCTAssertTrue($0 is PDFWrongPasswordError)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        try PDFUnlocker.writeUnlocked(url, password: "open-me", to: output)
        XCTAssertEqual(PDFUnlocker.protection(of: output), .none)
        XCTAssertEqual(PDFDocument(url: output)?.pageCount, 2)
    }
}

extension PDFUnlockTests {
    func testOpenUsesRememberedPasswordAndKeepsTheName() throws {
        let url = try makePDF(named: "Report.pdf", user: "shared", owner: "x")
        XCTAssertEqual(PDFUnlocker.open(url, trying: ["other"]), .needsPassword)
        guard case .unlocked(let copy, let password) = PDFUnlocker.open(url, trying: ["other", "shared"]) else {
            return XCTFail("expected the PDF to open")
        }
        defer { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }
        XCTAssertEqual(password, "shared")
        XCTAssertEqual(copy.lastPathComponent, "Report.pdf")
        XCTAssertEqual(PDFUnlocker.protection(of: copy), .none)
        XCTAssertNil(PDFUnlocker.open(url, password: "bad"))
    }
}

extension PDFUnlockTests {
    func testDamagedFileIsNotReportedAsProtected() throws {
        let url = folder.appendingPathComponent("broken.pdf")
        try Data("this is not a pdf".utf8).write(to: url)
        XCTAssertEqual(PDFUnlocker.open(url, trying: ["x"]), .notProtected)
    }

    func testUnlockedCopyKeepsRotationAndTitle() throws {
        let document = PDFDocument()
        let page = PDFPage()
        page.rotation = 90
        document.insert(page, at: 0)
        document.documentAttributes = [PDFDocumentAttribute.titleAttribute: "Quarterly report"]
        let url = folder.appendingPathComponent("rotated.pdf")
        XCTAssertTrue(document.write(to: url, withOptions: [.userPasswordOption: "pw", .ownerPasswordOption: "pw2"]))
        let output = folder.appendingPathComponent("rotated-open.pdf")
        try PDFUnlocker.writeUnlocked(url, password: "pw", to: output)
        let copy = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(copy.page(at: 0)?.rotation, 90)
        XCTAssertEqual(copy.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String, "Quarterly report")
    }
}
