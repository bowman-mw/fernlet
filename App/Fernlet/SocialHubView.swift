import SwiftUI
import FernletDomainModel
import FernletUI

/// The Social tab's top-level wrapper — currently a straight pass-through to ``FriendsView``.
///
/// Exists as the stable entry point ContentView mounts for the tab, so the tab wiring (active
/// sheet, tab-bar compaction, reset token) survives future layout changes inside the hub.
struct SocialHubView: View {
    var store: FernletStore

    /// The app's one `ProximityRunPolicyHost`, passed straight through to ``FriendsView``.
    ///
    /// Threaded by `init` rather than by `@Environment` for the reason the host's own documentation
    /// gives — an environment injection would need `@Observable`, and nothing here observes it — and
    /// the same way `ContentView` hands it to `FoodView`. Its one use on this surface is the launch
    /// restore's resume affordance (P7 item 5, pass 2).
    var runPolicyHost: ProximityRunPolicyHost

    @Binding var activeSheet: FernletSheet?
    @Binding var isTabBarCompact: Bool
    @Binding var tabResetToken: Int

    var body: some View {
        FriendsView(
            store: store,
            runPolicyHost: runPolicyHost,
            activeSheet: $activeSheet,
            isTabBarCompact: $isTabBarCompact,
            tabResetToken: $tabResetToken
        )
        .background(Color.parchment)
    }
}
