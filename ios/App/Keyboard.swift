import SwiftUI
import UIKit

extension UIApplication {
    func dismissKeyboard() {
        sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

extension View {
    /// Tapping empty space hides the keyboard. Buttons and links inside keep
    /// their own taps (a child gesture wins over this one).
    func tapDismissesKeyboard() -> some View {
        contentShape(Rectangle())
            .onTapGesture { UIApplication.shared.dismissKeyboard() }
    }

    /// A downward swipe hides the keyboard — for views that don't scroll
    /// (scroll views use `.scrollDismissesKeyboard` instead).
    func swipeDownDismissesKeyboard() -> some View {
        simultaneousGesture(
            DragGesture(minimumDistance: 20).onEnded { g in
                if g.translation.height > 30 && g.translation.height > abs(g.translation.width) {
                    UIApplication.shared.dismissKeyboard()
                }
            }
        )
    }
}

/// Where the composer rests: low over the home indicator while the keyboard
/// is down, a small gap above it while it's up.
private struct ComposerDock: ViewModifier {
    @State private var keyboardUp = false

    /// The home-indicator inset, 0 on a device with a Home button.
    private var homeInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow?.safeAreaInsets.bottom }
            .first ?? 0
    }

    /// Clear behind a glass composer so content scrolls under it.
    private var dockBackground: Color {
        if #available(iOS 26, *) { return .clear }
        return Theme.background
    }

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 12)
            .padding(.top, 6)
            // Into the home-indicator inset, keeping ~20 pt to the edge.
            .padding(.bottom, keyboardUp ? 8 : homeInset > 0 ? min(0, 20 - homeInset) : 10)
            .background(dockBackground.ignoresSafeArea(edges: .bottom))
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                withAnimation(.easeOut(duration: 0.25)) { keyboardUp = true }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                withAnimation(.easeOut(duration: 0.25)) { keyboardUp = false }
            }
    }
}

extension View {
    func composerDock() -> some View { modifier(ComposerDock()) }
}
