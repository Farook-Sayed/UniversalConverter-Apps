import SwiftUI
import AppKit
import ConverterCore

/// One merge window: which files are joined, in what order, and how the merge is going. The window works on a copy of the
/// queue's files, so changing the order here never changes the queue.
@MainActor @Observable
final class MergeSession: Identifiable {
    enum State {
        case setup
        case running(ConversionProgress?)
        case finished(URL, [String])
        case failed(String)
    }

    let id = UUID()
    let groups: [MergeGroup]
    private(set) var kind: MergeKind
    /// The files of the chosen kind, in the order they are joined.
    private(set) var files: [DetectedFile]
    var targetID: String
    var pageSize: MergePageSize = .a4
    var name = "Merged"
    private(set) var state: State = .setup
    private var task: Task<Void, Never>?
    private let outputFolder: URL

    init(groups: [MergeGroup], outputFolder: URL) {
        precondition(!groups.isEmpty, "a merge needs a group")
        self.groups = groups
        self.outputFolder = outputFolder
        kind = groups[0].kind
        files = groups[0].files
        targetID = MergePlanner.suggestedTarget(for: groups[0])?.id ?? ""
    }

    var group: MergeGroup { groups.first { $0.kind == kind } ?? groups[0] }
    var target: OutputFormat? { group.targets.first { $0.id == targetID } ?? group.targets.first }

    /// The tool the chosen merge needs, when it is not installed.
    var missingTool: String? {
        guard let engine = group.engine, !ToolLocator().isAvailable(engine) else { return nil }
        switch engine {
        case .ffmpeg: return "FFmpeg"
        case .pandoc: return "Pandoc"
        default: return "A tool"
        }
    }

    var canStart: Bool {
        guard case .setup = state else { return false }
        return files.count >= 2 && missingTool == nil && !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var isRunning: Bool { if case .running = state { return true } else { return false } }

    func choose(_ newKind: MergeKind) {
        guard newKind != kind, let next = groups.first(where: { $0.kind == newKind }) else { return }
        kind = newKind
        files = next.files
        targetID = MergePlanner.suggestedTarget(for: next)?.id ?? ""
    }

    func move(from offsets: IndexSet, to destination: Int) {
        files.move(fromOffsets: offsets, toOffset: destination)
    }

    func moveUp(_ index: Int) {
        guard index > 0, index < files.count else { return }
        files.swapAt(index, index - 1)
    }

    func moveDown(_ index: Int) {
        guard index >= 0, index < files.count - 1 else { return }
        files.swapAt(index, index + 1)
    }

    func remove(_ index: Int) {
        guard files.indices.contains(index) else { return }
        files.remove(at: index)
    }

    func start() {
        guard canStart, let target else { return }
        state = .running(nil)
        let request = MergeRequest(kind: kind, inputs: files, target: target, outputDirectory: outputFolder,
                                   name: name.trimmingCharacters(in: .whitespaces), pageSize: pageSize)
        let converter = Converter(progress: { [weak self] update in
            Task { @MainActor in
                guard let self, case .running = self.state else { return }
                self.state = .running(update)
            }
        })
        task = Task { [weak self] in
            do {
                let result = try await converter.merge(request)
                self?.state = .finished(result.outputURL, result.notes)
            } catch {
                if Task.isCancelled {
                    self?.state = .setup
                } else {
                    self?.state = .failed(error.localizedDescription)
                }
            }
        }
    }

    func cancel() {
        task?.cancel()
    }

    /// Back to the setup, after a failure, so the user can change something and try again.
    func tryAgain() {
        if case .failed = state { state = .setup }
    }
}
