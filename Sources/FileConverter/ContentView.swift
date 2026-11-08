import SwiftUI
import AppKit
import ConverterCore

/// The main window. It shows an empty state until files are added, then a list with one row per file.
struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @State private var isTargeted = false
    @State private var selection = Set<UUID>()

    var body: some View {
        content
            .frame(minWidth: 640, minHeight: 440)
            .safeAreaInset(edge: .top, spacing: 0) { notices }
            .safeAreaInset(edge: .bottom, spacing: 0) { StatusBar() }
            .overlay { DropHighlight(isTargeted: isTargeted) }
            .dropDestination(for: URL.self) { urls, _ in
                model.add(urls)
                return !urls.isEmpty
            } isTargeted: { targeted in
                isTargeted = targeted
            }
            .navigationTitle("Universal Converter")
            .navigationSubtitle(subtitle)
            .toolbar { toolbar }
            .animation(.snappy, value: model.items.map(\.id))
            .onReceive(NotificationCenter.default.publisher(for: .fcOpenSettings)) { _ in
                openSettings()
            }
    }

    @ViewBuilder
    private var content: some View {
        if model.hasItems {
            List(selection: $selection) {
                ForEach(model.items) { item in
                    QueueRow(item: item)
                        .contextMenu { rowMenu(for: item) }
                }
            }
            .listStyle(.inset)
            .onDeleteCommand {
                model.remove(selection.isEmpty ? Set(model.items.filter { !$0.isBusy }.map(\.id)) : selection)
                selection = []
            }
        } else {
            EmptyState()
        }
    }

    /// Install results and file problems, above the list.
    @ViewBuilder
    private var notices: some View {
        if model.toolNotice != nil || model.notice != nil {
            VStack(spacing: 6) {
                if let message = model.toolNotice {
                    NoticeBanner(message: message, tint: .green, symbol: "checkmark.circle.fill") {
                        model.dismissToolNotice()
                    }
                }
                if let message = model.notice {
                    NoticeBanner(message: message, tint: .orange, symbol: "exclamationmark.circle.fill") {
                        model.dismissNotice()
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
        }
    }

    private var subtitle: String {
        let count = model.items.count
        guard count > 0 else { return "" }
        return count == 1 ? "1 file" : "\(count) files"
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                model.showOpenPanel()
            } label: {
                Label("Add Files", systemImage: "plus")
            }
            .help("Add files (⌘O)")
        }
        // Actions that need files only appear once there are files, as in Apple's own apps.
        if model.hasItems {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.convertAll()
                } label: {
                    Label("Convert All", systemImage: "arrow.triangle.2.circlepath")
                        .labelStyle(.titleAndIcon)
                }
                .prominentButtonStyle()
                .help("Convert every file that has a format chosen (⇧⌘R)")
                .disabled(model.anyBusy)
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Clear Finished") { model.clearFinished() }
                    Button("Remove All", role: .destructive) { model.remove(Set(model.items.map(\.id))) }
                        .disabled(model.anyBusy)
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .help("More actions")
            }
        }
    }

    // MARK: Row context menu

    @ViewBuilder
    private func rowMenu(for item: AppModel.Item) -> some View {
        switch item.phase {
        case .converting, .queued:
            Button("Cancel") { model.cancel(item.id) }
        case .finished(let url, _):
            Button("Show in Finder") { model.reveal(url) }
            Button("Convert Again") { model.convert(item.id) }
        default:
            Button("Convert") { model.convert(item.id) }
                .disabled(item.selectedTarget == nil || item.isBlocked)
        }
        Button("Show Original in Finder") { model.reveal(item.file.url) }
        Divider()
        Button("Remove from List", role: .destructive) { model.remove(item.id) }
            .disabled(item.isBusy)
    }
}

// MARK: - Empty state

/// What the window shows with no files. It says what works straight away.
struct EmptyState: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ContentUnavailableView {
            Label {
                Text("Drop files to convert")
            } icon: {
                Image(systemName: "arrow.triangle.2.circlepath.circle")
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: 64, weight: .light))
                    .foregroundStyle(.tint)
            }
        } description: {
            VStack(spacing: 10) {
                Text("The format comes from what is inside the file, so a wrong file name does not matter.")
                Text("Images, Word documents, text, audio and archives work right away. Add more formats in Settings.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        } actions: {
            Button("Choose Files…") { model.showOpenPanel() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        }
    }
}

// MARK: - Drop highlight

/// A highlight over the whole window while files are dragged onto it, like Finder and Shortcuts.
struct DropHighlight: View {
    let isTargeted: Bool

    var body: some View {
        ZStack {
            if isTargeted {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.accentColor.opacity(0.10))
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                Label("Drop to add files", systemImage: "square.and.arrow.down")
                    .font(.title3.weight(.medium))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
            }
        }
        .padding(10)
        .allowsHitTesting(false)
        .animation(.snappy(duration: 0.18), value: isTargeted)
    }
}

// MARK: - Status bar

/// One line at the bottom: how many files, what is installing, and an offer to add formats.
struct StatusBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HStack(spacing: 10) {
            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
            Spacer()
            if model.isInstalling {
                ProgressView()
                    .controlSize(.small)
                Text(model.installStep ?? "Installing…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if !model.missingFeatures.isEmpty {
                Button {
                    UserDefaults.standard.set(SettingsTab.tools.rawValue, forKey: SettingsKey.settingsTab)
                    openSettings()
                } label: {
                    Label("Add formats…", systemImage: "plus.circle")
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(Color.accentColor)
                .help("Install optional tools for more formats")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var summary: String {
        let total = model.items.count
        guard total > 0 else { return "No files" }
        let running = model.convertingCount
        if running > 0 { return "\(running) of \(total) converting" }
        return total == 1 ? "1 file" : "\(total) files"
    }
}

// MARK: - Notices

/// A message above the list, with a button to dismiss it.
struct NoticeBanner: View {
    let message: String
    let tint: Color
    let symbol: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: 10, tint: tint)
    }
}
