import SwiftUI
import FernletDomainModel
import PrivateHealthStore
import PeriodContextBridge
import FernletUI
import FernletLock
import FernletLockUI

enum PrivateHubSection: String, CaseIterable, Identifiable {
    case journal = "Journal"
    case period = "Period"
    case intimacy = "Intimacy"
    // Worry Box + Journal: always visible (no per-user gating), so they pick up via `allCases`.
    case worryBox = "Worry Box"
    var id: String { rawValue }

    /// The single source of truth for hub section visibility. `PrivateHubView.body` used to inline a
    /// second, near-identical copy of this filter that was the one actually running (the helper was
    /// only reached by tests) — so the tests could pass while the UI diverged. There is one filter now.
    static func visibleSections(visibility: SensitiveSurfaceVisibility) -> [PrivateHubSection] {
        allCases.filter { section in
            switch section {
            case .intimacy: visibility.intimacy
            case .period: visibility.period
            case .journal, .worryBox: true
            }
        }
    }
}

struct PrivateHubView: View {
    var store: FernletStore
    var periodStore: PeriodTrackerStore
    var intimacyStore: IntimacyLogStore
    var periodContext: PeriodContextBridge? = nil
    var worryBox: WorryBoxService
    @Binding var activeSheet: FernletSheet?
    @Binding var section: PrivateHubSection
    @Binding var isTabBarCompact: Bool
    @Binding var tabResetToken: Int

    var body: some View {
        let visibleSections = PrivateHubSection.visibleSections(visibility: store.sensitiveSurfaceVisibility)

        TabView(selection: clampedSection(visibleSections)) {
            JournalView(store: store, activeSheet: $activeSheet, isInHub: true, isTabBarCompact: $isTabBarCompact, tabResetToken: $tabResetToken)
                .tag(PrivateHubSection.journal)
            if store.isPeriodTrackingVisible {
                PeriodTrackerView(store: store, periodStore: periodStore, periodContext: periodContext, activeSheet: $activeSheet, isInHub: true, isTabBarCompact: $isTabBarCompact, tabResetToken: $tabResetToken)
                    .tag(PrivateHubSection.period)
            }
            if store.isIntimacyTrackingVisible {
                PersonalScreenView(screen: .intimacyTracking, store: store, intimacyStore: intimacyStore, activeSheet: $activeSheet, isInHub: true, isTabBarCompact: $isTabBarCompact, tabResetToken: $tabResetToken)
                    .tag(PrivateHubSection.intimacy)
            }
            WorryBoxView(worryBox: worryBox)
                .tag(PrivateHubSection.worryBox)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .safeAreaInset(edge: .top, spacing: 0) {
            HubSectionPicker(
                sections: Array(visibleSections),
                selection: $section
            ) { $0.rawValue }
        }
        .background(Color.parchment)
        // UX appearance tests can bypass the gate overlay to review the Journal/Period/
        // Intimacy screens without configuring a passcode. Release builds: always gated.
        // `.privateHub` is the scope that owns the sealed content key — unlocking the progress-photo
        // strip or App-lock settings does NOT open this tab (and vice versa).
        .fernletLockGate(scope: .privateHub, active: !UITestSupport.bypassPrivateLockGate)
        .onAppear { resetUnavailableSectionIfNeeded() }
        .onChange(of: store.sensitiveSurfaceVisibility) { _, _ in
            resetUnavailableSectionIfNeeded()
        }
    }

    /// A selection binding that can never point at a hidden (absent) page. The reader clamps a
    /// stranded `section` to `.journal` AT RENDER TIME, so the paged `TabView` never binds to a tag
    /// whose page is missing from the builder — which otherwise shows one frame of bare
    /// `Color.parchment` before `resetUnavailableSectionIfNeeded()` runs a transaction later. This
    /// closes both the same-transaction window (a visibility flip from a HealthKit body-profile
    /// import or an Age/Gender edit, not just the Settings toggle) and the stale-selection window
    /// after the tab shell rebuilds. The writer passes edits straight through.
    private func clampedSection(_ visibleSections: [PrivateHubSection]) -> Binding<PrivateHubSection> {
        Binding(
            get: { visibleSections.contains(section) ? section : .journal },
            set: { section = $0 }
        )
    }

    /// Persists the corrected selection so `$section` (owned by an ancestor and read elsewhere)
    /// converges on a real page. `clampedSection` already prevents the blank frame; this keeps the
    /// stored value honest for the picker and any observer.
    private func resetUnavailableSectionIfNeeded() {
        guard !PrivateHubSection.visibleSections(visibility: store.sensitiveSurfaceVisibility).contains(section) else { return }
        section = .journal
    }
}
