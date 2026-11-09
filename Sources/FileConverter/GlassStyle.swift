import SwiftUI

extension View {
    /// Liquid Glass on macOS 26 and later. Earlier systems get a plain, lightly tinted background.
    @ViewBuilder
    func glassSurface(cornerRadius: CGFloat = 14, tint: Color? = nil) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            if let tint {
                self.glassEffect(.regular.tint(tint), in: RoundedRectangle(cornerRadius: cornerRadius))
            } else {
                self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius))
            }
        } else {
            plainSurface(cornerRadius: cornerRadius, tint: tint)
        }
        #else
        plainSurface(cornerRadius: cornerRadius, tint: tint)
        #endif
    }

    /// The main action button: Liquid Glass prominent on macOS 26 and later, bordered prominent before.
    /// A disabled button is plain, because a tinted button with nothing to do looks like it can be clicked.
    @ViewBuilder
    func prominentButtonStyle(enabled: Bool = true) -> some View {
        #if compiler(>=6.2)
        if !enabled {
            self.buttonStyle(.bordered)
        } else if #available(macOS 26.0, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.borderedProminent)
        }
        #else
        if enabled {
            self.buttonStyle(.borderedProminent)
        } else {
            self.buttonStyle(.bordered)
        }
        #endif
    }

    private func plainSurface(cornerRadius: CGFloat, tint: Color?) -> some View {
        self.background((tint ?? Color.secondary).opacity(0.12),
                        in: RoundedRectangle(cornerRadius: cornerRadius))
    }
}
