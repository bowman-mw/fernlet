import SwiftUI

enum PrivateHubSection: String, CaseIterable, Identifiable {
    case journal = "Journal"
    case period = "Period"
    case intimacy = "Intimacy"
    var id: String { rawValue }

    static func visibleSections(allowsIntimacy: Bool) -> [PrivateHubSection] {
        allowsIntimacy ? allCases : allCases.filter { $0 != .intimacy }
    }
}

struct PrivateHubView: View {
    var store: FernletStore
    var periodStore: PeriodTrackerStore
    var periodContext: PeriodContextBridge? = nil
    @Binding var activeSheet: FernletSheet?
    @Binding var section: PrivateHubSection
    @Binding var isTabBarCompact: Bool
    @Binding var tabResetToken: Int

    var body: some View {
        let visibleSections = store.isIntimateLoggingAllowed ? PrivateHubSection.allCases : PrivateHubSection.allCases.filter { $0 != .intimacy }

        TabView(selection: $section) {
            JournalView(store: store, activeSheet: $activeSheet, isInHub: true, isTabBarCompact: $isTabBarCompact, tabResetToken: $tabResetToken)
                .tag(PrivateHubSection.journal)
            PeriodTrackerView(store: store, periodStore: periodStore, periodContext: periodContext, activeSheet: $activeSheet, isInHub: true, isTabBarCompact: $isTabBarCompact, tabResetToken: $tabResetToken)
                .tag(PrivateHubSection.period)
            if store.isIntimateLoggingAllowed {
                PersonalScreenView(screen: .intimacyTracking, store: store, activeSheet: $activeSheet, isInHub: true, isTabBarCompact: $isTabBarCompact, tabResetToken: $tabResetToken)
                    .tag(PrivateHubSection.intimacy)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .safeAreaInset(edge: .top, spacing: 0) {
            HubSectionPicker(
                sections: Array(visibleSections),
                selection: $section
            ) { $0.rawValue }
        }
        .background(Color.parchment)
        .fernletLockGate()
        .onAppear { resetUnavailableSectionIfNeeded() }
        .onChange(of: store.isIntimateLoggingAllowed) { _, _ in
            resetUnavailableSectionIfNeeded()
        }
    }

    private func resetUnavailableSectionIfNeeded() {
        if !store.isIntimateLoggingAllowed && section == .intimacy {
            section = .journal
        }
    }
}
