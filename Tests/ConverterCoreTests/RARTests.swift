import XCTest
import ConverterCore

/// Converting real RAR files. These need a RAR file on this Mac, so they run only when FC_RAR_SAMPLE is set:
///     FC_RAR_SAMPLE=/path/to/archive.rar swift test --filter RARTests
final class RARTests: XCTestCase {

    func testRealRARArchiveConvertsToZip() async throws {
        guard let path = ProcessInfo.processInfo.environment["FC_RAR_SAMPLE"] else {
            throw XCTSkip("Set FC_RAR_SAMPLE to a RAR file to run this test")
        }
        let input = URL(fileURLWithPath: path)
        let detected = try FileDetector().detect(url: input)
        XCTAssertEqual(detected.formatID, "rar")
        let route = try XCTUnwrap(FormatCatalog.targets(for: detected, available: { _ in true })
            .first { $0.id == "zip" })

        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("fc-rar-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: output) }
        let result = try await Converter().convert(
            ConversionRequest(input: detected, route: route, outputDirectory: output))

        let listing = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/unzip"),
                                                  arguments: ["-Z1", result.outputURL.path])
        XCTAssertTrue(listing.stdout.contains("35mb.png"), "the ZIP should hold every file from the archive")
    }
}
