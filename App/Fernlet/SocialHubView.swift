import SwiftUI
import FernletDomainModel
import FernletUI

/// The Social tab's top-level wrapper (the Album panel since `b4-mem-name`) — a straight pass-through
/// to ``FriendsView``.
///
/// Exists as the stable entry point ContentView mounts for the tab, so the tab wiring (active
/// sheet, tab-bar compaction, reset token, the page Home asks for, closing back to Home, the root
/// keep-as-friends prompt's two flags) survives
/// future layout changes inside the hub.
struct SocialHubView: View {
    var store: FernletStore
    @Binding var activeSheet: FernletSheet?
    @Binding var isTabBarCompact: Bool
    @Binding var tabResetToken: Int
    /// A page Home's buttons asked for (Friends nearby, Activities, Friend shops).
    @Binding var requestedRoute: FriendsRoute?
    /// Closes the panel back to Home.
    var onFinished: () -> Void = {}
    /// Whether the root's keep-as-friends prompt is up (``KeepFriendsPromptHost``).
    var keepFriendsPromptIsUp: Bool = false
    /// Out: whether one of the Album's full-screen covers is up.
    @Binding var albumCoverIsUp: Bool

    var body: some View {
        FriendsView(store: store, activeSheet: $activeSheet, isTabBarCompact: $isTabBarCompact, tabResetToken: $tabResetToken,
                    requestedRoute: $requestedRoute, onFinished: onFinished, keepFriendsPromptIsUp: keepFriendsPromptIsUp,
                    albumCoverIsUp: $albumCoverIsUp)
            .fernletPageBackground()
    }
}
