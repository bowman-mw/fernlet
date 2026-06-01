import SwiftUI

struct SocialHubView: View {
    var store: FernletStore
    @Binding var activeSheet: FernletSheet?

    var body: some View {
        ConnectView(store: store, activeSheet: $activeSheet)
            .background(Color.parchment)
    }
}
