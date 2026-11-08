import Foundation
import AppKit
import Observation
import UserNotifications
import ConverterCore

/// Keys used by the Settings window and read by the conversion model.
enum SettingsKey {
    static let outputFolder = "outputFolderPath"   // empty means next to each original file
    static let ollamaModel = "ollamaModel"
    static let repairCode = "repairCode"
    static let revealWhenDone = "revealWhenDone"
    static let notifyWhenDone = "notifyWhenDone"
}

enum AppSettings {
    static func register() {
        UserDefaults.standard.register(defaults: [
            SettingsKey.outputFolder: "",
            SettingsKey.ollamaModel: "qwen2.5-coder:7b",
            SettingsKey.repairCode: true,
            SettingsKey.revealWhenDone: false,
            SettingsKey.notifyWhenDone: true,
        ])
    }

    static var outputFolder: URL? {
        let path = UserDefaults.standard.string(forKey: SettingsKey.outputFolder) ?? ""
        return path.isEmpty ? nil : URL(fileURLWithPath: path, isDirectory: true)
    }

    static var ollamaModel: String {
        let model = UserDefaults.standard.string(forKey: SettingsKey.ollamaModel) ?? ""
        return model.isEmpty ? "qwen2.5-coder:7b" : model
    }

    static var repairAttempts: Int {
        UserDefaults.standard.bool(forKey: SettingsKey.repairCode) ? 1 : 0
    }
}

/// The files in the window, and the conversions running on them.
@MainActor
@Observable
final class AppModel {

    enum Phase: Equatable {
        case ready
        /// Waiting for a free slot. At most two conversions run at once.
        case queued
        case converting
        case finished(URL, ValidationResult?)
        case failed(String)
        case cancelled
    }

    struct Item: Identifiable {
        let id = UUID()
        let file: DetectedFile
        var targets: [Route]
        var selectedTargetID: String?
        var findings: [Finding] = []
        var phase: Phase = .ready
        var log: [String] = []

        var selectedTarget: Route? { targets.first { $0.id == selectedTargetID } }
        var isBlocked: Bool { findings.contains { $0.severity == .blocking } }
        var isBusy: Bool { phase == .converting || phase == .queued }
        /// Formats reached in one step, and formats reached through other formats.
        var directTargets: [Route] { targets.filter { !$0.isMultiStep } }
        var chainedTargets: [Route] { targets.filter(\.isMultiStep) }
    }

    private(set) var items: [Item] = []
    private(set) var tools: [ToolStatus] = []
    /// A short message about files that could not be added, shown above the list.
    private(set) var notice: String?

    private var tasks: [UUID: Task<Void, Never>] = [:]

    init() {
        refreshTools()
    }

    var hasItems: Bool { !items.isEmpty }
    var anyBusy: Bool { items.contains { $0.isBusy } }
    var missingTools: [ToolStatus] { tools.filter { $0.path == nil } }

    // MARK: Adding and removing files

    /// Adds files to the queue. Files that cannot be read are reported in `notice`.
    func add(_ urls: [URL]) {
        var problems: [String] = []
        var folders: [String] = []
        for url in urls where !items.contains(where: { $0.file.url == url }) {
            var isFolder: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), isFolder.boolValue {
                folders.append(url.lastPathComponent)
                continue
            }
            do {
                let detected = try FileDetector().detect(url: url)
                let targets = FormatCatalog.targets(for: detected)
                var item = Item(file: detected, targets: targets, selectedTargetID: targets.first?.id)
                if targets.isEmpty {
                    item.phase = .failed("No conversions are available for this file yet.")
                }
                items.append(item)
            } catch {
                problems.append(url.lastPathComponent)
            }
        }
        var messages: [String] = []
        if !folders.isEmpty {
            messages.append("Folders cannot be converted (\(folders.joined(separator: ", "))). Drop the files inside instead.")
        }
        if !problems.isEmpty {
            messages.append("Could not read: \(problems.joined(separator: ", "))")
        }
        notice = messages.isEmpty ? nil : messages.joined(separator: " ")
        refreshFindings()
    }

    func remove(_ ids: Set<UUID>) {
        for id in ids { tasks[id]?.cancel() }
        waiting.removeAll { ids.contains($0) }
        items.removeAll { ids.contains($0.id) }
    }

    var convertingCount: Int { items.filter(\.isBusy).count }

    func remove(_ id: UUID) {
        tasks[id]?.cancel()
        waiting.removeAll { $0 == id }
        items.removeAll { $0.id == id }
    }

    /// Removes files that are finished, failed or cancelled. Files still converting stay.
    func clearFinished() {
        items.removeAll { !$0.isBusy && $0.phase != .ready }
    }

    // MARK: Choosing a format

    func select(_ targetID: String?, for id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].selectedTargetID = targetID
        items[index].phase = .ready
        refreshFindings()
    }

    /// Where a file's result is saved: the Settings folder, or next to the original.
    func outputDirectory(for url: URL) -> URL {
        AppSettings.outputFolder ?? url.deletingLastPathComponent()
    }

    /// Recalculates the warnings for every file that has a format chosen.
    func refreshFindings() {
        let python = Converter.fontPython(tools: ToolLocator())
        for index in items.indices {
            guard let target = items[index].selectedTarget else {
                items[index].findings = []
                continue
            }
            items[index].findings = Preflight.findings(
                for: items[index].file, target: target,
                outputFolder: outputDirectory(for: items[index].file.url),
                tools: ToolLocator(), fontPython: python)
        }
    }

    // MARK: Converting

    /// At most this many conversions run at once. More would slow each other down and use a lot of memory.
    static let maxConcurrent = 2

    /// Files waiting for a free slot, in the order they were queued.
    private var waiting: [UUID] = []

    private var runningCount: Int { items.filter { $0.phase == .converting }.count }

    /// Queues a file. It starts at once when fewer than `maxConcurrent` conversions are running.
    func convert(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }),
              !items[index].isBusy,
              items[index].selectedTarget != nil else { return }
        refreshFindings()
        guard !items[index].isBlocked else { return }
        items[index].phase = .queued
        items[index].log = []
        waiting.append(id)
        startWaiting()
    }

    private func startWaiting() {
        while runningCount < Self.maxConcurrent, !waiting.isEmpty {
            start(waiting.removeFirst())
        }
    }

    private func start(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }),
              items[index].phase == .queued,
              let target = items[index].selectedTarget else { return }
        let file = items[index].file
        items[index].phase = .converting
        let request = ConversionRequest(input: file, route: target,
                                        outputDirectory: outputDirectory(for: file.url))
        let converter = Converter(ollama: OllamaClient(model: AppSettings.ollamaModel),
                                  repairAttempts: AppSettings.repairAttempts)

        tasks[id] = Task { [weak self] in
            do {
                let result = try await converter.convert(request)
                self?.finish(id, phase: .finished(result.outputURL, result.validation), log: result.log)
            } catch {
                if Task.isCancelled {
                    self?.finish(id, phase: .cancelled, log: [])
                } else {
                    self?.finish(id, phase: .failed(error.localizedDescription), log: [])
                }
            }
        }
    }

    func convertAll() {
        // Files that are already finished are left alone, so Convert All never makes duplicates.
        for item in items where item.phase == .ready && item.selectedTarget != nil && !item.isBlocked {
            convert(item.id)
        }
    }

    func cancel(_ id: UUID) {
        if waiting.contains(id) {
            waiting.removeAll { $0 == id }
            if let index = items.firstIndex(where: { $0.id == id }) { items[index].phase = .cancelled }
        } else {
            tasks[id]?.cancel()
        }
    }

    private func finish(_ id: UUID, phase: Phase, log: [String]) {
        tasks[id] = nil
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].phase = phase
        items[index].log = log
        if case .finished(let url, _) = phase {
            if UserDefaults.standard.bool(forKey: SettingsKey.revealWhenDone) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            notifyIfInBackground(title: "Saved \(url.lastPathComponent)")
        }
        startWaiting()
    }

    /// Fills the window with sample files in several states. Only used by the snapshot tool.
    func loadDemo(folder: URL) {
        let names = ["documents/sample.docx", "video/sample.mp4", "images/sample.png", "code/hello.py",
                     "video/silent.mp4", "audio/sample.mp3", "markup/sample.md"]
        add(names.map { folder.appendingPathComponent($0) })
        func choose(_ index: Int, _ id: String) {
            if items.indices.contains(index) { select(id, for: items[index].id) }
        }
        choose(0, "pdf"); choose(1, "gif"); choose(2, "jpg"); choose(3, "java")
        choose(4, "mp3"); choose(6, "pdf")
        if items.count > 3 {
            items[3].phase = .finished(folder.appendingPathComponent("code/hello.py"), .passed(checker: "javac"))
        }
        if items.count > 4 {
            items[4].phase = .failed("silent.mp4 has no sound track, so there is no audio to save as MP3 audio.")
        }
        if items.count > 5 { items[5].phase = .converting }
    }

    // MARK: Helpers

    func refreshTools() {
        tools = ToolLocator().statusOfAllTools()
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Shows a file picker and adds the chosen files.
    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.message = "Choose files to convert"
        if panel.runModal() == .OK {
            add(panel.urls)
        }
    }

    private func notifyIfInBackground(title: String) {
        guard UserDefaults.standard.bool(forKey: SettingsKey.notifyWhenDone), !NSApp.isActive else { return }
        let content = UNMutableNotificationContent()
        content.title = "Universal Converter"
        content.body = title
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
}
