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
    static let settingsTab = "settingsTab"
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

/// One optional tool group and whether it is installed.
struct FeatureState: Identifiable {
    let feature: ToolFeature
    let installed: Bool
    var id: String { feature.id }
}

/// The files in the window, and the conversions running on them.
@MainActor
@Observable
final class AppModel {

    enum Phase: Equatable {
        case ready
        /// Waiting for a free slot. At most `maxConcurrent` conversions run at once.
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
        var directTargets: [Route] { targets.filter { !$0.isMultiStep } }
        var chainedTargets: [Route] { targets.filter(\.isMultiStep) }
    }

    private(set) var items: [Item] = []
    private(set) var features: [FeatureState] = []
    private(set) var homebrewInstalled = false
    /// The feature being installed right now, and the step it is on.
    private(set) var installingID: String?
    private(set) var installStep: String?
    /// A short message about files that could not be added. Shown above the list until dismissed.
    private(set) var notice: String?
    /// The result of the last install. Shown above the list until dismissed.
    private(set) var toolNotice: String?

    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var waiting: [UUID] = []
    static let maxConcurrent = 2

    init() {
        refreshTools()
    }

    var hasItems: Bool { !items.isEmpty }
    var anyBusy: Bool { items.contains { $0.isBusy } }
    var convertingCount: Int { items.filter(\.isBusy).count }
    var missingFeatures: [FeatureState] { features.filter { !$0.installed } }
    var isInstalling: Bool { installingID != nil }
    private var runningCount: Int { items.filter { $0.phase == .converting }.count }

    /// Whether a conversion tool is installed. The menus offer only conversions that can run now.
    private var usable: (Engine) -> Bool {
        let locator = ToolLocator()
        return { locator.isAvailable($0) }
    }

    // MARK: Files

    /// Adds files to the queue. Folders and unreadable files are reported in `notice`.
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
                let targets = FormatCatalog.targets(for: detected, available: usable)
                items.append(Item(file: detected, targets: targets, selectedTargetID: targets.first?.id))
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

    func remove(_ id: UUID) {
        remove([id])
    }

    /// Removes files that are finished, failed or cancelled. Files still waiting or converting stay.
    func clearFinished() {
        items.removeAll { !$0.isBusy && $0.phase != .ready }
    }

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

    /// Recalculates the notes for every file. Called when files are added, formats change, or tools change.
    func refreshFindings() {
        let python = Converter.fontPython(tools: ToolLocator())
        let locator = ToolLocator()
        for index in items.indices {
            let file = items[index].file
            var findings: [Finding] = []
            if let target = items[index].selectedTarget {
                findings = Preflight.findings(for: file, target: target,
                                              outputFolder: outputDirectory(for: file.url),
                                              tools: locator, fontPython: python)
            }
            // Formats that would appear if the optional tools were installed.
            let everything = FormatCatalog.targets(for: file).count
            let hidden = everything - items[index].targets.count
            if everything == 0 {
                findings.append(Finding(severity: .info, message: "Universal Converter cannot convert this kind of file yet."))
            } else if hidden > 0 {
                let verb = hidden == 1 ? "needs an optional tool" : "need optional tools"
                findings.append(Finding(severity: .info,
                                        message: "\(hidden) more format\(hidden == 1 ? "" : "s") \(verb). Add them in Settings, under Tools."))
            }
            items[index].findings = findings
        }
    }

    /// Recalculates the format menus, for example after a tool is installed. A chosen format is kept if it still exists.
    func rebuildTargets() {
        for index in items.indices {
            let targets = FormatCatalog.targets(for: items[index].file, available: usable)
            items[index].targets = targets
            if !targets.contains(where: { $0.id == items[index].selectedTargetID }) {
                items[index].selectedTargetID = targets.first?.id
            }
        }
        refreshFindings()
    }

    // MARK: Converting

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

    /// Converts every file that has a format chosen and is not already done.
    func convertAll() {
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

    // MARK: Tools

    func refreshTools() {
        let locator = ToolLocator()
        features = ToolFeature.all.map { FeatureState(feature: $0, installed: $0.isInstalled(locator)) }
        homebrewInstalled = locator.locate(["brew"]) != nil
    }

    /// Installs one optional feature with Homebrew. Only one install runs at a time.
    func install(_ state: FeatureState) {
        guard installingID == nil else { return }
        installingID = state.id
        installStep = "Starting…"
        toolNotice = nil
        let feature = state.feature
        let codeModel = AppSettings.ollamaModel
        Task { [weak self] in
            do {
                _ = try await ToolInstaller.install(feature, tools: ToolLocator(), codeModel: codeModel) { step in
                    Task { @MainActor in self?.installStep = step }
                }
                self?.toolNotice = "\(feature.title) is ready. Its formats now appear in the menus."
            } catch {
                self?.toolNotice = "\(feature.title) could not be installed. \(error.localizedDescription)"
            }
            self?.installingID = nil
            self?.installStep = nil
            self?.refreshTools()
            self?.rebuildTargets()
        }
    }

    func dismissToolNotice() { toolNotice = nil }
    func dismissNotice() { notice = nil }

    // MARK: Helpers

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
}
