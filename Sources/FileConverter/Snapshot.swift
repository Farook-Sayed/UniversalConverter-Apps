import AppKit
import SwiftUI

extension Notification.Name {
    /// Asks the main window to open Settings. Used by the snapshot tool.
    static let fcOpenSettings = Notification.Name("FCOpenSettings")
    /// Selects a Settings tab by name. Used by the snapshot tool.
    static let fcSelectSettingsTab = Notification.Name("FCSelectSettingsTab")
    /// Opens the merge window. Used by the Convert menu.
    static let fcMergeFiles = Notification.Name("FCMergeFiles")
}

/// Developer tool: saves pictures of the app's own windows, so the design can be checked without a screen
/// recording. It only runs when the FC_SNAPSHOT environment variable names an output folder.
@MainActor
enum SnapshotRunner {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["FC_SNAPSHOT"] != nil
    }

    static func run(model: AppModel) async {
        let env = ProcessInfo.processInfo.environment
        guard let folder = env["FC_SNAPSHOT"] else { return }
        let output = URL(fileURLWithPath: folder, isDirectory: true)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let suffix = env["FC_SNAPSHOT_DARK"] == "1" ? "-dark" : "-light"
        NSApp.appearance = NSAppearance(named: env["FC_SNAPSHOT_DARK"] == "1" ? .darkAqua : .aqua)

        NSApp.activate(ignoringOtherApps: true)
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        NSApp.windows.first(where: { $0.isVisible })?.makeKeyAndOrderFront(nil)
        try? await Task.sleep(nanoseconds: 400_000_000)
        save("empty\(suffix)", in: output, matching: { $0.title == "Universal Converter" })

        // Password-protected PDFs: the list, then the password window.
        if let locked = env["FC_SNAPSHOT_PROTECTED"] {
            let folder = URL(fileURLWithPath: locked, isDirectory: true)
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            model.add(files.filter { $0.pathExtension == "pdf" }.sorted { $0.path < $1.path })
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            save("locked-queue\(suffix)", in: output, matching: { $0.title == "Universal Converter" })
            let window = NSWindow(contentViewController: NSHostingController(
                rootView: PDFPasswordSheet().environment(model)))
            window.title = "Password"
            window.isReleasedWhenClosed = false
            window.makeKeyAndOrderFront(nil)
            try? await Task.sleep(nanoseconds: 900_000_000)
            save("locked-password\(suffix)", in: output, matching: { $0.title == "Password" })
            window.close()
            await model.unlockPDFs(password: "shared-pw")
            try? await Task.sleep(nanoseconds: 800_000_000)
            save("locked-after\(suffix)", in: output, matching: { $0.title == "Universal Converter" })
            model.remove(Set(model.items.map(\.id)))
        }

        if let samples = env["FC_SNAPSHOT_SAMPLES"] {
            model.loadDemo(folder: URL(fileURLWithPath: samples, isDirectory: true))
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            save("queue\(suffix)", in: output, matching: { $0.title == "Universal Converter" })

            // The picture adjustments, with every typed field showing.
            if let picture = model.items.first(where: \.isImageTarget) {
                model.editImage(picture.id) {
                    $0.compression = .custom
                    $0.customSize = "500 KB"
                    $0.size = .pixels
                    $0.customPixels = "1200"
                    $0.crop = .square
                    $0.removeBackground = true
                    $0.effect = .sketch
                }
                let window = NSWindow(contentViewController: NSHostingController(
                    rootView: ImageAdjustPopover(itemID: picture.id).environment(model)))
                window.title = "Adjust"
                window.isReleasedWhenClosed = false
                window.makeKeyAndOrderFront(nil)
                try? await Task.sleep(nanoseconds: 900_000_000)
                save("adjust\(suffix)", in: output, matching: { $0.title == "Adjust" })
                window.close()
                try? await Task.sleep(nanoseconds: 400_000_000)
                save("queue-adjusted\(suffix)", in: output, matching: { $0.title == "Universal Converter" })
            }
        }

        // The merge window, with the sample pictures and PDF in the queue.
        if let session = model.makeMergeSession() {
            let window = NSWindow(contentViewController: NSHostingController(
                rootView: MergeSheet(session: session).environment(model)))
            window.title = "Merge"
            window.isReleasedWhenClosed = false
            window.makeKeyAndOrderFront(nil)
            try? await Task.sleep(nanoseconds: 900_000_000)
            save("merge\(suffix)", in: output, matching: { $0.title == "Merge" })
            // With FC_SNAPSHOT_HOLD set the window stays up, so a real screen capture can be taken of it.
            if let hold = env["FC_SNAPSHOT_HOLD"], let seconds = Double(hold) {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            }
            window.close()
            try? await Task.sleep(nanoseconds: 300_000_000)
        }

        NotificationCenter.default.post(name: .fcOpenSettings, object: nil)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        for tab in ["general", "code", "tools"] {
            NotificationCenter.default.post(name: .fcSelectSettingsTab, object: tab)
            try? await Task.sleep(nanoseconds: 700_000_000)
            save("settings-\(tab)\(suffix)", in: output,
                 matching: { $0.title != "Universal Converter" && $0.isVisible })
        }
        NSApp.terminate(nil)
    }

    private static func save(_ name: String, in folder: URL, matching: (NSWindow) -> Bool) {
        let windows = NSApp.windows.filter { $0.isVisible && $0.contentView != nil }
        guard let window = windows.first(where: matching) ?? windows.first,
              let frame = window.contentView?.superview else { return }
        guard let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { return }
        frame.cacheDisplay(in: frame.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("\(name).png"))
    }
}
