import SwiftUI
import FernletDomainModel
import FernletUI

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
