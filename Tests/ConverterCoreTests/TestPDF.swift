import Foundation

/// Builds small PDFs by hand, so the tests need no other tool to make their input.
enum TestPDF {

    /// A PDF with one line of text per page.
    static func text(pages: Int) -> Data {
        // Object numbers: 1 is the catalog, 2 the page tree, then each page with its content, then the font.
        let font = 3 + pages * 2
        var objects: [Data] = [Data("<< /Type /Catalog /Pages 2 0 R >>".utf8)]
        let kids = (0..<pages).map { "\(3 + $0 * 2) 0 R" }.joined(separator: " ")
        objects.append(Data("<< /Type /Pages /Kids [\(kids)] /Count \(pages) >>".utf8))
        for index in 0..<pages {
            let page = "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] "
                + "/Resources << /Font << /F1 \(font) 0 R >> >> /Contents \(4 + index * 2) 0 R >>"
            objects.append(Data(page.utf8))
            let text = "BT /F1 24 Tf 20 90 Td (Page \(index + 1)) Tj ET"
            objects.append(Data("<< /Length \(text.utf8.count) >>\nstream\n\(text)\nendstream".utf8))
        }
        objects.append(Data("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>".utf8))
        return build(objects)
    }

    /// A one-page PDF with a large, uncompressed colour photo. Its noise does not compress, so
    /// reducing the image resolution is what makes the file smaller.
    static func imageHeavy(pixels: Int = 1200) -> Data {
        var pixelBytes = Data(capacity: pixels * pixels * 3)
        var seed: UInt32 = 12_345
        for _ in 0..<(pixels * pixels * 3) {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            pixelBytes.append(UInt8(seed >> 24))
        }
        let header = "<< /Type /XObject /Subtype /Image /Width \(pixels) /Height \(pixels) "
            + "/ColorSpace /DeviceRGB /BitsPerComponent 8 /Length \(pixelBytes.count) >>\nstream\n"
        var image = Data(header.utf8)
        image.append(pixelBytes)
        image.append(Data("\nendstream".utf8))
        let content = "q 300 0 0 300 50 50 cm /Im1 Do Q"
        return build([
            Data("<< /Type /Catalog /Pages 2 0 R >>".utf8),
            Data("<< /Type /Pages /Kids [3 0 R] /Count 1 >>".utf8),
            Data(("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 400] "
                + "/Resources << /XObject << /Im1 4 0 R >> >> /Contents 5 0 R >>").utf8),
            image,
            Data("<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream".utf8),
        ])
    }

    /// Joins the objects into a PDF file, with the cross-reference table that readers expect.
    private static func build(_ objects: [Data]) -> Data {
        var pdf = Data("%PDF-1.4\n".utf8)
        var offsets: [Int] = []
        for (index, body) in objects.enumerated() {
            offsets.append(pdf.count)
            pdf.append(Data("\(index + 1) 0 obj\n".utf8))
            pdf.append(body)
            pdf.append(Data("\nendobj\n".utf8))
        }
        let xref = pdf.count
        var table = "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets {
            table += String(format: "%010d 00000 n \n", offset)
        }
        table += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        pdf.append(Data(table.utf8))
        return pdf
    }
}
