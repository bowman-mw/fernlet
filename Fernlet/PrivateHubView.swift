import SwiftUI
import FernletDomainModel
import PrivateHealthStore
import PeriodContextBridge
import FernletUI
import FernletLock
import FernletLockUI

/// The pages of the Private hub, in display order: Journal, Cycle, Worry Box.
///
/// Raw values double as the section-picker labels. Cycle is the merged period + intimacy page and
/// is conditional on the store's derived `SensitiveSurfaceVisibility` — it exists while EITHER
/// half is visible and vanishes only when both gates hide; ``visibleSections(visibility:)`` is the
/// single filter both the UI and tests use to decide which pages exist.
enum PrivateHubSection: String, CaseIterable, Identifiable {
    case journal = "Journal"
    /// The merged period + intimacy page (``CycleTrackerView``); each half gates itself inside.
    case cycle = "Cycle"
    // Worry Box + Journal: always visible (no per-user gating), so they pick up via `allCases`.
    case worryBox = "Worry Box"
    var id: String { rawValue }

    /// The single source of truth for hub section visibility. `PrivateHubView.body` used to inline a
    /// second, near-identical copy of this filter that was the one actually running (the helper was
    /// only reached by tests) — so the tests could pass while the UI diverged. There is one filter now.
    static func visibleSections(visibility: SensitiveSurfaceVisibility) -> [PrivateHubSection] {
        allCases.filter { section in
            switch section {
            // The merged page survives while either half is visible; only both-hidden removes it.
            case .cycle: visibility.period || visibility.intimacy
            case .journal, .worryBox: true
            }
        }
    }
}

/// The Personal tab's paged container for every sensitive surface: ``JournalView``,
/// ``CycleTrackerView``, and ``WorryBoxView``, all behind one lock gate.
///
/// The whole hub sits behind `fernletLockGate` (bypassable only via the DEBUG UI-test hook), so
/// each child screen inherits the app-lock requirement instead of gating itself. Section
/// visibility follows ``PrivateHubSection/visibleSections(visibility:)``; the `clampedSection(_:)`
/// binding guarantees the paged `TabView` can never select a hidden page mid-transaction (a
/// visibility flip from Settings, a HealthKit body-profile import, or an Age/Gender edit), while
/// `resetUnavailableSectionIfNeeded()` converges the ancestor-owned `$section` onto a real page
/// afterward.
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
    /// Whether the Personal tab is the visible page of the outer paged `TabView` (the parent
    /// passes `selectedTab == .personal`). Gates ONLY the capture-friction screenshot pulse:
    /// page-style `TabView`s keep offscreen children alive, so without this a screenshot taken
    /// on Home would blur and nudge a hub nobody is looking at. Rendered from state, never
    /// `.onAppear`/`.onDisappear` (documented unreliable on page TabViews). Defaults to true.
    var isFrontmost: Bool = true

    var body: some View {
        let visibleSections = PrivateHubSection.visibleSections(visibility: store.sensitiveSurfaceVisibility)

        TabView(selection: clampedSection(visibleSections)) {
            JournalView(store: store, activeSheet: $activeSheet, isInHub: true, isTabBarCompact: $isTabBarCompact, tabResetToken: $tabResetToken)
                .tag(PrivateHubSection.journal)
            if visibleSections.contains(.cycle) {
                CycleTrackerView(store: store, periodStore: periodStore, intimacyStore: intimacyStore, periodContext: periodContext, activeSheet: $activeSheet, isInHub: true, isTabBarCompact: $isTabBarCompact, tabResetToken: $tabResetToken)
                    .tag(PrivateHubSection.cycle)
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
        // Capture FRICTION (never a security control) over the whole hub — the three pages and
        // their pushed details share this one presentation host, so one attachment covers them
        // all; the five sensitive sheets present in their own contexts and attach at their own
        // bodies. Deliberately INNER to `.fernletLockGate` so the capture cover can never occlude
        // the passcode field or the Face-ID chrome during the documented inactive→active bounce.
        // Stays active under the lock-gate bypass flag: neither trigger fires under automation,
        // and the FERNLET_UI_TEST_FORCE_CAPTURE tests need the cover WITH the gate bypassed.
        .captureProtected(surface: "privateHub", isFrontmost: isFrontmost)
        // UX appearance tests can bypass the gate overlay to review the Journal/Cycle screens
        // without configuring a passcode. Release builds: always gated.
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
