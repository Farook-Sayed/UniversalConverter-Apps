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
    static let pagesAsZip = "pagesAsZip"
    static let settingsTab = "settingsTab"
}

enum AppSettings {
    static func register() {
        UserDefaults.standard.register(defaults: [
            SettingsKey.outputFolder: "",
            SettingsKey.ollamaModel: CodeModels.defaultName,
            SettingsKey.repairCode: true,
            SettingsKey.revealWhenDone: false,
            SettingsKey.notifyWhenDone: true,
            SettingsKey.pagesAsZip: false,
        ])
    }

    static var outputFolder: URL? {
        let path = UserDefaults.standard.string(forKey: SettingsKey.outputFolder) ?? ""
        return path.isEmpty ? nil : URL(fileURLWithPath: path, isDirectory: true)
    }

    static var ollamaModel: String { CodeModels.selected }

    /// Several PDF pages become a ZIP file when this is on, and a folder when it is off.
    static var pageOutput: PageOutput {
        UserDefaults.standard.bool(forKey: SettingsKey.pagesAsZip) ? .zip : .folder
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

/// The compression levels offered in the queue for a PDF. Custom reveals a field for the size.
enum PDFCompressionChoice: String, CaseIterable, Identifiable {
    case original, low, medium, high, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .original: return "Original"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .custom: return "Custom"
        }
    }

    var summary: String {
        switch self {
        case .original: return "Keeps every image at full resolution. The file is only rewritten."
        case .low: return "Light compression. Images stay near 300 dpi."
        case .medium: return "Balanced. Images are kept near 150 dpi."
        case .high: return "The smallest file. Images drop to about 72 dpi, so print quality falls."
        case .custom: return "Type a size such as 2 MB or 800 KB. Image quality is lowered until the file fits."
        }
    }
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

    /// Whether a PDF has a password. A locked PDF cannot be converted until its password is entered.
    enum PDFLock: Equatable {
        case none
        /// Being opened to see whether it has a password.
        case checking
        case needsPassword
        /// Opened. This is the copy without protection that conversions read.
        case unlocked(URL)
    }

    struct Item: Identifiable {
        let id = UUID()
        let file: DetectedFile
        var lock: PDFLock = .none

        /// The file conversions read: the unlocked copy of a PDF that had a password, or the file itself.
        var effectiveFile: DetectedFile {
            guard case .unlocked(let copy) = lock else { return file }
            return DetectedFile(url: copy, category: file.category, formatID: file.formatID, mimeType: file.mimeType,
                                method: file.method, extensionMismatch: file.extensionMismatch)
        }
        var targets: [Route]
        var selectedTargetID: String?
        var findings: [Finding] = []
        var phase: Phase = .ready
        var log: [String] = []
        /// What the conversion is doing right now, such as "Translating part 2 of 5".
        var progress: ConversionProgress?
        /// PDF compression, and the size typed for the custom level, such as "2 MB".
        var compression: PDFCompressionChoice = .medium
        var customSize = ""
        /// Notes about the finished result, such as a size that could not be reached.
        var notes: [String] = []
        /// The adjustments for a picture: compression, size, crop, background and style.
        var imageEdits = ImageEdits()
        /// The size of the original, read once when the file is added.
        var size: Int64 = 0

        /// True when the chosen route makes a smaller PDF from a PDF.
        var isCompressTarget: Bool {
            guard let route = selectedTarget else { return false }
            return route.engine == .ghostscript && route.target.id == "pdf" && file.formatID == "pdf"
        }

        /// The compression to run. Nil when a custom size is missing or not understood.
        var compressionValue: PDFCompression? {
            switch compression {
            case .original: return .original
            case .low: return .low
            case .medium: return .medium
            case .high: return .high
            case .custom: return FileSize.parse(customSize).map { PDFCompression.custom(bytes: $0) }
            }
        }

        /// True when the chosen route is an image conversion, which can take adjustments.
        var isImageTarget: Bool {
            guard let route = selectedTarget else { return false }
            // Text read from a picture has no size, quality or crop settings, so it gets no Adjust button.
            return route.engine == .imageio && file.category == .image && route.target.id != "txt"
        }

        /// True when the chosen format can trade quality for size.
        var isLossyImageTarget: Bool {
            selectedTarget.map { ImageProcessing.lossyTargets.contains($0.id) } ?? false
        }

        /// True when a typed size or pixel count is missing or not understood.
        var needsCustomSize: Bool {
            (isCompressTarget && compressionValue == nil) || (isImageTarget && imageEdits.adjustments == nil)
        }

        var selectedTarget: Route? { targets.first { $0.id == selectedTargetID } }
        var isBlocked: Bool { findings.contains { $0.severity == .blocking } }
        var isUnlocked: Bool { if case .unlocked = lock { return true } else { return false } }
        var isBusy: Bool { phase == .converting || phase == .queued }
        var directTargets: [Route] { targets.filter { !$0.isMultiStep } }
        var chainedTargets: [Route] { targets.filter(\.isMultiStep) }
    }

    private(set) var items: [Item] = []
    private(set) var features: [FeatureState] = []
    private(set) var homebrewInstalled = false
    /// Every install and download running now, each with the step it is on. Several can run at the same time.
    private(set) var installSteps: [String: String] = [:]
    /// A short message about files that could not be added. Shown above the list until dismissed.
    private(set) var notice: String?
    /// Passwords typed during this session, tried on every PDF that is added. They are kept in memory only.
    private var typedPasswords: [String] = []
    /// True while the password window is open.
    var isAskingForPassword = false
    /// A message in the password window, such as "That password opened 1 of 3 files."
    private(set) var passwordMessage: String?
    /// The result of the last install. Shown above the list until dismissed.
    private(set) var toolNotice: String?
    /// The code models that are downloaded, and whether Ollama itself is installed.
    private(set) var installedModels: Set<String> = []
    private(set) var ollamaInstalled = false

    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var waiting: [UUID] = []
    /// How many formats each kind of file could become with every tool installed. It never changes while the app runs.
    @ObservationIgnored private var allTargetCounts: [String: Int] = [:]
    /// How many conversions run at once. It follows this Mac's processor cores.
    static let maxConcurrent = ResourcePlan.parallelConversions()

    init() {
        refreshTools()
        // Work folders left by a run that quit in the middle of a conversion can be large, so clear the old ones.
        Task.detached(priority: .background) { Converter.removeStaleWork() }
    }

    var hasItems: Bool { !items.isEmpty }
    var anyBusy: Bool { items.contains { $0.isBusy } }
    var convertingCount: Int { items.filter(\.isBusy).count }
    /// True when Convert All has something to start. Files added during a conversion join the queue.
    var hasConvertibleItems: Bool {
        items.contains { $0.phase == .ready && $0.selectedTarget != nil && !$0.isBlocked && !$0.needsCustomSize }
    }
    var missingFeatures: [FeatureState] { features.filter { !$0.installed } }
    var isInstalling: Bool { !installSteps.isEmpty }
    func isInstalling(_ id: String) -> Bool { installSteps[id] != nil }
    /// What the status bar says: the step when one install runs, and a count when several do.
    var installSummary: String {
        switch installSteps.count {
        case 0: return ""
        case 1: return installSteps.values.first ?? "Installing…"
        default: return "Installing \(installSteps.count) things at once…"
        }
    }
    private var runningCount: Int { items.filter { $0.phase == .converting }.count }

    /// Whether a conversion tool is installed. The menus offer only conversions that can run now.
    /// Answers are remembered for the life of the closure, because one route search asks about each tool many times.
    private var usable: (Engine) -> Bool {
        let locator = ToolLocator()
        var known: [Engine: Bool] = [:]
        return { engine in
            if let answer = known[engine] { return answer }
            let answer = locator.isAvailable(engine)
            known[engine] = answer
            return answer
        }
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
                var item = Item(file: detected, targets: targets, selectedTargetID: targets.first?.id)
                item.size = Preflight.fileSize(url)
                if detected.formatID == "pdf" { item.lock = .checking }
                items.append(item)
                if item.lock == .checking { openPDF(item.id) }
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
        for item in items where ids.contains(item.id) { discardCopy(of: item) }
        waiting.removeAll { ids.contains($0) }
        items.removeAll { ids.contains($0.id) }
        // A removed file that was converting frees its place, so the next waiting file can start.
        startWaiting()
    }

    func remove(_ id: UUID) {
        remove([id])
    }

    /// Removes files that are finished, failed or cancelled. Files still waiting or converting stay.
    func clearFinished() {
        for item in items where !item.isBusy && item.phase != .ready { discardCopy(of: item) }
        items.removeAll { !$0.isBusy && $0.phase != .ready }
    }

    func select(_ targetID: String?, for id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].selectedTargetID = targetID
        items[index].phase = .ready
        refreshFindings(only: id)
    }

    /// Where a file's result is saved: the Settings folder, or next to the original.
    func outputDirectory(for url: URL) -> URL {
        AppSettings.outputFolder ?? url.deletingLastPathComponent()
    }

    /// Recalculates the notes for one file, or for every file. Called when files are added, formats change, or
    /// tools change.
    func refreshFindings(only id: UUID? = nil) {
        let python = Converter.fontPython(tools: ToolLocator())
        let locator = ToolLocator()
        for index in items.indices where id == nil || items[index].id == id {
            let file = items[index].effectiveFile
            var findings: [Finding] = []
            switch items[index].lock {
            case .checking:
                findings.append(Finding(severity: .blocking, message: "Checking whether this PDF has a password…"))
            case .needsPassword:
                findings.append(Finding(severity: .blocking, message: "This PDF has a password. Enter it to open the file."))
            default:
                if let target = items[index].selectedTarget {
                    findings = Preflight.findings(for: file, target: target,
                                                  outputFolder: outputDirectory(for: items[index].file.url),
                                                  tools: locator, fontPython: python)
                }
            }
            // Formats that would appear if the optional tools were installed.
            let everything = allTargetCount(for: file)
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

    private func allTargetCount(for file: DetectedFile) -> Int {
        let key = "\(file.category.rawValue)/\(file.formatID)"
        if let known = allTargetCounts[key] { return known }
        let count = FormatCatalog.targets(for: file).count
        allTargetCounts[key] = count
        return count
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
              items[index].selectedTarget != nil,
              !items[index].needsCustomSize else { return }
        refreshFindings(only: id)
        guard !items[index].isBlocked else { return }
        items[index].phase = .queued
        items[index].log = []
        items[index].notes = []
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
        let file = items[index].effectiveFile
        items[index].phase = .converting
        let request = ConversionRequest(input: file, route: target,
                                        outputDirectory: outputDirectory(for: items[index].file.url),
                                        pdfCompression: items[index].compressionValue ?? .medium,
                                        imageAdjustments: items[index].imageEdits.adjustments ?? .unchanged)
        let converter = Converter(ollama: OllamaClient(model: AppSettings.ollamaModel),
                                  repairAttempts: AppSettings.repairAttempts,
                                  pageOutput: AppSettings.pageOutput,
                                  progress: { [weak self] update in
                                      Task { @MainActor in self?.setProgress(id, update) }
                                  })

        tasks[id] = Task { [weak self] in
            do {
                let result = try await converter.convert(request)
                self?.finish(id, phase: .finished(result.outputURL, result.validation), log: result.log,
                             notes: result.notes)
            } catch {
                if Task.isCancelled {
                    self?.finish(id, phase: .cancelled, log: [])
                } else {
                    self?.finish(id, phase: .failed(error.localizedDescription), log: [])
                }
            }
        }
    }

    // MARK: PDF passwords

    var lockedCount: Int { items.filter { $0.lock == .needsPassword }.count }

    /// Opens a PDF that was just added. One that only has restrictions opens at once. A password typed earlier is tried
    /// first. Otherwise the password window asks. The work runs off the main thread, because a large PDF takes a while.
    private func openPDF(_ id: UUID) {
        guard let url = items.first(where: { $0.id == id })?.file.url else { return }
        let passwords = typedPasswords
        Task { [weak self] in
            let opened = await Task.detached { PDFUnlocker.open(url, trying: passwords) }.value
            self?.finishOpening(id, opened)
        }
    }

    private func finishOpening(_ id: UUID, _ opened: PDFUnlocker.Opened) {
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            if case .unlocked(let copy, _) = opened { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }
            return
        }
        switch opened {
        case .notProtected: items[index].lock = .none
        case .unlocked(let copy, _): items[index].lock = .unlocked(copy)
        case .needsPassword:
            items[index].lock = .needsPassword
            isAskingForPassword = true
        }
        refreshFindings(only: id)
    }

    /// Tries one password on every PDF that is waiting for one. Files it does not open stay locked.
    func unlockPDFs(password: String) async {
        let waiting = items.filter { $0.lock == .needsPassword }.map { ($0.id, $0.file.url) }
        guard !waiting.isEmpty else { isAskingForPassword = false; return }
        let results = await Task.detached {
            waiting.map { ($0.0, PDFUnlocker.open($0.1, password: password)) }
        }.value
        var opened = 0
        for (id, result) in results {
            guard let result else { continue }
            finishOpening(id, result)
            opened += 1
        }
        if opened > 0 && !typedPasswords.contains(password) { typedPasswords.append(password) }
        let remaining = lockedCount
        if remaining == 0 {
            passwordMessage = nil
            isAskingForPassword = false
        } else if opened == 0 {
            passwordMessage = "That password does not open \(remaining == 1 ? "this PDF" : "these PDFs")."
        } else {
            passwordMessage = "That password opened \(opened) of \(waiting.count). Enter the password for the other \(remaining)."
        }
    }

    func askForPassword() {
        passwordMessage = nil
        isAskingForPassword = true
    }

    func stopAskingForPassword() {
        passwordMessage = nil
        isAskingForPassword = false
    }

    /// Saves a copy of an opened PDF without its password, next to the original or in the output folder.
    func saveUnlockedCopy(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }), case .unlocked(let copy) = item.lock else { return }
        let folder = outputDirectory(for: item.file.url)
        let stem = item.file.url.deletingPathExtension().lastPathComponent + " (unlocked)"
        let destination = OutputNaming.uniqueURL(stem: stem, ext: "pdf", in: folder)
        do {
            try FileManager.default.copyItem(at: copy, to: destination)
            addToolNotice("Saved \(destination.lastPathComponent) without its password.")
            reveal(destination)
        } catch {
            notice = "Could not save the unlocked copy: \(error.localizedDescription)"
        }
    }

    private func discardCopy(of item: Item) {
        guard case .unlocked(let copy) = item.lock else { return }
        try? FileManager.default.removeItem(at: copy.deletingLastPathComponent())
    }

    // MARK: Merge

    /// What the files in the queue could be merged into. Empty until two files of the same kind are in the queue.
    var mergeGroups: [MergeGroup] {
        MergePlanner.groups(for: items.filter { $0.lock == .none || $0.isUnlocked }.map(\.effectiveFile))
    }
    var canMerge: Bool { !mergeGroups.isEmpty }

    /// A merge window for the files in the queue, or nil when nothing can be merged.
    func makeMergeSession() -> MergeSession? {
        let groups = mergeGroups
        guard let first = groups.first?.files.first else { return nil }
        // An unlocked copy lives in a temporary folder, so the result goes next to the original instead.
        let original = items.first { $0.effectiveFile.url == first.url }?.file.url ?? first.url
        return MergeSession(groups: groups, outputFolder: outputDirectory(for: original))
    }

    /// Converts every file that has a format chosen and is not already done.
    func convertAll() {
        for item in items where item.phase == .ready && item.selectedTarget != nil && !item.isBlocked {
            convert(item.id)
        }
    }

    /// Changes the adjustments of one picture. Nothing changes while the file is converting.
    func editImage(_ id: UUID, _ change: (inout ImageEdits) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }), !items[index].isBusy else { return }
        change(&items[index].imageEdits)
        reopen(index)
    }

    /// A changed setting means the last result is out of date, so the row offers Convert again.
    private func reopen(_ index: Int) {
        switch items[index].phase {
        case .finished, .failed, .cancelled:
            items[index].phase = .ready
            items[index].notes = []
        case .ready, .queued, .converting:
            break
        }
    }

    /// Chooses how hard a PDF is compressed. Nothing changes while the file is converting.
    func setCompression(_ choice: PDFCompressionChoice, for id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }), !items[index].isBusy else { return }
        items[index].compression = choice
        reopen(index)
    }

    /// Sets the size for the custom compression level, as typed.
    func setCustomSize(_ text: String, for id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }), !items[index].isBusy else { return }
        items[index].customSize = text
        reopen(index)
    }

    /// Stops every running conversion. Used when the app quits, so no tool keeps running without it.
    func cancelAll() {
        waiting.removeAll()
        for task in tasks.values { task.cancel() }
    }

    func cancel(_ id: UUID) {
        if waiting.contains(id) {
            waiting.removeAll { $0 == id }
            if let index = items.firstIndex(where: { $0.id == id }) { items[index].phase = .cancelled }
        } else {
            tasks[id]?.cancel()
        }
    }

    private func setProgress(_ id: UUID, _ update: ConversionProgress) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].progress = update
    }

    private func finish(_ id: UUID, phase: Phase, log: [String], notes: [String] = []) {
        tasks[id] = nil
        // A place is free whether or not the file is still in the list. Without this, removing a file that was
        // converting would leave the files waiting behind it stuck.
        defer { startWaiting() }
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].phase = phase
        items[index].progress = nil
        items[index].log = log
        items[index].notes = notes
        if case .finished(let url, _) = phase {
            if UserDefaults.standard.bool(forKey: SettingsKey.revealWhenDone) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            notifyIfInBackground(title: "Saved \(url.lastPathComponent)")
        }
    }

    // MARK: Tools

    func refreshTools() {
        let locator = ToolLocator()
        features = ToolFeature.all.map { FeatureState(feature: $0, installed: $0.isInstalled(locator)) }
        homebrewInstalled = locator.locate(["brew"]) != nil
        ollamaInstalled = locator.locate(["ollama"]) != nil
        installedModels = Set(CodeModels.catalog.filter(\.isInstalled).map(\.name))
    }

    /// Downloads one code model through Ollama. It runs next to any installs, and next to other downloads.
    func installModel(_ entry: CodeModel) {
        let id = "model:\(entry.name)"
        guard !isInstalling(id) else { return }
        installSteps[id] = "Starting…"
        Task { [weak self] in
            do {
                _ = try await ToolInstaller.pullModel(entry.name, tools: ToolLocator()) { step in
                    Task { @MainActor in self?.setInstallStep(id, step) }
                }
                self?.addToolNotice("\(entry.title) is downloaded. Choose it in Settings → Code to use it.")
            } catch {
                self?.addToolNotice("\(entry.title) could not be downloaded. \(error.localizedDescription)")
            }
            self?.finishInstall(id)
        }
    }

    /// Installs one optional feature with Homebrew. Several features can be installed at once: their downloads run side
    /// by side, and the installs themselves take turns.
    func install(_ state: FeatureState) {
        guard !isInstalling(state.id) else { return }
        installSteps[state.id] = "Starting…"
        let feature = state.feature
        let id = state.id
        let codeModel = AppSettings.ollamaModel
        Task { [weak self] in
            do {
                _ = try await ToolInstaller.install(feature, tools: ToolLocator(), codeModel: codeModel) { step in
                    Task { @MainActor in self?.setInstallStep(id, step) }
                }
                self?.addToolNotice("\(feature.title) is ready. Its formats now appear in the menus.")
            } catch {
                self?.addToolNotice("\(feature.title) could not be installed. \(error.localizedDescription)")
            }
            self?.finishInstall(id)
        }
    }

    /// What removing a feature would take away, for the confirmation. Nothing is removed yet.
    func removalPlan(_ state: FeatureState) async -> RemovalPlan {
        let feature = state.feature
        return await Task.detached { await ToolInstaller.removalPlan(for: feature, tools: ToolLocator()) }.value
    }

    /// Says why a group cannot be removed, when none of it was installed by Homebrew.
    func noteNotRemovable(_ state: FeatureState) {
        addToolNotice("\(state.feature.title) was not installed by Homebrew, so Universal Converter cannot remove it. Remove it the way you installed it.")
    }

    /// Removes a feature after the user confirmed. It takes its turn with installs, because both change Homebrew's folders.
    func uninstall(_ state: FeatureState, plan: RemovalPlan) {
        guard !isInstalling(state.id) else { return }
        installSteps[state.id] = "Removing…"
        let feature = state.feature
        let id = state.id
        Task { [weak self] in
            do {
                _ = try await ToolInstaller.uninstall(feature, tools: ToolLocator(), plan: plan) { step in
                    Task { @MainActor in self?.setInstallStep(id, step) }
                }
                self?.addToolNotice("\(feature.title) was removed, and its downloaded files were deleted.")
            } catch {
                self?.addToolNotice("\(feature.title) could not be removed. \(error.localizedDescription)")
            }
            self?.finishInstall(id)
        }
    }

    /// Deletes one downloaded code model after the user confirmed.
    func removeModel(_ entry: CodeModel) {
        let id = "model:\(entry.name)"
        guard !isInstalling(id) else { return }
        installSteps[id] = "Removing…"
        Task { [weak self] in
            do {
                _ = try await ToolInstaller.removeModel(entry.name, tools: ToolLocator())
                self?.addToolNotice("\(entry.title) was removed.")
            } catch {
                self?.addToolNotice("\(entry.title) could not be removed. \(error.localizedDescription)")
            }
            self?.finishInstall(id)
        }
    }

    /// Installs every feature that is not installed yet, all at once.
    func installAllMissing() {
        for state in missingFeatures where !isInstalling(state.id) { install(state) }
    }

    private func setInstallStep(_ id: String, _ step: String) {
        // A late update from an install that has already finished must not bring it back.
        guard installSteps[id] != nil else { return }
        installSteps[id] = step
    }

    private func finishInstall(_ id: String) {
        installSteps[id] = nil
        refreshTools()
        rebuildTargets()
    }

    /// Results of installs that finish near each other are all kept, one per line, until dismissed.
    private func addToolNotice(_ message: String) {
        toolNotice = [toolNotice, message].compactMap { $0 }.joined(separator: "\n")
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
        let names = ["documents/sample.pdf", "documents/sample.docx", "video/sample.mp4", "images/sample.png",
                     "code/hello.py", "video/silent.mp4", "audio/sample.mp3", "markup/sample.md"]
        add(names.map { folder.appendingPathComponent($0) })
        func choose(_ index: Int, _ id: String) {
            if items.indices.contains(index) { select(id, for: items[index].id) }
        }
        choose(0, "pdf"); choose(2, "gif"); choose(3, "jpg"); choose(4, "java")
        choose(5, "mp3"); choose(7, "pdf")
        if items.count > 4 {
            items[4].phase = .finished(folder.appendingPathComponent("code/hello.py"), .passed(checker: "javac"))
        }
        if items.count > 5 {
            items[5].phase = .failed("silent.mp4 has no sound track, so there is no audio to save as MP3 audio.")
        }
        if items.count > 2 {
            items[2].phase = .converting
            items[2].progress = ConversionProgress("Converting", fraction: 0.45)
        }
        if items.count > 6 { items[6].phase = .converting }
        // Several installs at once, as the Tools tab shows them.
        installSteps = ["video": "Downloading…", "office": "Waiting for another install to finish…", "markdown": "Installing pandoc…"]
    }
}
