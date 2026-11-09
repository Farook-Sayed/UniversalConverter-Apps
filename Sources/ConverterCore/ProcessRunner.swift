import Foundation

/// Runs an external program and captures its output.
///
/// Output goes to temporary files rather than pipes. ffmpeg and LibreOffice write a lot of logging,
/// and a full pipe would block the child process. Cancelling the calling task stops the program.
public enum ProcessRunner {
    /// Six hours. A long video conversion can take a very long time, so this only stops a program that is stuck.
    public static let defaultTimeout: TimeInterval = 6 * 60 * 60

    public static func run(
        _ executable: URL,
        arguments: [String],
        environment: [String: String] = [:],
        workingDirectory: URL? = nil,
        timeout: TimeInterval = ProcessRunner.defaultTimeout,
        onOutput: (@Sendable (String) -> Void)? = nil
    ) async throws -> ProcessOutput {
        try Task.checkCancellation()

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("fc-proc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let outURL = scratch.appendingPathComponent("stdout.txt")
        let errURL = scratch.appendingPathComponent("stderr.txt")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        var env = ProcessInfo.processInfo.environment
        for (key, value) in environment { env[key] = value }
        // An app opened from Finder gets a minimal PATH. Tools installed with Homebrew start helper programs
        // such as node through PATH, so the usual install folders are added to the end.
        let knownFolders = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        env["PATH"] = (knownFolders + ToolLocator.searchDirectories.filter { !knownFolders.contains($0) })
            .joined(separator: ":")
        process.environment = env
        // Nothing reads from the app's own input, so a tool that asks a question fails at once instead of waiting.
        process.standardInput = FileHandle.nullDevice
        let outHandle = try FileHandle(forWritingTo: outURL)
        let errHandle = try FileHandle(forWritingTo: errURL)
        process.standardOutput = outHandle
        process.standardError = errHandle

        // While the program runs, its new output lines go to `onOutput`, so a caller can show progress.
        let tail: Task<Void, Never>? = onOutput.map { emit in
            Task.detached { await Self.streamLines(from: outURL, emit: emit) }
        }
        let box = ProcessBox(process)
        // The time limit. It is cancelled when the program ends, so it does not keep the process object alive.
        let watchdog = DispatchSource.makeTimerSource(queue: .global())
        watchdog.schedule(deadline: .now() + timeout)
        watchdog.setEventHandler { [weak box] in box?.terminateForTimeout() }
        watchdog.resume()
        defer { watchdog.cancel() }
        let exitCode: Int32
        do {
            exitCode = try await runProcess(process, box: box)
        } catch {
            tail?.cancel()
            _ = await tail?.value
            throw error
        }
        tail?.cancel()
        _ = await tail?.value

        try? outHandle.close()
        try? errHandle.close()
        if box.timedOut {
            throw ConversionError.timedOut(tool: executable.lastPathComponent)
        }
        // Decoded leniently: a tool's message may contain bytes that are not valid UTF-8.
        let stdout = String(decoding: (try? Data(contentsOf: outURL)) ?? Data(), as: UTF8.self)
        let stderr = String(decoding: (try? Data(contentsOf: errURL)) ?? Data(), as: UTF8.self)
        return ProcessOutput(exitCode: exitCode, stdout: stdout, stderr: stderr)
    }

    /// Reads whole lines from a file as it grows, and passes each one on. Runs until cancelled, then reads the rest.
    private static func streamLines(from file: URL, emit: @Sendable (String) -> Void) async {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return }
        defer { try? handle.close() }
        var pending = ""
        func flush(final: Bool) {
            let data = (try? handle.readToEnd()) ?? Data()
            pending += String(decoding: data, as: UTF8.self)
            var lines = pending.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            pending = lines.removeLast()
            if final, !pending.isEmpty {
                lines.append(pending)
                pending = ""
            }
            for line in lines where !line.isEmpty { emit(line) }
        }
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 250_000_000)
            flush(final: false)
        }
        flush(final: true)
    }

    /// Starts the program and waits for it to end, or stops it if this task is cancelled.
    private static func runProcess(_ process: Process, box: ProcessBox) async throws -> Int32 {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { finished in
                    continuation.resume(returning: finished.terminationStatus)
                }
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                // A cancel that arrived before the program started found nothing to stop, so check again now.
                if Task.isCancelled { box.terminateIfRunning() }
            }
        } onCancel: {
            box.terminateIfRunning()
        }
    }
}

/// Gives the cancellation handler and the timeout a way to stop a running process.
final class ProcessBox: @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    private var _timedOut = false

    init(_ process: Process) {
        self.process = process
    }

    var timedOut: Bool {
        lock.lock(); defer { lock.unlock() }
        return _timedOut
    }

    func terminateIfRunning() {
        if process.isRunning { process.terminate() }
    }

    /// Stops the process and remembers that the time limit, not the user, was the reason.
    func terminateForTimeout() {
        guard process.isRunning else { return }
        lock.lock()
        _timedOut = true
        lock.unlock()
        process.terminate()
    }
}
