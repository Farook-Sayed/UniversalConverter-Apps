import Foundation
import CoreGraphics
import PDFKit
import Vision

/// Reads text from pictures and from scanned pages, with Vision, which ships with macOS.
public enum TextRecognition {

    /// The largest side of a page drawn for reading, in pixels. A poster-sized page would otherwise need gigabytes.
    private static let largestPageSide: CGFloat = 5000

    /// The text in a picture, in reading order. Empty when there is no text.
    public static func recognize(_ image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        // Transparent areas read as black, which would hide black text. They go on white first.
        let readable = image.alphaInfo == .none || image.alphaInfo == .noneSkipLast || image.alphaInfo == .noneSkipFirst
            ? image : (ImageProcessing.flattened(image) ?? image)
        try VNImageRequestHandler(cgImage: readable, options: [:]).perform([request])
        // Vision gives lines in reading order, and keeps each column of a page together.
        return (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }

    /// What a PDF holds as text. `scannedPages` counts the pages with no text layer, and `recognizedText` says
    /// whether any of those pages gave text.
    public struct PDFText: Sendable {
        public let text: String
        public let scannedPages: Int
        public let recognizedText: Bool
    }

    /// The text of every page of a PDF. A page with a text layer gives that text. A scanned page, which has no
    /// text layer, is drawn as a picture and read. `progress` gives the share of pages done, from 0 to 1.
    /// Cancelling the task stops it between pages.
    public static func recognize(pdf url: URL, progress: (Double) -> Void = { _ in }) throws -> PDFText {
        guard let document = PDFDocument(url: url) else {
            throw ConversionError.unsupported("This PDF could not be opened.")
        }
        var pages: [String] = []
        var scanned = 0
        var recognizedText = false
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            progress(Double(index) / Double(max(document.pageCount, 1)))
            // Each page's picture is released before the next is drawn, so a long scan does not fill the memory.
            try autoreleasepool {
                guard let page = document.page(at: index) else { return }
                let layer = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !layer.isEmpty {
                    pages.append(layer)
                    return
                }
                scanned += 1
                if let picture = render(page) {
                    let text = try recognize(picture)
                    if !text.isEmpty {
                        recognizedText = true
                        pages.append(text)
                    }
                }
            }
        }
        progress(1)
        return PDFText(text: pages.joined(separator: "\n\n"), scannedPages: scanned, recognizedText: recognizedText)
    }

    /// A page drawn on white, the way up it is shown. Reading needs more pixels than the screen shows.
    private static func render(_ page: PDFPage) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        // PDFKit gives the page's size before its rotation, and draws it after the rotation.
        let sideways = abs(page.rotation) % 180 == 90
        let shownWidth = sideways ? bounds.height : bounds.width
        let shownHeight = sideways ? bounds.width : bounds.height
        guard shownWidth > 0, shownHeight > 0 else { return nil }
        let scale = min(2.5, largestPageSide / max(shownWidth, shownHeight))
        let width = Int(shownWidth * scale), height = Int(shownHeight * scale)
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)
        return context.makeImage()
    }
}
