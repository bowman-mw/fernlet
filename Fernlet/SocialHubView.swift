import SwiftUI

enum SocialHubSection: String, CaseIterable, Identifiable {
    case workshop = "Workshop"
    case friends = "Friends"
    case mesh = "Meshes"
    case hobbies = "Hobbies"
    var id: String { rawValue }
}

struct SocialHubView: View {
    var store: FernletStore
    @Binding var activeSheet: FernletSheet?
    @Binding var section: SocialHubSection

    var body: some View {
        TabView(selection: $section) {
            WorkshopView(store: store, activeSheet: $activeSheet, isInHub: true)
                .tag(SocialHubSection.workshop)
            FriendListView(store: store)
                .tag(SocialHubSection.friends)
            MeshLobbyView(store: store, activeSheet: $activeSheet)
                .tag(SocialHubSection.mesh)
            PersonalScreenView(screen: .hobbyNotes, store: store, activeSheet: $activeSheet, isInHub: true)
                .tag(SocialHubSection.hobbies)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .safeAreaInset(edge: .top, spacing: 0) {
            HubSectionPicker(
                sections: Array(SocialHubSection.allCases),
                selection: $section
            ) { $0.rawValue }
        }
        .background(Color.parchment)
    }
}
