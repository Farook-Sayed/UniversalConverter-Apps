import SwiftUI
import AppKit
import ConverterCore

/// The tabs of the Settings window.
enum SettingsTab: String {
    case general, code, tools
}

/// Settings (⌘,). Three tabs: General, Code and Tools.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(SettingsKey.outputFolder) private var outputFolder = ""
    @AppStorage(SettingsKey.ollamaModel) private var ollamaModel = "qwen2.5-coder:7b"
    @AppStorage(SettingsKey.repairCode) private var repairCode = true
    @AppStorage(SettingsKey.revealWhenDone) private var revealWhenDone = false
    @AppStorage(SettingsKey.notifyWhenDone) private var notifyWhenDone = true
    @AppStorage(SettingsKey.settingsTab) private var tabName = SettingsTab.general.rawValue

    private var tab: Binding<SettingsTab> {
        Binding(get: { SettingsTab(rawValue: tabName) ?? .general },
                set: { tabName = $0.rawValue })
    }

    var body: some View {
        TabView(selection: tab) {
            general
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            code
                .tabItem { Label("Code", systemImage: "chevron.left.forwardslash.chevron.right") }
                .tag(SettingsTab.code)
            tools
                .tabItem { Label("Tools", systemImage: "wrench.and.screwdriver") }
                .tag(SettingsTab.tools)
        }
        .frame(width: 540, height: 440)
        .onReceive(NotificationCenter.default.publisher(for: .fcSelectSettingsTab)) { note in
            if let name = note.object as? String { tabName = name }
        }
        .onAppear { model.refreshTools() }
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
                Text("Code translation uses this model. Install it from the Tools tab, or with: ollama pull \(ollamaModel)")
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
            Section {
                Label("Images (PNG, JPEG, TIFF, GIF, BMP), Word and text (DOCX, DOC, RTF, HTML, TXT), audio (WAV, M4A) and archives (ZIP, TAR, TAR.GZ).", systemImage: "checkmark.seal")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            } header: {
                Text("Works now")
            } footer: {
                Text("These use tools that come with macOS. Nothing needs installing.")
            }

            Section {
                ForEach(model.features) { state in
                    FeatureRow(state: state, busyElsewhere: model.isInstalling && model.installingID != state.id)
                }
            } header: {
                Text("Add more formats")
            } footer: {
                if model.homebrewInstalled {
                    Text("Installs use Homebrew and run in the background. Large downloads can take a while.")
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("These installs use Homebrew, a free package manager. Install it once, then come back here.")
                        Link("Get Homebrew", destination: URL(string: "https://brew.sh")!)
                    }
                }
            }

            Section {
                Button("Check Again") {
                    model.refreshTools()
                    model.rebuildTargets()
                }
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

/// One optional feature: what it adds, how big it is, and an Install button or a check mark.
struct FeatureRow: View {
    @Environment(AppModel.self) private var model
    let state: FeatureState
    let busyElsewhere: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(state.feature.title)
                    .font(.body.weight(.medium))
                Text(state.feature.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(state.feature.size)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 12)
            if model.installingID == state.id {
                ProgressView()
                    .controlSize(.small)
                    .help(model.installStep ?? "Installing…")
            } else if state.installed {
                Label("Installed", systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.green)
                    .font(.callout)
            } else {
                Button("Install") { model.install(state) }
                    .disabled(busyElsewhere || !model.homebrewInstalled)
            }
        }
        .padding(.vertical, 2)
    }
}
