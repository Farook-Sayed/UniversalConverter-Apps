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
            .safeAreaInset(edge: .top, spacing: 0) {
                if !model.missingTools.isEmpty {
                    MissingToolsBanner(missing: model.missingTools)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                StatusBar()
            }
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

/// What the window shows with no files: a short invitation, the way Apple's own apps do it.
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
                Text("Works with documents, images, video, audio, e-books, fonts, archives, 3D models and code.")
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

/// A thin bar at the bottom: how many files, what is running, and where results are saved.
struct StatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
            Spacer()
            SettingsLink {
                Label(outputText, systemImage: "folder")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Change where results are saved")
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
        return running > 0 ? "\(running) of \(total) converting" : (total == 1 ? "1 file" : "\(total) files")
    }

    private var outputText: String {
        AppSettings.outputFolder.map { "Saved in \($0.lastPathComponent)" } ?? "Saved next to the originals"
    }
}

// MARK: - Missing tools

/// Lists the tools that are missing, with a link to the Tools tab in Settings.
struct MissingToolsBanner: View {
    let missing: [ToolStatus]

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text("Not installed: \(missing.map(\.name).joined(separator: ", ")). Conversions that need them are blocked.")
                .font(.callout)
            Spacer()
            SettingsLink { Text("Open Tools…") }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassSurface(cornerRadius: 12, tint: .orange)
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }
}
