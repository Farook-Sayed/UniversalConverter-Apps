import Foundation

/// How much this Mac's hardware is used. The numbers follow the processor cores, so a small Mac is not overloaded
/// and a big one is not left idle.
public enum ResourcePlan {
    /// Downloads that run side by side. A download waits on the network, not on the processor, so a few at once keep
    /// a fast connection busy. More than this only makes each one slower.
    public static let parallelDownloads = 4

    /// The batches one tool's download is cut into. Newer Homebrew already downloads several packages at once, so two
    /// is enough; an older one downloads one package at a time, and two batches double its speed.
    public static let downloadBatchesPerFeature = 2

    /// Conversions that run side by side: one for every three cores, between two and four. Two always run, so one
    /// can read or write files while the other uses the processor.
    public static func parallelConversions(cores: Int = ProcessInfo.processInfo.activeProcessorCount) -> Int {
        max(2, min(4, cores / 3))
    }

    /// The processor threads each conversion may use, so that the conversions running together share the cores
    /// instead of all asking for every one of them.
    public static func threadsPerConversion(cores: Int = ProcessInfo.processInfo.activeProcessorCount,
                                            parallel: Int = parallelConversions()) -> Int {
        max(2, cores / max(parallel, 1))
    }
}

/// Hands out a fixed number of slots. Waiting is asynchronous, and a task that is cancelled while it waits stops waiting.
public actor AsyncSemaphore {
    private var available: Int
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []

    public init(_ count: Int) {
        available = max(count, 1)
    }

    /// True when a slot is free right now.
    public var hasFreeSlot: Bool { available > 0 }

    public func acquire() async throws {
        try Task.checkCancellation()
        if available > 0 {
            available -= 1
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append((id, continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    public func release() {
        if waiters.isEmpty {
            available += 1
        } else {
            // The slot goes straight to the task that has waited longest.
            waiters.removeFirst().continuation.resume()
        }
    }

    /// Runs `body` while holding a slot. `onWait` is called first when no slot is free, so the caller can say it is waiting.
    public func withSlot<T: Sendable>(onWait: (@Sendable () -> Void)? = nil,
                                      _ body: @Sendable () async throws -> T) async throws -> T {
        if available == 0 { onWait?() }
        try await acquire()
        do {
            let result = try await body()
            release()
            return result
        } catch {
            release()
            throw error
        }
    }
}

/// Remembers which downloads have been started, so two features that need the same dependency download it only once.
/// The second feature waits for the first one's download instead of starting its own.
public actor DownloadLedger {
    private var tasks: [String: Task<Void, Never>] = [:]

    /// Starts a download for every name that nobody has started yet, in up to `groups` batches that run side by side,
    /// and returns every download that carries one of `names`, including ones another caller already started.
    /// `kind` keeps formulae and casks apart, because they can share a name.
    public func reserve(_ names: [String], groups: Int, kind: String,
                        fetch: @escaping @Sendable ([String]) async -> Void) -> [Task<Void, Never>] {
        let fresh = names.filter { tasks[kind + ":" + $0] == nil }
        let count = max(1, min(groups, fresh.count))
        for index in 0..<count {
            // Names are dealt out like cards, so every batch gets about the same number of packages.
            let batch = fresh.enumerated().filter { $0.offset % count == index }.map(\.element)
            guard !batch.isEmpty else { continue }
            let task = Task { await fetch(batch) }
            for name in batch { tasks[kind + ":" + name] = task }
        }
        var seen = Set<Task<Void, Never>>()
        return names.compactMap { tasks[kind + ":" + $0] }.filter { seen.insert($0).inserted }
    }
}

/// Decides what may run at the same time while tools are installed.
///
/// Downloads only use the network, so several run together. Installing changes Homebrew's own folders, and two installs
/// that share a dependency collide ("Bottle destination already exists"), so installs take turns. Because the files
/// are already downloaded when an install starts, each one is short.
public final class InstallCoordinator: Sendable {
    public static let shared = InstallCoordinator()

    public let downloads: AsyncSemaphore
    public let installs: AsyncSemaphore
    public let ledger = DownloadLedger()

    public init(downloadSlots: Int = ResourcePlan.parallelDownloads) {
        downloads = AsyncSemaphore(downloadSlots)
        installs = AsyncSemaphore(1)
    }
}
