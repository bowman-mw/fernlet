import SwiftUI
import FernletDomainModel
import FernletUI

/// The Social tab's top-level wrapper — currently a straight pass-through to ``FriendsView``.
///
/// Exists as the stable entry point ContentView mounts for the tab, so the tab wiring (active
/// sheet, tab-bar compaction, reset token) survives future layout changes inside the hub.
struct SocialHubView: View {
    var store: FernletStore
    @Binding var activeSheet: FernletSheet?
    @Binding var isTabBarCompact: Bool
    @Binding var tabResetToken: Int

    var body: some View {
        FriendsView(store: store, activeSheet: $activeSheet, isTabBarCompact: $isTabBarCompact, tabResetToken: $tabResetToken)
            .background(Color.parchment)
    }
}
