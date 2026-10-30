import SwiftUI

extension View {
    /// Sprout's passport over the whole app (World-Passport-Spec §1): hands `presenter` down through the
    /// environment, so any screen can open the book, and presents it full screen over the root, the screen behind
    /// it still showing (the book draws its own veil, rise and swing). Put on the root once.
    func worldPassportBook(_ presenter: WorldPassportPresenter, store: FernletStore) -> some View {
        modifier(WorldPassportBookHost(presenter: presenter, store: store))
    }
}

/// Implements `worldPassportBook(_:store:)`: the environment, the full-screen cover with a clear background, a fresh
/// book each open, and the passport's DEBUG screenshot hook (a no-op in Release).
struct WorldPassportBookHost: ViewModifier {
    @Bindable var presenter: WorldPassportPresenter
    let store: FernletStore

    func body(content: Content) -> some View {
        content
            .environment(presenter)
            .fullScreenCover(isPresented: $presenter.isPresented) {
                PassportBookScreen(presenter: presenter, store: store)
                    .id(presenter.openCount)
                    .environment(presenter)
                    .worldDesignLanguage()
                    .presentationBackground(.clear)
            }
            .passportBookHook(presenter, store: store)
    }
}
