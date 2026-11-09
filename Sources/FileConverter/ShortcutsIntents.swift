import AppIntents
import Foundation
import ConverterCore

/// "Convert File" in Shortcuts and Siri. It takes a file and a format, and returns the converted file.
struct ConvertFileIntent: AppIntent {
    static let title: LocalizedStringResource = "Convert File"
    static let description = IntentDescription(
        "Converts a file to another format with Universal Converter. The result is returned to the shortcut.")

    @Parameter(title: "File")
    var file: IntentFile

    @Parameter(title: "Format",
               description: "The format to convert to, such as pdf, png, mp3 or docx.")
    var format: String

    static var parameterSummary: some ParameterSummary {
        Summary("Convert \(\.$file) to \(\.$format)")
    }

    func perform() async throws -> some ReturnsValue<IntentFile> {
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("fc-shortcut-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        // Use the file where it is if the shortcut has a path, otherwise write the data to a temporary file.
        let inputURL: URL
        if let existing = file.fileURL {
            inputURL = existing
        } else {
            // Only the last part of the name is used, so a name like "../x" cannot leave the temporary folder.
            let safeName = URL(fileURLWithPath: file.filename).lastPathComponent
            inputURL = work.appendingPathComponent(safeName.isEmpty ? "input" : safeName)
            try file.data.write(to: inputURL)
        }

        let detected = try FileDetector().detect(url: inputURL)
        let wanted = format.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        guard let target = FormatCatalog.targets(for: detected)
            .first(where: { $0.id == wanted || $0.fileExtension == wanted }) else {
            throw IntentFailure("Universal Converter cannot convert \(file.filename) to \(format).")
        }

        let output = work.appendingPathComponent("output", isDirectory: true)
        let converter = Converter(ollama: OllamaClient(model: AppSettings.ollamaModel),
                                  repairAttempts: AppSettings.repairAttempts,
                                  pageOutput: .zip)
        let result = try await converter.convert(
            ConversionRequest(input: detected, route: target, outputDirectory: output))

        // The file is copied out of the temporary folder before that folder is removed.
        let returned = FileManager.default.temporaryDirectory
            .appendingPathComponent("fc-result-\(UUID().uuidString)-\(result.outputURL.lastPathComponent)")
        try FileManager.default.copyItem(at: result.outputURL, to: returned)
        return .result(value: IntentFile(fileURL: returned, filename: result.outputURL.lastPathComponent))
    }
}

/// Makes Siri and Shortcuts find the action without any setup by the user.
struct UniversalConverterShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ConvertFileIntent(),
            phrases: [
                "Convert a file with \(.applicationName)",
                "Convert with \(.applicationName)",
            ],
            shortTitle: "Convert File",
            systemImageName: "arrow.triangle.2.circlepath"
        )
    }
}

/// A message that Shortcuts shows when a conversion cannot run.
struct IntentFailure: LocalizedError {
    let errorDescription: String?

    init(_ message: String) {
        errorDescription = message
    }
}
