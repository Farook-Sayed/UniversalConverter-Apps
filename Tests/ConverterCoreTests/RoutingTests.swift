import XCTest
import ConverterCore

final class RoutingTests: XCTestCase {

    private func detected(_ formatID: String, _ category: MediaCategory, ext: String) -> DetectedFile {
        DetectedFile(url: URL(fileURLWithPath: "/tmp/input.\(ext)"), category: category, formatID: formatID,
                     mimeType: "application/octet-stream", method: .magicBytes, extensionMismatch: false)
    }

    private func target(_ id: String, in targets: [Route]) -> Route? {
        targets.first { $0.id == id }
    }

    func testVideoCanBecomeAudioWithFFmpeg() {
        let targets = FormatCatalog.targets(for: detected("mp4", .video, ext: "mp4"))
        XCTAssertEqual(target("mp3", in: targets)?.engine, .ffmpeg)
        XCTAssertEqual(target("gif", in: targets)?.engine, .ffmpeg)
        XCTAssertNil(target("mp4", in: targets), "a file is never offered its own format")
    }

    func testRasterImagesUseTheBuiltInImageEngineExceptForPDFAndWebP() {
        let targets = FormatCatalog.targets(for: detected("png", .image, ext: "png"))
        XCTAssertEqual(target("jpg", in: targets)?.engine, .imageio)
        XCTAssertEqual(target("pdf", in: targets)?.engine, .imagemagick)
        XCTAssertEqual(target("webp", in: targets)?.engine, .imagemagick)
    }

    func testSVGUsesImageMagick() {
        let targets = FormatCatalog.targets(for: detected("svg", .vector, ext: "svg"))
        XCTAssertEqual(target("png", in: targets)?.engine, .imagemagick)
    }

    func testWordDocumentsUseLibreOfficeExceptMarkdown() {
        let targets = FormatCatalog.targets(for: detected("docx", .document, ext: "docx"))
        XCTAssertEqual(target("pdf", in: targets)?.engine, .libreoffice)
        XCTAssertEqual(target("md", in: targets)?.engine, .pandoc)
    }


    func testLegacyWordAndRTFReachMarkdownThroughWord() {
        // Pandoc reads only .docx, so these reach Markdown in two steps: first to DOCX, then to Markdown.
        for (formatID, ext) in [("doc", "doc"), ("rtf", "rtf"), ("odt", "odt")] {
            let md = target("md", in: FormatCatalog.targets(for: detected(formatID, .document, ext: ext)))
            XCTAssertEqual(md?.steps.map { $0.output.id }, ["docx", "md"], formatID)
        }
    }

    func testSpreadsheetsAndSlidesUseLibreOffice() {
        XCTAssertEqual(target("pdf", in: FormatCatalog.targets(for: detected("xlsx", .spreadsheet, ext: "xlsx")))?.engine,
                       .libreoffice)
        XCTAssertEqual(target("pdf", in: FormatCatalog.targets(for: detected("pptx", .presentation, ext: "pptx")))?.engine,
                       .libreoffice)
    }

    func testMarkdownConvertsWithPandoc() {
        let targets = FormatCatalog.targets(for: detected("md", .markup, ext: "md"))
        XCTAssertEqual(target("docx", in: targets)?.engine, .pandoc)
        XCTAssertEqual(target("html", in: targets)?.engine, .pandoc)
        // Markdown to PDF goes through Word: Pandoc, then LibreOffice. It is not a direct conversion.
        let pdf = target("pdf", in: targets)
        XCTAssertEqual(pdf?.engine, .libreoffice)
        XCTAssertEqual(pdf?.isMultiStep, true)
        XCTAssertEqual(pdf?.steps.first?.output.id, "docx")
    }

    func testHTMLCanBecomePDFWithLibreOffice() {
        let targets = FormatCatalog.targets(for: detected("html", .markup, ext: "html"))
        XCTAssertEqual(target("pdf", in: targets)?.engine, .libreoffice)
    }

    func testCodeUsesOllamaAndExcludesItself() {
        let targets = FormatCatalog.targets(for: detected("python", .code, ext: "py"))
        XCTAssertEqual(target("java", in: targets)?.engine, .ollama)
        XCTAssertEqual(target("java", in: targets)?.fileExtension, "java")
        XCTAssertNil(target("python", in: targets))
    }

    func testUnknownFilesHaveNoTargets() {
        XCTAssertTrue(FormatCatalog.targets(for: detected("xyz", .unknown, ext: "xyz")).isEmpty)
    }

    func testArchivesConvertToOtherArchiveFormats() {
        let zip = FormatCatalog.targets(for: detected("zip", .archive, ext: "zip"))
        XCTAssertEqual(zip.map(\.id).sorted(), ["7z", "tar", "targz"])
        XCTAssertEqual(target("targz", in: zip)?.fileExtension, "tar.gz")
        XCTAssertEqual(target("7z", in: zip)?.engine, .archiver)
    }

    func testTarGzOffersZipAndSevenZipButNotItself() {
        let targets = FormatCatalog.targets(for: detected("targz", .archive, ext: "tar.gz"))
        XCTAssertEqual(target("zip", in: targets)?.engine, .archiver)
        XCTAssertNil(target("targz", in: targets))
    }

    func testVideoOffersTheExtraContainers() {
        let targets = FormatCatalog.targets(for: detected("mp4", .video, ext: "mp4"))
        XCTAssertEqual(target("wmv", in: targets)?.engine, .ffmpeg)
        XCTAssertEqual(target("flv", in: targets)?.engine, .ffmpeg)
        XCTAssertEqual(target("3gp", in: targets)?.engine, .ffmpeg)
    }

    func testSubtitlesConvertWithFFmpeg() {
        let targets = FormatCatalog.targets(for: detected("srt", .subtitle, ext: "srt"))
        XCTAssertEqual(targets.map(\.id).sorted(), ["ass", "vtt"])
        XCTAssertEqual(target("vtt", in: targets)?.engine, .ffmpeg)
    }

    func testFontsConvertWithFontTools() {
        let ttf = FormatCatalog.targets(for: detected("ttf", .font, ext: "ttf"))
        XCTAssertEqual(ttf.map(\.id).sorted(), ["woff", "woff2"])
        XCTAssertEqual(target("woff", in: ttf)?.engine, .fonttools)
        let woff = FormatCatalog.targets(for: detected("woff", .font, ext: "woff"))
        XCTAssertEqual(woff.map(\.id).sorted(), ["otf", "ttf"])
    }

    func testNotebookConvertsWithPandoc() {
        let targets = FormatCatalog.targets(for: detected("ipynb", .markup, ext: "ipynb"))
        XCTAssertEqual(target("md", in: targets)?.engine, .pandoc)
        XCTAssertNil(target("ipynb", in: targets), "a notebook is not offered its own format")
    }

    func testPDFOffersTextImagesAndDocuments() {
        let targets = FormatCatalog.targets(for: detected("pdf", .document, ext: "pdf"))
        XCTAssertEqual(target("txt", in: targets)?.engine, .poppler)
        XCTAssertEqual(target("png", in: targets)?.engine, .poppler)
        XCTAssertEqual(target("docx", in: targets)?.engine, .libreoffice)
        // A smaller PDF is offered too. It is made by Ghostscript, not by Poppler.
        XCTAssertEqual(target("pdf", in: targets)?.engine, .ghostscript)
    }

    func testPostScriptConvertsWithGhostscript() {
        let targets = FormatCatalog.targets(for: detected("eps", .postscript, ext: "eps"))
        XCTAssertTrue(["jpg", "pdf", "png"].allSatisfy { id in targets.contains { $0.id == id } })
        XCTAssertEqual(target("pdf", in: targets)?.engine, .ghostscript)
    }

    func testModelsConvertWithAssimp() {
        let targets = FormatCatalog.targets(for: detected("obj", .model3d, ext: "obj"))
        XCTAssertEqual(target("glb", in: targets)?.engine, .assimp)
        XCTAssertNil(target("obj", in: targets))
        XCTAssertEqual(Converter.assimpFormat(for: "gltf"), "gltf2")
        XCTAssertEqual(Converter.assimpFormat(for: "dae"), "collada")
    }

    func testEbooksConvertWithCalibre() {
        let targets = FormatCatalog.targets(for: detected("mobi", .ebook, ext: "mobi"))
        XCTAssertEqual(target("epub", in: targets)?.engine, .calibre)
        XCTAssertEqual(target("pdf", in: targets)?.engine, .calibre)
        XCTAssertNil(target("mobi", in: targets))
    }

    func testEPUBOffersKindleAndFictionBookThroughCalibre() {
        let targets = FormatCatalog.targets(for: detected("epub", .markup, ext: "epub"))
        XCTAssertEqual(target("mobi", in: targets)?.engine, .calibre)
        XCTAssertEqual(target("fb2", in: targets)?.engine, .calibre)
        XCTAssertEqual(target("docx", in: targets)?.engine, .pandoc)
    }

    func testPlainGzipIsNotOfferedAnything() {
        XCTAssertTrue(FormatCatalog.targets(for: detected("gz", .archive, ext: "gz")).isEmpty)
    }

    func testFileStemKeepsTarGzTogether() {
        XCTAssertEqual(FileNames.stem(URL(fileURLWithPath: "/tmp/backup.tar.gz")), "backup")
        XCTAssertEqual(FileNames.stem(URL(fileURLWithPath: "/tmp/backup.zip")), "backup")
        XCTAssertEqual(FileNames.effectiveExtension(URL(fileURLWithPath: "/tmp/backup.tar.gz")), "tar.gz")
    }

    func testExtensionAliasesAreRecognised() {
        XCTAssertTrue(FormatCatalog.extensions(forFormat: "jpg").contains("jpeg"))
        XCTAssertTrue(FormatCatalog.extensions(forFormat: "md").contains("markdown"))
        XCTAssertTrue(FormatCatalog.extensions(forFormat: "cpp").contains("cc"))
    }
}
