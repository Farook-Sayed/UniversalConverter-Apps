import XCTest
import ConverterCore

final class DetectionTests: XCTestCase {

    private let detector = FileDetector()

    private func bytes(_ values: [UInt8]) -> Data { Data(values) }

    private func ascii(_ text: String) -> Data { Data(text.utf8) }

    func testPNGIsIdentifiedByContent() {
        let png = bytes([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0])
        let file = detector.detect(head: png, url: URL(fileURLWithPath: "/tmp/photo.png"))
        XCTAssertEqual(file.formatID, "png")
        XCTAssertEqual(file.category, .image)
        XCTAssertEqual(file.method, .magicBytes)
        XCTAssertFalse(file.extensionMismatch)
    }

    func testMislabelledFileIsDetectedFromContent() {
        // A PNG saved with a .jpg name must be read as PNG and flagged.
        let png = bytes([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let file = detector.detect(head: png, url: URL(fileURLWithPath: "/tmp/photo.jpg"))
        XCTAssertEqual(file.formatID, "png")
        XCTAssertTrue(file.extensionMismatch)
    }

    func testTextStartingWithBMIsNotBitmap() {
        let file = detector.detect(head: ascii("BMW annual report\n"), url: URL(fileURLWithPath: "/tmp/notes.txt"))
        XCTAssertNotEqual(file.formatID, "bmp")
        XCTAssertEqual(file.formatID, "txt")
    }

    func testPDFIsIdentified() {
        let file = detector.detect(head: ascii("%PDF-1.7\n"), url: URL(fileURLWithPath: "/tmp/a.pdf"))
        XCTAssertEqual(file.formatID, "pdf")
        XCTAssertEqual(file.category, .document)
    }

    func testMP4AndQuickTimeAndM4AUseTheFtypBrand() {
        func ftyp(_ brand: String) -> Data {
            var data = Data([0, 0, 0, 0x18])
            data.append(ascii("ftyp"))
            data.append(ascii(brand))
            return data
        }
        XCTAssertEqual(detector.detect(head: ftyp("isom"), url: URL(fileURLWithPath: "/tmp/v.mp4")).formatID, "mp4")
        XCTAssertEqual(detector.detect(head: ftyp("qt  "), url: URL(fileURLWithPath: "/tmp/v.mov")).formatID, "mov")
        XCTAssertEqual(detector.detect(head: ftyp("M4A "), url: URL(fileURLWithPath: "/tmp/s.m4a")).category, .audio)
        XCTAssertEqual(detector.detect(head: ftyp("avif"), url: URL(fileURLWithPath: "/tmp/p.avif")).formatID, "avif")
    }

    /// One ZIP entry as it is stored in a file: the 30-byte local header, then the name, then the stored data.
    private func zipEntry(_ name: String, data: String = "") -> Data {
        var entry = Data([0x50, 0x4B, 0x03, 0x04])
        entry.append(Data(repeating: 0, count: 22))            // version, flags, method, time, date, CRC, sizes
        entry.append(contentsOf: [UInt8(name.utf8.count), 0])  // name length
        entry.append(contentsOf: [0, 0])                       // extra field length
        entry.append(ascii(name))
        entry.append(ascii(data))
        return entry
    }

    func testWordDocumentInsideZipIsRecognised() {
        // A .docx is a ZIP whose entry names start with "word/".
        var data = zipEntry("[Content_Types].xml", data: "<Types/>")
        data.append(zipEntry("word/document.xml"))
        let file = detector.detect(head: data, url: URL(fileURLWithPath: "/tmp/report.docx"))
        XCTAssertEqual(file.formatID, "docx")
        XCTAssertEqual(file.category, .document)
    }

    func testOpenDocumentSpreadsheetInsideZipIsRecognised() {
        // OpenDocument files store "mimetype" first, and its text names the type.
        let data = zipEntry("mimetype", data: "application/vnd.oasis.opendocument.spreadsheet")
        let file = detector.detect(head: data, url: URL(fileURLWithPath: "/tmp/budget.ods"))
        XCTAssertEqual(file.formatID, "ods")
        XCTAssertEqual(file.category, .spreadsheet)
    }

    func testOrdinaryZipsWithOfficeLookingFolderNamesStayZips() {
        // "password/" contains "word/", "documents/word/" has a word folder inside another, and a text file
        // can mention a type. None of these is an Office or OpenDocument file.
        var data = zipEntry("backup/password/list.txt")
        data.append(zipEntry("documents/word/notes.txt"))
        data.append(zipEntry("notes.txt", data: "see application/vnd.oasis.opendocument.text"))
        let file = detector.detect(head: data, url: URL(fileURLWithPath: "/tmp/backup.zip"))
        XCTAssertEqual(file.formatID, "zip")
        XCTAssertEqual(file.category, .archive)
    }

    func testWindowsMediaAndFlashAreIdentified() {
        let wmv = Data([0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11, 0x00, 0x00])
        XCTAssertEqual(detector.detect(head: wmv, url: URL(fileURLWithPath: "/tmp/clip.wmv")).formatID, "wmv")
        let flv = Data([0x46, 0x4C, 0x56, 0x01, 0x05, 0x00, 0x00, 0x00])
        XCTAssertEqual(detector.detect(head: flv, url: URL(fileURLWithPath: "/tmp/clip.flv")).formatID, "flv")
    }

    func testFontSignaturesAreIdentified() {
        let cases: [(bytes: Data, formatID: String)] = [
            (Data([0x00, 0x01, 0x00, 0x00, 0x00, 0x0C]), "ttf"),
            (ascii("OTTO\u{00}\u{0D}"), "otf"),
            (ascii("wOFF\u{00}\u{01}"), "woff"),
            (ascii("wOF2\u{00}\u{01}"), "woff2"),
        ]
        for testCase in cases {
            let file = detector.detect(head: testCase.bytes, url: URL(fileURLWithPath: "/tmp/font.bin"))
            XCTAssertEqual(file.formatID, testCase.formatID)
            XCTAssertEqual(file.category, .font)
        }
    }

    func testMPEGProgramStreamIsVOBOrMPGByName() {
        let program = Data([0x00, 0x00, 0x01, 0xBA, 0x44, 0x00, 0x04, 0x00])
        XCTAssertEqual(detector.detect(head: program, url: URL(fileURLWithPath: "/tmp/disc.vob")).formatID, "vob")
        XCTAssertEqual(detector.detect(head: program, url: URL(fileURLWithPath: "/tmp/clip.mpg")).formatID, "mpg")
    }

    func testM2TSIsRecognisedByExtension() {
        // M2TS has no reliable signature. This data has zero bytes, so it is not text either.
        let binary = Data([0x47, 0x00, 0x11, 0x10, 0x00, 0x00])
        let file = detector.detect(head: binary, url: URL(fileURLWithPath: "/tmp/recording.m2ts"))
        XCTAssertEqual(file.formatID, "m2ts")
        XCTAssertEqual(file.category, .video)
        XCTAssertEqual(file.method, .extensionOnly)
    }

    func testSubtitleFilesAreIdentified() {
        let srt = ascii("1\n00:00:00,500 --> 00:00:02,000\nHello\n")
        let file = detector.detect(head: srt, url: URL(fileURLWithPath: "/tmp/movie.srt"))
        XCTAssertEqual(file.formatID, "srt")
        XCTAssertEqual(file.category, .subtitle)
    }

    func testKindleAndFictionBookAreIdentified() {
        var mobi = Data(count: 68)
        mobi.replaceSubrange(60..<68, with: ascii("BOOKMOBI"))
        XCTAssertEqual(detector.detect(head: mobi, url: URL(fileURLWithPath: "/tmp/novel.mobi")).formatID, "mobi")
        XCTAssertEqual(detector.detect(head: mobi, url: URL(fileURLWithPath: "/tmp/novel.azw3")).formatID, "azw3")
        let fb2 = ascii("<?xml version=\"1.0\"?>\n<FictionBook xmlns=\"http://www.gribuser.ru/xml/fictionbook/2.0\">")
        let file = detector.detect(head: fb2, url: URL(fileURLWithPath: "/tmp/novel.fb2"))
        XCTAssertEqual(file.formatID, "fb2")
        XCTAssertEqual(file.category, .ebook)
    }

    func testGzipNamedTarGzIsCompressedTar() {
        let gzip = Data([0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00])
        XCTAssertEqual(detector.detect(head: gzip, url: URL(fileURLWithPath: "/tmp/backup.tar.gz")).formatID, "targz")
        XCTAssertEqual(detector.detect(head: gzip, url: URL(fileURLWithPath: "/tmp/data.gz")).formatID, "gz")
    }

    func testPlainZipStaysZip() {
        var data = bytes([0x50, 0x4B, 0x03, 0x04])
        data.append(ascii("notes.txt"))
        let file = detector.detect(head: data, url: URL(fileURLWithPath: "/tmp/files.zip"))
        XCTAssertEqual(file.formatID, "zip")
        XCTAssertEqual(file.category, .archive)
    }

    func testPythonSourceIsIdentifiedAsCodeByExtension() {
        let file = detector.detect(head: ascii("print('hello')\n"), url: URL(fileURLWithPath: "/tmp/hello.py"))
        XCTAssertEqual(file.formatID, "python")
        XCTAssertEqual(file.category, .code)
        XCTAssertEqual(file.method, .textWithExtension)
    }

    func testSVGIsIdentifiedFromText() {
        let svg = ascii("<?xml version=\"1.0\"?><svg xmlns=\"http://www.w3.org/2000/svg\"></svg>")
        let file = detector.detect(head: svg, url: URL(fileURLWithPath: "/tmp/icon.svg"))
        XCTAssertEqual(file.formatID, "svg")
        XCTAssertEqual(file.category, .vector)
    }

    func testMarkdownWithAnInlineSVGIsStillMarkdown() {
        let md = ascii("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"10\"></svg>\n\n# Chapter one\n")
        let file = detector.detect(head: md, url: URL(fileURLWithPath: "/tmp/book.md"))
        XCTAssertEqual(file.formatID, "md")
        XCTAssertEqual(file.category, .markup)
    }

    func testRandomBinaryWithUnknownExtensionIsUnknown() {
        let data = bytes([0x00, 0xFF, 0x13, 0x37, 0x00, 0x42])
        let file = detector.detect(head: data, url: URL(fileURLWithPath: "/tmp/blob.xyz"))
        XCTAssertEqual(file.category, .unknown)
    }
}
