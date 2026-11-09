import SwiftUI
import ConverterCore

/// The adjustments chosen for one picture in the queue. Typed sizes are kept as text, because they can be wrong.
struct ImageEdits: Equatable {
    enum Compression: String, CaseIterable, Identifiable {
        case original, low, medium, high, custom
        var id: String { rawValue }
        var title: String {
            switch self {
            case .original: return "Original"
            case .low: return "Low"
            case .medium: return "Medium"
            case .high: return "High"
            case .custom: return "Custom"
            }
        }
    }

    enum Size: String, CaseIterable, Identifiable {
        case original, threeQuarters, half, quarter, pixels
        var id: String { rawValue }
        var title: String {
            switch self {
            case .original: return "Original"
            case .threeQuarters: return "75%"
            case .half: return "50%"
            case .quarter: return "25%"
            case .pixels: return "Pixels"
            }
        }
    }

    var compression: Compression = .original
    var customSize = ""
    var size: Size = .original
    var customPixels = ""
    var crop: ImageCrop = .off
    var removeBackground = false
    var effect: ImageEffect = .off
    var keepMetadata = true

    /// True when the typed pixel count is not a positive whole number.
    var adjustmentsPixelsAreInvalid: Bool {
        guard let pixels = Int(customPixels.trimmingCharacters(in: .whitespaces)) else { return true }
        return pixels <= 0
    }

    /// The compression to show. Lossless formats have no presets, so a preset chosen earlier reads as Original.
    func shownCompression(lossy: Bool) -> Compression {
        lossy || compression == .custom ? compression : .original
    }

    /// The adjustments to run. Nil when a typed size or pixel count is missing or not understood.
    var adjustments: ImageAdjustments? {
        var result = ImageAdjustments()
        switch compression {
        case .original: result.compression = .original
        case .low: result.compression = .low
        case .medium: result.compression = .medium
        case .high: result.compression = .high
        case .custom:
            guard let bytes = FileSize.parse(customSize) else { return nil }
            result.compression = .custom(bytes: bytes)
        }
        switch size {
        case .original: result.resize = .original
        case .threeQuarters: result.resize = .percent(75)
        case .half: result.resize = .percent(50)
        case .quarter: result.resize = .percent(25)
        case .pixels:
            guard let pixels = Int(customPixels.trimmingCharacters(in: .whitespaces)), pixels > 0 else { return nil }
            result.resize = .longestSide(pixels)
        }
        result.crop = crop
        result.removeBackground = removeBackground
        result.effect = effect
        result.keepMetadata = keepMetadata
        return result
    }

    /// A short description for the row, such as "50%, square crop, sketch". Empty when nothing is changed.
    func summary(lossy: Bool) -> String {
        var parts: [String] = []
        switch shownCompression(lossy: lossy) {
        case .original: break
        case .custom: parts.append("under \(customSize)")
        default: parts.append(compression.title.lowercased() + " compression")
        }
        if size != .original {
            parts.append(size == .pixels ? "longest side \(customPixels) px" : size.title)
        }
        if crop != .off { parts.append(crop.title.lowercased() + " crop") }
        if removeBackground { parts.append("background removed") }
        if effect != .off { parts.append(effect.title.lowercased()) }
        if !keepMetadata { parts.append("no camera details") }
        let text = parts.joined(separator: ", ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }
}

extension ImageCrop {
    var title: String {
        switch self {
        case .off: return "None"
        case .square: return "Square"
        case .fourByThree: return "4:3"
        case .sixteenByNine: return "16:9"
        case .threeByFour: return "3:4"
        }
    }
}

extension ImageEffect {
    var title: String {
        switch self {
        case .off: return "None"
        case .sketch: return "Sketch"
        }
    }
}

/// The line under a picture in the queue: what is changed, and a button to change it.
struct ImageAdjustRow: View {
    @Environment(AppModel.self) private var model
    let item: AppModel.Item
    @State private var showing = false

    var body: some View {
        HStack(spacing: 8) {
            Text(caption)
                .font(.caption2)
                .foregroundStyle(item.needsCustomSize ? Color.orange : Color.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button("Adjust…") { showing = true }
                .controlSize(.small)
                .disabled(item.isBusy)
                .popover(isPresented: $showing, arrowEdge: .bottom) {
                    ImageAdjustPopover(itemID: item.id)
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var caption: String {
        if item.needsCustomSize { return "Enter the size or pixel count in Adjust…" }
        let summary = item.imageEdits.summary(lossy: item.isLossyImageTarget)
        return summary.isEmpty ? "Original size and quality" : summary
    }
}

/// The adjustments for one picture: compression, size, crop, background, style and details.
struct ImageAdjustPopover: View {
    @Environment(AppModel.self) private var model
    let itemID: UUID

    private var item: AppModel.Item? { model.items.first { $0.id == itemID } }
    private var edits: ImageEdits { item?.imageEdits ?? ImageEdits() }
    private var lossy: Bool { item?.isLossyImageTarget ?? true }
    private var targetName: String { item?.selectedTarget?.fileExtension.uppercased() ?? "This format" }

    var body: some View {
        Form {
            Section {
                Picker("Compression", selection: compression) {
                    ForEach(lossy ? ImageEdits.Compression.allCases : [.original, .custom]) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if edits.compression == .custom {
                    TextField("Target size", text: binding(\.customSize), prompt: Text("500 KB"))
                    if FileSize.parse(edits.customSize) == nil {
                        problem("Enter a size such as 500 KB or 2 MB.")
                    }
                }
            } header: {
                Text("Compression")
            } footer: {
                Text(lossy
                     ? "Low keeps the most detail, and High makes the smallest file. Custom aims for the size you type."
                     : "\(targetName) keeps every detail, so Custom makes the picture smaller in pixels until it fits.")
            }

            Section {
                Picker("Size", selection: binding(\.size)) {
                    ForEach(ImageEdits.Size.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if edits.size == .pixels {
                    TextField("Longest side", text: binding(\.customPixels), prompt: Text("1200"))
                    if edits.adjustmentsPixelsAreInvalid {
                        problem("Enter a whole number of pixels, such as 1200.")
                    }
                }
                Picker("Crop", selection: binding(\.crop)) {
                    ForEach(ImageCrop.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            } header: {
                Text("Size and shape")
            } footer: {
                Text("A picture is never made larger than it is. A crop keeps the centre of the picture.")
            }

            Section {
                Toggle("Remove background", isOn: binding(\.removeBackground))
                Picker("Style", selection: binding(\.effect)) {
                    ForEach(ImageEffect.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            } header: {
                Text("Effects")
            } footer: {
                Text("Removing the background keeps the main subject. PNG, HEIC, TIFF and GIF stay transparent, and JPEG and BMP get a white background. A sketch is drawn on white paper.")
            }

            Section {
                Toggle("Keep camera and location details", isOn: binding(\.keepMetadata))
            } footer: {
                Text("Turn this off before sharing a picture publicly. These details can include where the photo was taken.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 400, height: 640)
    }

    private func problem(_ message: String) -> some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(.orange)
    }

    private var compression: Binding<ImageEdits.Compression> {
        Binding(
            get: { edits.shownCompression(lossy: lossy) },
            set: { newValue in model.editImage(itemID) { $0.compression = newValue } }
        )
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<ImageEdits, Value>) -> Binding<Value> {
        Binding(
            get: { edits[keyPath: keyPath] },
            set: { newValue in model.editImage(itemID) { $0[keyPath: keyPath] = newValue } }
        )
    }
}
