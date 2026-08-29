import SwiftUI
import FernletDomainModel
import PrivateHealthStore
import PeriodContextBridge
import FernletUI
import FernletLock
import FernletLockUI
import HealthKitGateway

/// The pages of the Private hub, in display order: Journal, Cycle, Worry Box.
///
/// Raw values double as the section-picker labels. Cycle is the merged period + intimacy page and
/// is conditional on the store's derived `SensitiveSurfaceVisibility` — it exists while EITHER
/// half is visible and vanishes only when both gates hide; ``visibleSections(visibility:)`` is the
/// single filter both the UI and tests use to decide which pages exist.
enum PrivateHubSection: String, CaseIterable, Hashable, Identifiable {
    case journal = "Journal"
    /// The merged period + intimacy page (``CycleTrackerView``); each half gates itself inside.
    case cycle = "Cycle"
    // Worry box + Journal: always visible (no per-user gating), so they pick up via `allCases`.
    // Sentence case, matching the page's own title and the First aid tile — the picker was the one
    // place that title-cased it.
    case worryBox = "Worry box"
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

/// The Personal tab's section-scoped container for every sensitive surface: ``JournalView``,
/// ``CycleTrackerView``, and ``WorryBoxView``, all behind one lock gate.
///
/// The whole hub sits behind `fernletLockGate` (bypassable only via the DEBUG UI-test hook), so
/// each child screen inherits the app-lock requirement instead of gating itself. Section
/// visibility follows ``PrivateHubSection/visibleSections(visibility:)``. Only the selected child
/// exists, and `resetUnavailableSectionIfNeeded()` converges the ancestor-owned `$section` onto a
/// real page after a visibility flip from Settings, a profile import, or an Age/Gender edit.
struct PrivateHubView: View {
    var store: FernletStore
    var periodStore: PeriodTrackerStore
    var intimacyStore: IntimacyLogStore
    var healthKitService: HealthKitService
    var periodContext: PeriodContextBridge? = nil
    var worryBox: WorryBoxService
    @Binding var activeSheet: FernletSheet?
    @Binding var section: PrivateHubSection
    @Binding var isTabBarCompact: Bool
    @Binding var tabResetToken: Int
    /// Actual outer-tab selection. The outer `TabView` retains this view offscreen, so this value —
    /// not `onDisappear` — activates the lock gate and revokes the hub key on departure.
    var isActive: Bool = true
    /// Whether the Personal tab is the visible, uncovered page of the retaining root `TabView`
    /// (the parent passes `selectedTab == .personal` ANDed with "no root-presented sheet is
    /// covering the tab pages"). Gates ONLY the capture-friction screenshot pulse: page-style
    /// `TabView`s keep offscreen children alive, so without this a screenshot taken on Home —
    /// or beneath a covering root sheet — would blur, nudge, and CLAIM the once-per-session
    /// nudge for a hub nobody is looking at. The body further ANDs in the lock-gate occlusion
    /// before handing the flag to the capture modifier. Rendered from state, never
    /// `.onAppear`/`.onDisappear` (documented unreliable on page TabViews). Defaults to true.
    var isFrontmost: Bool = true
    /// The environment-injected lock service, read here (not only inside the gate modifier) so
    /// the capture-friction attachment below can know whether the gate's opaque overlay is up:
    /// a screenshot of the LOCKED (or not-yet-configured) hub must never spend the
    /// once-per-session nudge on a banner drawn invisibly beneath that overlay.
    @Environment(FernletLockService.self) private var lockService

    var body: some View {
        let visibleSections = PrivateHubSection.visibleSections(visibility: store.sensitiveSurfaceVisibility)
        // Whether the lock gate attached below is painting its opaque overlay (unlock screen or
        // setup CTA) over the hub. The capture modifier is deliberately INNER to the gate, so
        // without this a screenshot of the locked hub would still react — and spend the
        // session's one nudge — beneath an overlay nobody can see through. Uses the same
        // `active` flag as the gate attachment so the UI-test bypass stays consistent.
        let lockGateIsActive = isActive && !UITestSupport.bypassPrivateLockGate
        let lockOverlayUp = FernletLockGateOcclusion.overlayIsUp(
            active: lockGateIsActive,
            state: lockService.state,
            scope: .privateHub
        )

        Group {
            if isActive {
                sectionPage(visibleSections: visibleSections)
            } else {
                Color.clear
            }
        }
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
        // `!lockOverlayUp`: being inner to the gate also means the modifier stays alive while
        // the gate's opaque overlay covers it, so the pulse must be additionally gated on the
        // hub content actually being visible.
        .captureProtected(surface: "privateHub", isFrontmost: isFrontmost && !lockOverlayUp)
        // UX appearance tests can bypass the gate overlay to review the Journal/Cycle screens
        // without configuring a passcode. Release builds: always gated.
        // `.privateHub` is the scope that owns the sealed content key — unlocking the progress-photo
        // strip or App-lock settings does NOT open this tab (and vice versa).
        .fernletLockGate(scope: .privateHub, active: lockGateIsActive)
        .onAppear { resetUnavailableSectionIfNeeded() }
        .onChange(of: store.sensitiveSurfaceVisibility) { _, _ in
            resetUnavailableSectionIfNeeded()
        }
    }

    /// Only the selected private page exists. The former nested page `TabView` retained Journal,
    /// Cycle, and Worry Box simultaneously, along with all three decrypted caches and navigation
    /// stacks. The picker is the section navigation, so offscreen private pages own nothing.
    @ViewBuilder
    private func sectionPage(visibleSections: [PrivateHubSection]) -> some View {
        let activeSection = visibleSections.contains(section) ? section : .journal
        switch activeSection {
        case .journal:
            JournalView(
                store: store, activeSheet: $activeSheet, isInHub: true,
                isTabBarCompact: $isTabBarCompact, tabResetToken: $tabResetToken
            )
        case .cycle:
            CycleTrackerView(
                store: store, periodStore: periodStore, intimacyStore: intimacyStore,
                healthKitService: healthKitService, periodContext: periodContext,
                activeSheet: $activeSheet, isInHub: true,
                isTabBarCompact: $isTabBarCompact, tabResetToken: $tabResetToken
            )
        case .worryBox:
            WorryBoxView(worryBox: worryBox)
        }
    }

    /// Persists the corrected selection so `$section` (owned by an ancestor and read elsewhere)
    /// converges on a real page for the picker and any observer.
    private func resetUnavailableSectionIfNeeded() {
        guard !PrivateHubSection.visibleSections(visibility: store.sensitiveSurfaceVisibility).contains(section) else { return }
        section = .journal
    }
}

