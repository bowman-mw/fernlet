import SwiftUI

enum PrivateHubSection: String, CaseIterable, Identifiable {
    case journal = "Journal"
    case period = "Period"
    case intimacy = "Intimacy"
    var id: String { rawValue }
}

struct PrivateHubView: View {
    @ObservedObject var store: FernletStore
    @ObservedObject var periodStore: PeriodTrackerStore
    @Binding var activeSheet: FernletSheet?
    @State private var section: PrivateHubSection = .journal

    var body: some View {
        TabView(selection: $section) {
            JournalView(store: store, activeSheet: $activeSheet, isInHub: true)
                .tag(PrivateHubSection.journal)
            PeriodTrackerView(periodStore: periodStore, activeSheet: $activeSheet, isGated: false, isInHub: true)
                .tag(PrivateHubSection.period)
            PersonalScreenView(screen: .intimacyTracking, store: store, activeSheet: $activeSheet, isInHub: true)
                .tag(PrivateHubSection.intimacy)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .safeAreaInset(edge: .top, spacing: 0) {
            HubSectionPicker(
                sections: Array(PrivateHubSection.allCases),
                selection: $section
            ) { $0.rawValue }
        }
        .background(Color.parchment)
        .fernletLockGate()
    }
}
