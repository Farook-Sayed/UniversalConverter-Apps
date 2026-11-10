import SwiftUI
import AppKit
import ConverterCore

@main
struct FileConverterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    init() {
        AppSettings.register()
    }

    var body: some Scene {
        WindowGroup("Universal Converter") {
            ContentView()
                .environment(model)
                .onAppear {
                    appDelegate.attach(model)
                    if UserDefaults.standard.bool(forKey: SettingsKey.notifyWhenDone) {
                        model.requestNotificationPermission()
                    }
                }
                .task {
                    if SnapshotRunner.isRequested { await SnapshotRunner.run(model: model) }
                }
        }
        .defaultSize(width: 680, height: 560)
        .windowResizability(.contentMinSize)
        .commands {
            AppCommands(model: model)
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

/// Receives files from Finder ("Open With" and drops on the Dock icon) and passes them to the model.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var pending: [URL] = []

    func attach(_ model: AppModel) {
        self.model = model
        if !pending.isEmpty {
            model.add(pending)
            pending = []
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if let model {
            model.add(urls)
        } else {
            pending.append(contentsOf: urls)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Quitting stops the conversions that are running, so ask first.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // The snapshot tool quits on its own, and nobody is there to answer.
        guard let model, model.anyBusy, !SnapshotRunner.isRequested else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Quit while files are converting?"
        alert.informativeText = "Conversions that are still running will be stopped, and their results will not be saved."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    /// A tool such as FFmpeg would otherwise keep running after the app is gone.
    func applicationWillTerminate(_ notification: Notification) {
        model?.cancelAll()
    }
}

/// The menu bar: File, Convert, About and Help.
struct AppCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Universal Converter") {
                NSApp.orderFrontStandardAboutPanel(options: [
                    .applicationName: "Universal Converter",
                    .credits: AboutText.credits,
                ])
            }
        }

        CommandGroup(replacing: .newItem) {
            Button("Open…") {
                model.showOpenPanel()
            }
            .keyboardShortcut("o", modifiers: .command)
        }

        CommandMenu("Convert") {
            Button("Convert All") {
                model.convertAll()
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(!model.hasConvertibleItems)

            Button("Merge Files…") {
                NotificationCenter.default.post(name: .fcMergeFiles, object: nil)
            }
            .keyboardShortcut("m", modifiers: [.command, .shift])
            .disabled(!model.canMerge)

            Divider()

            Button("Clear Finished") {
                model.clearFinished()
            }
            .disabled(!model.hasItems)
        }

        CommandGroup(replacing: .help) {
            Button("Universal Converter Guide") {
                if let guide = Bundle.main.url(forResource: "GUIDE", withExtension: "md") {
                    NSWorkspace.shared.open(guide)
                }
            }
        }
    }
}

/// The About window text. Each tool keeps its own license.
enum AboutText {
    static var credits: NSAttributedString {
        let text = """
        Converts files on this Mac with the tools you install through Homebrew: FFmpeg, ImageMagick, LibreOffice, Pandoc, 7-Zip, fontTools and Ollama.

        Code translation uses a model that runs locally through Ollama. Nothing is uploaded.

        Each tool is licensed by its own authors.
        """
        return NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.labelColor,
        ])
    }
}
