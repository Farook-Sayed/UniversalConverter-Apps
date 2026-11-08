import SwiftUI
import AppKit
import QuickLookThumbnailing

/// A file's thumbnail, the way Finder shows it: a preview for photos, videos and documents, and the
/// file-type icon while the preview loads or when the file has none.
struct FileThumbnail: View {
    let url: URL
    var size: CGFloat = 44

    @State private var preview: NSImage?

    var body: some View {
        Group {
            if let preview {
                Image(nsImage: preview)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .shadow(color: .black.opacity(0.18), radius: 1.5, y: 0.5)
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .scaledToFit()
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .task(id: url) {
            preview = await Self.makeThumbnail(for: url, side: size)
        }
    }

    private static func makeThumbnail(for url: URL, side: CGFloat) async -> NSImage? {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: side, height: side),
                                                   scale: scale, representationTypes: .thumbnail)
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
    }
}
