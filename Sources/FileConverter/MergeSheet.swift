import SwiftUI
import AppKit
import ConverterCore

/// The window for joining several files into one: choose the order, the format and the name, then merge.
struct MergeSheet: View {
    @Bindable var session: MergeSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if session.groups.count > 1 { kindPicker }
            Text(session.group.title)
                .font(.callout)
                .foregroundStyle(.secondary)
            fileList
            options
            if let missing = session.missingTool { missingToolNotice(missing) }
            Divider()
            footer
        }
        .padding(20)
        .frame(width: 500)
        .disabled(false)
        .interactiveDismissDisabled(session.isRunning)
    }

    private var header: some View {
        Text("Merge Files")
            .font(.title2.weight(.semibold))
    }

    private var kindPicker: some View {
        Picker("Merge", selection: Binding(get: { session.kind }, set: { session.choose($0) })) {
            ForEach(session.groups) { group in
                Text(Self.name(of: group.kind)).tag(group.kind)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .disabled(!isSetup)
    }

    private static func name(of kind: MergeKind) -> String {
        switch kind {
        case .pdf: return "PDF"
        case .audio: return "Audio"
        case .video: return "Video"
        case .document: return "Document"
        }
    }

    private var isSetup: Bool { if case .setup = session.state { return true } else { return false } }

    // MARK: Order

    private var fileList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Order")
                .font(.headline)
            List {
                ForEach(Array(session.files.enumerated()), id: \.element.url) { index, file in
                    HStack(spacing: 10) {
                        Text("\(index + 1)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 20, alignment: .trailing)
                        FileThumbnail(url: file.url, size: 28)
                        Text(file.url.lastPathComponent)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        Button { session.moveUp(index) } label: { Image(systemName: "chevron.up") }
                            .disabled(index == 0 || !isSetup)
                            .help("Move up")
                        Button { session.moveDown(index) } label: { Image(systemName: "chevron.down") }
                            .disabled(index == session.files.count - 1 || !isSetup)
                            .help("Move down")
                        Button { session.remove(index) } label: { Image(systemName: "xmark.circle.fill") }
                            .disabled(session.files.count <= 2 || !isSetup)
                            .help(session.files.count <= 2 ? "A merge needs at least two files" : "Leave this file out")
                    }
                    .buttonStyle(.borderless)
                    .padding(.vertical, 1)
                }
                .onMove { source, destination in session.move(from: source, to: destination) }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .frame(height: min(CGFloat(session.files.count) * 38 + 8, 230))
            Text("Drag a file, or use the arrows, to change the order. The merged file follows this order.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: Options

    private var options: some View {
        Form {
            Picker("Save as", selection: $session.targetID) {
                ForEach(session.group.targets) { Text($0.label).tag($0.id) }
            }
            if session.kind == .pdf {
                Picker("Pictures on", selection: $session.pageSize) {
                    ForEach(MergePageSize.allCases) { Text($0.title).tag($0) }
                }
            }
            TextField("Name", text: $session.name)
        }
        .formStyle(.columns)
        .disabled(!isSetup)
    }

    private func missingToolNotice(_ tool: String) -> some View {
        HStack(spacing: 8) {
            Label("\(tool) is not installed.", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.callout)
            Spacer()
            Button("Open Tools") {
                UserDefaults.standard.set(SettingsTab.tools.rawValue, forKey: SettingsKey.settingsTab)
                openSettings()
            }
        }
    }

    // MARK: Footer

    @ViewBuilder
    private var footer: some View {
        switch session.state {
        case .setup:
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Merge") { session.start() }
                    .keyboardShortcut(.defaultAction)
                    .prominentButtonStyle(enabled: session.canStart)
                    .disabled(!session.canStart)
            }
        case .running(let update):
            VStack(alignment: .leading, spacing: 8) {
                if let fraction = update?.fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                }
                HStack {
                    Text(update?.message ?? "Merging…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let fraction = update?.fraction {
                        Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Cancel") { session.cancel() }
                }
            }
        case .finished(let url, let notes):
            VStack(alignment: .leading, spacing: 8) {
                Label("Saved \(url.lastPathComponent)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                ForEach(notes, id: \.self) { note in
                    Text(note).font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    Spacer()
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                        .prominentButtonStyle()
                }
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Label("The merge did not finish", systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                HStack {
                    Spacer()
                    Button("Close") { dismiss() }
                    Button("Change and Try Again") { session.tryAgain() }
                        .keyboardShortcut(.defaultAction)
                        .prominentButtonStyle()
                }
            }
        }
    }
}
