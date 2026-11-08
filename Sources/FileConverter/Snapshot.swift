import AppKit
import SwiftUI

extension Notification.Name {
    /// Asks the main window to open Settings. Used by the snapshot tool.
    static let fcOpenSettings = Notification.Name("FCOpenSettings")
    /// Selects a Settings tab by name. Used by the snapshot tool.
    static let fcSelectSettingsTab = Notification.Name("FCSelectSettingsTab")
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

        if let samples = env["FC_SNAPSHOT_SAMPLES"] {
            model.loadDemo(folder: URL(fileURLWithPath: samples, isDirectory: true))
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            save("queue\(suffix)", in: output, matching: { $0.title == "Universal Converter" })
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
