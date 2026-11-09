import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ConverterCore

/// One file in the list. Left to right: thumbnail, name and status, then the format menu and the action.
struct QueueRow: View {
    @Environment(AppModel.self) private var model
    let item: AppModel.Item
    @State private var showLog = false

    private var name: String { item.file.url.lastPathComponent }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
        HStack(alignment: .center, spacing: 14) {
            FileThumbnail(url: item.file.url)

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(kindLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                status
                    .padding(.top, 3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // The controls keep their width. The text column gives way instead.
            HStack(spacing: 10) {
                if !item.targets.isEmpty {
                    FormatMenu(item: item)
                }
                actionButton
                    .frame(width: 92, alignment: .trailing)
            }
            .layoutPriority(1)
        }
        // A PDF being made smaller gets its compression choice on a line of its own, under the file.
        if item.isCompressTarget && !item.isBusy {
            CompressionControl(item: item)
                .padding(.leading, 58)
        }
        // A picture gets its adjustments on a line under the file, with a button that opens the controls.
        if item.isImageTarget && !item.isBusy {
            ImageAdjustRow(item: item)
                .padding(.leading, 58)
        }
        }
        .padding(.vertical, 8)
        .animation(.snappy, value: item.phase)
        .accessibilityElement(children: .contain)
    }

    // MARK: Text

    /// "PNG image · 2.1 MB", using the system's own name for the file type.
    private var kindLine: String {
        var kind = item.file.formatID.uppercased()
        if let name = FormatCatalog.displayName(ofFormat: item.file.formatID) {
            kind = name
        } else {
            let ext = FormatCatalog.extensions(forFormat: item.file.formatID).first ?? item.file.formatID
            if let description = UTType(filenameExtension: ext)?.localizedDescription {
                kind = description.prefix(1).uppercased() + description.dropFirst()
            }
        }
        let size = ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)
        return "\(kind) · \(size)"
    }

    // MARK: Status

    @ViewBuilder
    private var status: some View {
        switch item.phase {
        case .ready:
            FindingsLine(findings: item.findings)
        case .queued:
            HStack(spacing: 6) {
                Image(systemName: "clock")
                Text("Waiting for its turn…")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        case .converting:
            HStack(spacing: 6) {
                if let fraction = item.progress?.fraction {
                    // A measured job shows a bar and its percentage. Other jobs show a spinner.
                    ProgressView(value: fraction)
                        .frame(width: 150)
                    Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                        .monospacedDigit()
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(item.progress?.message ?? (item.selectedTarget?.engine == .ollama
                     ? "Translating with the local model…"
                     : "Converting…"))
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .accessibilityElement(children: .combine)
        case .finished(let url, let validation):
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .symbolEffect(.bounce, value: url)
                    Text("Saved as \(url.lastPathComponent)")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                if let validation {
                    ValidationNote(result: validation)
                }
                ForEach(item.notes, id: \.self) { note in
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        case .failed(let message):
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                Text(message)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            .font(.caption)
            .help(message)
        case .cancelled:
            HStack(spacing: 5) {
                Image(systemName: "xmark.circle")
                Text("Cancelled")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: Action

    @ViewBuilder
    private var actionButton: some View {
        switch item.phase {
        case .converting, .queued:
            Button("Cancel") { model.cancel(item.id) }
                .accessibilityHint("Stops this conversion")
        case .finished(let url, _):
            HStack(spacing: 8) {
                if !item.log.isEmpty {
                    Button {
                        showLog = true
                    } label: {
                        Label("Details", systemImage: "info.circle")
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Show the commands that were run")
                    .popover(isPresented: $showLog, arrowEdge: .bottom) { LogPopover(lines: item.log) }
                }
                Button {
                    model.reveal(url)
                } label: {
                    Label("Show in Finder", systemImage: "magnifyingglass")
                }
                .labelStyle(.iconOnly)
                .help("Show in Finder")
            }
        case .failed:
            Button("Retry") { model.convert(item.id) }
                .disabled(item.isBlocked)
        default:
            Button("Convert") { model.convert(item.id) }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .disabled(item.selectedTarget == nil || item.isBlocked || item.needsCustomSize)
        }
    }
}

// MARK: - Format menu

/// A pop-up menu of the formats a file can become. Direct conversions come first, then chains.
/// Every menu has the same width, so the controls line up from row to row.
struct FormatMenu: View {
    @Environment(AppModel.self) private var model
    let item: AppModel.Item

    var body: some View {
        Picker("Convert to", selection: selection) {
            if item.selectedTargetID == nil {
                Text("Choose a format").tag(String?.none)
            }
            Section("Convert to") {
                ForEach(item.directTargets) { route in
                    Text(route.target.label).tag(Optional(route.id))
                }
            }
            if !item.chainedTargets.isEmpty {
                Section("Through other formats") {
                    ForEach(item.chainedTargets) { route in
                        Text(route.label).tag(Optional(route.id))
                    }
                }
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        // A pop-up cannot be stretched wider than its longest entry, so menus are right-aligned.
        // Their right edges line up in every row.
        .frame(width: 210, alignment: .trailing)
        .disabled(item.isBusy)
        .accessibilityLabel("Convert \(item.file.url.lastPathComponent) to")
    }

    private var selection: Binding<String?> {
        Binding(
            get: { item.selectedTargetID },
            set: { model.select($0, for: item.id) }
        )
    }
}

// MARK: - Notes

/// The most important note for a file, with a popover for the rest.
struct FindingsLine: View {
    let findings: [Finding]
    @State private var showAll = false

    var body: some View {
        if let top = findings.max(by: { Self.rank($0) < Self.rank($1) }) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: Self.symbol(top))
                    .foregroundStyle(Self.color(top))
                    .imageScale(.small)
                Text(top.message)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if findings.count > 1 {
                    Button("+\(findings.count - 1) more") { showAll = true }
                        .buttonStyle(.link)
                        .popover(isPresented: $showAll, arrowEdge: .bottom) {
                            FindingsList(findings: findings)
                        }
                }
            }
            .font(.caption)
            .accessibilityElement(children: .combine)
        }
    }

    static func rank(_ finding: Finding) -> Int {
        switch finding.severity {
        case .blocking: return 2
        case .caution: return 1
        case .info: return 0
        }
    }

    static func symbol(_ finding: Finding) -> String {
        switch finding.severity {
        case .info: return "info.circle"
        case .caution: return "exclamationmark.triangle.fill"
        case .blocking: return "xmark.octagon.fill"
        }
    }

    static func color(_ finding: Finding) -> Color {
        switch finding.severity {
        case .info: return .secondary
        case .caution: return .orange
        case .blocking: return .red
        }
    }
}

/// Every note for a file, in a popover.
struct FindingsList: View {
    let findings: [Finding]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(findings.sorted { FindingsLine.rank($0) > FindingsLine.rank($1) }) { finding in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: FindingsLine.symbol(finding))
                        .foregroundStyle(FindingsLine.color(finding))
                    Text(finding.message)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.callout)
            }
        }
        .padding(14)
        .frame(width: 340, alignment: .leading)
    }
}

/// What the syntax check found for a translated file.
struct ValidationNote: View {
    let result: ValidationResult

    var body: some View {
        switch result {
        case .passed(let checker):
            HStack(spacing: 5) {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                Text("Syntax check passed (\(checker))").foregroundStyle(.secondary)
            }
            .font(.caption)
        case .failed(let checker, _):
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("Syntax check found problems (\(checker)). The file is saved so you can review it.")
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .font(.caption)
        case .notChecked(let reason):
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
                Text(reason).foregroundStyle(.secondary).lineLimit(2)
            }
            .font(.caption)
        }
    }
}

/// The commands that ran, in a popover. For people who want to see exactly what happened.
struct LogPopover: View {
    let lines: [String]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(14)
        }
        .frame(width: 440, height: min(CGFloat(lines.count) * 34 + 40, 280))
    }
}

// MARK: - PDF compression

/// The compression level for a PDF that is being made smaller. Custom reveals a field for the size.
struct CompressionControl: View {
    @Environment(AppModel.self) private var model
    let item: AppModel.Item

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Picker("Compression", selection: choice) {
                    ForEach(PDFCompressionChoice.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 420, alignment: .leading)
                if item.compression == .custom {
                    TextField("e.g. 2 MB", text: customSize)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 110)
                        .accessibilityLabel("Target size")
                }
                Spacer(minLength: 0)
            }
            Text(item.needsCustomSize ? "Enter a size such as 2 MB or 800 KB." : item.compression.summary)
                .font(.caption2)
                .foregroundStyle(item.needsCustomSize ? Color.orange : Color.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .disabled(item.isBusy)
    }

    private var choice: Binding<PDFCompressionChoice> {
        Binding(get: { item.compression }, set: { model.setCompression($0, for: item.id) })
    }

    private var customSize: Binding<String> {
        Binding(get: { item.customSize }, set: { model.setCustomSize($0, for: item.id) })
    }
}
