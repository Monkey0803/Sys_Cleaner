import SwiftUI

/// Adds a consistent pointer highlight without replacing the button's native style.
private struct HoverHighlightModifier: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .fill(isEnabled && isHovered ? Color.accentColor.opacity(0.14) : .clear)
                    .overlay {
                        RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(isEnabled && isHovered ? Color.accentColor.opacity(0.55) : .clear,
                                          lineWidth: 1)
                    }
                    .padding(-3)
                    .allowsHitTesting(false)
            }
            .onHover { isHovered = $0 }
    }
}

extension View {
    func hoverHighlight() -> some View { modifier(HoverHighlightModifier()) }
}
