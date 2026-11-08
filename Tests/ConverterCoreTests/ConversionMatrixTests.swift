import XCTest
import ConverterCore

/// Converts every sample file to every format the app offers for it, and checks each result.
///
/// This takes several minutes, so it only runs when FC_RUN_MATRIX=1 is set:
///     FC_RUN_MATRIX=1 swift test --filter ConversionMatrixTests
/// A line-by-line report is written to build/matrix-report.txt in the project folder.
final class ConversionMatrixTests: XCTestCase {

    /// Failures that are correct by design. Each one needs the file name and part of the message.
    private let expectedRefusals: [(file: String, message: String)] = [
        ("code/big_script.py", "60 KB"),
        ("video/silent.mp4", "no sound track"),
        // A TrueType-outline web font cannot be saved as OTF, which has PostScript outlines.
        ("fonts/sample.woff", "TrueType"),
        ("fonts/sample.woff2", "TrueType"),
    ]

    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // ConverterCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // project root
    }

    func testEverySampleConvertsToEveryOfferedFormat() async throws {
        guard ProcessInfo.processInfo.environment["FC_RUN_MATRIX"] == "1" else {
            throw XCTSkip("Set FC_RUN_MATRIX=1 to run the full matrix. It takes several minutes.")
        }
        let samples = projectRoot.appendingPathComponent("TestFiles", isDirectory: true)
        let outputRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("fc-matrix-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outputRoot) }

        let detector = FileDetector()
        let converter = Converter()
        var report: [String] = []
        var unexpected: [String] = []

        for input in try sampleFiles(in: samples) {
            let name = input.path.replacingOccurrences(of: samples.path + "/", with: "")
            let detected = try detector.detect(url: input)
            let targets = FormatCatalog.targets(for: detected)
            if targets.isEmpty {
                report.append("--    \(name): no conversions offered (\(detected.formatID))")
                continue
            }
            for target in targets {
                let label = "\(name) -> \(target.id)"
                let folder = outputRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
                do {
                    let result = try await converter.convert(
                        ConversionRequest(input: detected, route: target, outputDirectory: folder))
                    let produced = try detector.detect(url: result.outputURL)
                    if produced.formatID == target.id {
                        report.append("OK     \(label)")
                    } else {
                        report.append("WRONG  \(label): the file is really \(produced.formatID)")
                        unexpected.append(label)
                    }
                } catch {
                    let message = error.localizedDescription.replacingOccurrences(of: "\n", with: " | ")
                    if expectedRefusals.contains(where: { name == $0.file && message.contains($0.message) }) {
                        report.append("REFUSED \(label): \(message)")
                    } else {
                        report.append("FAIL   \(label): \(message)")
                        unexpected.append(label)
                    }
                }
            }
        }

        let summary = "\(report.filter { $0.hasPrefix("OK") }.count) converted correctly, " +
            "\(unexpected.count) unexpected results"
        let text = (report + ["", summary]).joined(separator: "\n") + "\n"
        let buildDir = projectRoot.appendingPathComponent("build", isDirectory: true)
        try FileManager.default.createDirectory(at: buildDir, withIntermediateDirectories: true)
        try text.write(to: buildDir.appendingPathComponent("matrix-report.txt"), atomically: true, encoding: .utf8)
        print(summary)

        XCTAssertTrue(unexpected.isEmpty, "\(summary). See build/matrix-report.txt. First: \(unexpected.first ?? "")")
    }

    /// Every sample file, skipping the README and the zip.
    private func sampleFiles(in root: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw XCTSkip("Run scripts/make-test-files.sh first.")
        }
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                                                        options: [.skipsHiddenFiles])
        var files: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension != "md", url.pathExtension != "zip" else { continue }
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                files.append(url)
            }
        }
        return files.sorted { $0.path < $1.path }
    }
}
