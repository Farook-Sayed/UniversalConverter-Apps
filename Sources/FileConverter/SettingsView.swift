import SwiftUI
import AppKit
import ConverterCore

/// Settings window (⌘,). Three tabs: General, Code and Tools.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(SettingsKey.outputFolder) private var outputFolder = ""
    @AppStorage(SettingsKey.ollamaModel) private var ollamaModel = "qwen2.5-coder:7b"
    @AppStorage(SettingsKey.repairCode) private var repairCode = true
    @AppStorage(SettingsKey.revealWhenDone) private var revealWhenDone = false
    @AppStorage(SettingsKey.notifyWhenDone) private var notifyWhenDone = true

    enum Tab: String { case general, code, tools }
    @State private var tab = Tab.general

    var body: some View {
        TabView(selection: $tab) {
            general
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(Tab.general)
            code
                .tabItem { Label("Code", systemImage: "chevron.left.forwardslash.chevron.right") }
                .tag(Tab.code)
            tools
                .tabItem { Label("Tools", systemImage: "wrench.and.screwdriver") }
                .tag(Tab.tools)
        }
        .frame(width: 540, height: 380)
        .onReceive(NotificationCenter.default.publisher(for: .fcSelectSettingsTab)) { note in
            if let name = note.object as? String, let selected = Tab(rawValue: name) { tab = selected }
        }
    }

    private var general: some View {
        Form {
            Section("Where results are saved") {
                LabeledContent("Folder") {
                    Text(outputFolder.isEmpty ? "Next to each original file" : outputFolder)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("Choose Folder…", action: chooseFolder)
                    Button("Next to Originals") { outputFolder = "" }
                        .disabled(outputFolder.isEmpty)
                }
            }
            Section("When a file is ready") {
                Toggle("Show the result in Finder", isOn: $revealWhenDone)
                Toggle("Notify me when a file finishes while the app is in the background", isOn: $notifyWhenDone)
                    .onChange(of: notifyWhenDone) { _, enabled in
                        if enabled { model.requestNotificationPermission() }
                    }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var code: some View {
        Form {
            Section("Model") {
                TextField("Ollama model", text: $ollamaModel)
                Text("The model must be installed in Ollama. Install it with: ollama pull \(ollamaModel)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Checks") {
                Toggle("Ask the model to fix code that fails the syntax check", isOn: $repairCode)
                Text("When this is off, the translated file is saved with its errors listed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var tools: some View {
        Form {
            Section("Installed tools") {
                ForEach(model.tools) { tool in
                    LabeledContent {
                        if tool.path != nil {
                            Label("Installed", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else {
                            Label("Not installed", systemImage: "xmark.circle.fill")
                                .foregroundStyle(.red)
                        }
                    } label: {
                        VStack(alignment: .leading) {
                            Text(tool.name)
                            Text(tool.purpose).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section {
                Button("Recheck Tools") { model.refreshTools() }
            } footer: {
                Text("Install missing tools with Homebrew. The user guide lists the commands.")
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            outputFolder = url.path
        }
    }
}
