import SwiftUI

enum SocialHubSection: String, CaseIterable, Identifiable {
    case workshop = "Workshop"
    case friends = "Friends"
    case hobbies = "Hobbies"
    var id: String { rawValue }
}

struct SocialHubView: View {
    @ObservedObject var store: FernletStore
    @Binding var activeSheet: FernletSheet?
    @Binding var section: SocialHubSection

    var body: some View {
        TabView(selection: $section) {
            WorkshopView(store: store, activeSheet: $activeSheet, isInHub: true)
                .tag(SocialHubSection.workshop)
            FriendPhotoShareView(store: store, activeSheet: $activeSheet, isInHub: true)
                .tag(SocialHubSection.friends)
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
