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
    /// A box the user drew, as fractions of the picture. It replaces the crop shape when set.
    var cropRect: CGRect?
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
        result.cropRect = cropRect
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
        if cropRect != nil {
            parts.append("custom crop")
        } else if crop != .off {
            parts.append(crop.title.lowercased() + " crop")
        }
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
    @State private var preview: NSImage?
    @State private var aspect: CGFloat = 1.5

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
                CropEditor(image: preview, aspect: aspect, rect: cropBinding)
                    .frame(height: 220)
                Picker("Shape", selection: shapeBinding) {
                    ForEach(ImageCrop.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                if edits.cropRect != nil || edits.crop != .off {
                    Button("Reset crop") { model.editImage(itemID) { $0.crop = .off; $0.cropRect = nil } }
                }
            } header: {
                Text("Size and crop")
            } footer: {
                Text("Drag the box, or its corners, to choose what to keep. A shape keeps the centre of the picture. A picture is never made larger than it is.")
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
        .frame(width: 400, height: 720)
        .task(id: itemID) { await loadPreview() }
    }

    /// The crop box. It shows the chosen shape until the user draws one.
    private var cropBinding: Binding<CGRect> {
        Binding(
            get: {
                edits.cropRect ?? edits.crop.fractionRect(aspect: Double(aspect)) ?? CGRect(x: 0, y: 0, width: 1, height: 1)
            },
            set: { newValue in
                // A box dragged back over the whole picture is no crop at all.
                let whole = newValue.width > 0.999 && newValue.height > 0.999
                model.editImage(itemID) { $0.cropRect = whole ? nil : newValue; $0.crop = .off }
            }
        )
    }

    /// Choosing a shape replaces any box the user drew.
    private var shapeBinding: Binding<ImageCrop> {
        Binding(
            get: { edits.crop },
            set: { newValue in model.editImage(itemID) { $0.crop = newValue; $0.cropRect = nil } }
        )
    }

    private func loadPreview() async {
        guard let url = item?.file.url else { return }
        let image = await Task.detached(priority: .userInitiated) {
            ImageProcessing.preview(of: url, maxSide: 900)
        }.value
        guard let image else { return }
        preview = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        aspect = CGFloat(image.width) / CGFloat(max(image.height, 1))
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

/// A picture with a box over the part to keep. The box moves when dragged, and its corners resize it.
struct CropEditor: View {
    let image: NSImage?
    let aspect: CGFloat
    @Binding var rect: CGRect
    /// The box when a drag began. Each drag step is measured from here, so the box never drifts.
    @State private var start: CGRect?

    private let smallest: CGFloat = 0.05

    private enum Corner: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight
        var isLeft: Bool { self == .topLeft || self == .bottomLeft }
        var isTop: Bool { self == .topLeft || self == .topRight }
    }

    var body: some View {
        GeometryReader { geometry in
            let shown = fitted(in: geometry.size)
            let box = CGRect(x: shown.minX + rect.minX * shown.width, y: shown.minY + rect.minY * shown.height,
                             width: rect.width * shown.width, height: rect.height * shown.height)
            ZStack {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .frame(width: shown.width, height: shown.height)
                        .position(x: shown.midX, y: shown.midY)
                }
                // Four bands darken the picture outside the box.
                dimmed(CGRect(x: shown.minX, y: shown.minY, width: shown.width, height: box.minY - shown.minY))
                dimmed(CGRect(x: shown.minX, y: box.maxY, width: shown.width, height: shown.maxY - box.maxY))
                dimmed(CGRect(x: shown.minX, y: box.minY, width: box.minX - shown.minX, height: box.height))
                dimmed(CGRect(x: box.maxX, y: box.minY, width: shown.maxX - box.maxX, height: box.height))
                // The drag area is set before the position, so only the box itself can be dragged.
                Rectangle()
                    .stroke(Color.white, lineWidth: 1.5)
                    .frame(width: box.width, height: box.height)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 1)
                        .onChanged { move(by: $0.translation, in: shown) }
                        .onEnded { _ in start = nil })
                    .position(x: box.midX, y: box.midY)
                ForEach(Corner.allCases, id: \.self) { corner in
                    Circle()
                        .fill(Color.white)
                        .overlay(Circle().stroke(Color.black.opacity(0.4), lineWidth: 1))
                        .frame(width: 14, height: 14)
                        .gesture(DragGesture(minimumDistance: 0)
                            .onChanged { resize(corner, by: $0.translation, in: shown) }
                            .onEnded { _ in start = nil })
                        .position(x: corner.isLeft ? box.minX : box.maxX, y: corner.isTop ? box.minY : box.maxY)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .accessibilityLabel("Crop box")
    }

    private func dimmed(_ area: CGRect) -> some View {
        Color.black.opacity(0.5)
            .frame(width: max(area.width, 0), height: max(area.height, 0))
            .position(x: area.midX, y: area.midY)
            .allowsHitTesting(false)
    }

    /// The part of the view where the picture is drawn, keeping its shape.
    private func fitted(in size: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0, aspect > 0 else { return CGRect(origin: .zero, size: size) }
        var width = size.width
        var height = width / aspect
        if height > size.height {
            height = size.height
            width = height * aspect
        }
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }

    private func move(by translation: CGSize, in shown: CGRect) {
        let origin = start ?? rect
        start = origin
        let x = origin.minX + translation.width / shown.width
        let y = origin.minY + translation.height / shown.height
        rect = CGRect(x: min(max(x, 0), 1 - origin.width), y: min(max(y, 0), 1 - origin.height),
                      width: origin.width, height: origin.height)
    }

    private func resize(_ corner: Corner, by translation: CGSize, in shown: CGRect) {
        let origin = start ?? rect
        start = origin
        let dx = translation.width / shown.width
        let dy = translation.height / shown.height
        var left = origin.minX, right = origin.maxX, top = origin.minY, bottom = origin.maxY
        if corner.isLeft {
            left = min(max(origin.minX + dx, 0), right - smallest)
        } else {
            right = min(max(origin.maxX + dx, left + smallest), 1)
        }
        if corner.isTop {
            top = min(max(origin.minY + dy, 0), bottom - smallest)
        } else {
            bottom = min(max(origin.maxY + dy, top + smallest), 1)
        }
        rect = CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }
}
