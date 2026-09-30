//
//  FernletNavigation.swift
//  Fernlet
//
//  App navigation enums, split out of the design system when it moved into the
//  `FernletUI` package target (SPM carve-up §14): `FernletSheet` references
//  app-resident payloads (`FirstAidTool`) so these stay in the app, per the
//  plan's §5c "NavigationEnums → app target" rule.
//

import SwiftUI
import FernletDomainModel
import FernletUI
import PrivateHealthStore

/// How Fernlet picks light or dark: follow the phone, or force one.
///
/// Stored as a raw string under ``storageKey`` and read with `@AppStorage`; `.system` (the default)
/// maps to a `nil` `preferredColorScheme`, which is the only value that lets the OS decide. The app
/// previously had a Dark-mode Bool that ContentView passed to `preferredColorScheme` as
/// `.dark`/`.light` — never `nil` — so a phone in Dark Mode still got a fully light app, with no
/// "match system" choice anywhere and a dark onboarding handing over to a light app on step 8.
///
/// ``migrateLegacyDarkModePreferenceIfNeeded(defaults:)`` carries the old Bool over once at launch,
/// so an existing user's dark app stays dark.
enum FernletAppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    /// `@AppStorage` key for the stored choice.
    static let storageKey = "fernletAppearanceMode"
    /// The pre-three-way Bool this replaces. Read once by the migration below, then left alone.
    static let legacyDarkModeKey = "fernletDarkModeEnabled"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// The value to hand `preferredColorScheme`. `nil` for ``system`` — passing a concrete scheme
    /// is exactly what pinned the app to one appearance regardless of the phone.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    /// One-time carry-over of the legacy Dark-mode Bool.
    ///
    /// Only runs when no mode has been stored yet AND the old key exists, so a fresh install
    /// defaults to ``system`` while an existing user keeps the appearance they chose. Idempotent.
    static func migrateLegacyDarkModePreferenceIfNeeded(defaults: UserDefaults = .standard) {
        guard defaults.string(forKey: storageKey) == nil,
              defaults.object(forKey: legacyDarkModeKey) != nil else { return }
        let mode: FernletAppearanceMode = defaults.bool(forKey: legacyDarkModeKey) ? .dark : .light
        defaults.set(mode.rawValue, forKey: storageKey)
    }
}

/// The five top-level tabs (Home / Food / Move / Friends / Private) in display order.
///
/// `ContentView` keys the paged `TabView`, the custom floating tab bar, and the per-tab
/// listener/health-refresh gating on this; the raw value doubles as a stable identifier for
/// per-tab reset tokens. `next`/`previous` support ordered paging helpers.
///
/// Explicitly `nonisolated` since network migration P7 item 1: `ProximityRunPolicy.Input` stores a
/// tab inside a `nonisolated`, `Hashable` value, so the tab's synthesized conformances must be
/// reachable off the main actor under the Release configuration's `MainActor` default isolation. A
/// pure value with no actor state, so nothing is lost.
nonisolated enum FernletTab: String, CaseIterable, Hashable, Identifiable {
    case home
    case food
    case move
    case social
    case personal

    var id: String { rawValue }

    /// The tab's reader-facing name — drawn in the tab bar and spoken by VoiceOver.
    ///
    /// Localized (review T2-1). It used to be plain literals doing two jobs: the tab-bar caption
    /// AND the `tab` field of an audit-log line (`ContentView.swift`), which would have written a
    /// translated word into a diagnostic record. ``id``/`rawValue` is the token half and is what
    /// the log takes now.
    var title: String {
        switch self {
        case .home: String(localized: "tab.home", defaultValue: "Home",
                           comment: "Tab bar: the daily companion / overview tab")
        case .food: String(localized: "tab.food", defaultValue: "Food",
                           comment: "Tab bar: meals, recipes and nutrition")
        case .move: String(localized: "tab.move", defaultValue: "Move",
                           comment: "Tab bar: workouts and movement")
        case .social: String(localized: "tab.social", defaultValue: "Friends",
                             comment: "Tab bar: in-person friends and shared photos")
        case .personal: String(localized: "tab.personal", defaultValue: "Private",
                               comment: "Tab bar: the locked tab — journal, cycle, intimacy, worry box")
        }
    }

    var systemImage: String {
        switch self {
        case .home: "leaf.fill"
        case .food: "fork.knife"
        case .move: "figure.walk"
        case .social: "person.2.fill"
        case .personal: "lock.fill"
        }
    }

    var label: Label<Text, Image> {
        Label(title, systemImage: systemImage)
    }

    var next: FernletTab? {
        guard let index = Self.allCases.firstIndex(of: self) else { return nil }
        let nextIndex = Self.allCases.index(after: index)
        return nextIndex < Self.allCases.endIndex ? Self.allCases[nextIndex] : nil
    }

    var previous: FernletTab? {
        guard let index = Self.allCases.firstIndex(of: self), index > Self.allCases.startIndex else { return nil }
        let previousIndex = Self.allCases.index(before: index)
        return Self.allCases[previousIndex]
    }
}

/// What re-tapping the already-selected tab does to that tab's page: the standard iOS pair, with
/// the app's draft guard in front of the pop.
///
/// With a page pushed inside the tab (Food → Recipe book → a recipe), the tap unwinds the tab's
/// whole stack to its main page in one pop. At the main page it scrolls back to the top, which is
/// all a re-tap did before the owner asked for the first half (2026-09-29). Never both on one tap:
/// `ContentView.selectTab(_:)` records that a scroll request and a navigation request landing in
/// the same frame misbehaved, so each tap resolves to exactly one of the two.
///
/// A pop would also throw away whatever a pushed editor holds (the manual recipe editor, a pasted
/// import, a half-named barcode food, an activity being set up), and the tab button sits right under
/// those pages' pinned save bars. So when a pushed page reports unsaved typed input
/// (``TabDraftRegistry``) the tap asks first with the shared discard alert, and only its Discard
/// pops — the same contract `fernletDraftGuard` gives the sheet presentations of those editors.
///
/// `nonisolated` like ``FernletTab``: a pure value, so the decision is unit-testable off the main
/// actor under the Release configuration's `MainActor` default isolation.
nonisolated enum TabReselectAction: Equatable {
    /// Something is pushed and nothing unsaved is on it: clear the tab's navigation path in one write.
    case popToRoot
    /// Something is pushed and a pushed page holds unsaved input: raise the discard alert, and pop
    /// only from its Discard.
    case confirmDiscardThenPop
    /// The main page is showing: scroll it to the top and re-expand the tab bar.
    case scrollToTop

    /// The action for a re-tap given whether the tab's stack is at its main page and whether any
    /// page pushed on it holds unsaved input. At the main page the draft state is irrelevant: a
    /// scroll loses nothing.
    static func forReselect(isAtRoot: Bool, hasUnsavedDraft: Bool) -> TabReselectAction {
        guard !isAtRoot else { return .scrollToTop }
        return hasUnsavedDraft ? .confirmDiscardThenPop : .popToRoot
    }
}

/// One pushed page's claim on its tab's ``TabDraftRegistry``: whether that page holds unsaved input
/// right now.
///
/// Owned by the page's `@State` (through ``TabReselectDraftModifier``), so it lives exactly as long
/// as the page is in the stack — including while a further page is pushed over it (the recipe
/// editor under its barcode scanner still counts) — and is released with the page's state when the
/// page leaves the stack. The registry only holds it weakly.
final class TabDraftLease {
    /// Whether the owning page holds unsaved input. Written by the page, read when a re-tap lands.
    var isDirty = false
}

/// The unsaved-input state of every page pushed inside one tab's stack, read when a re-tap of that
/// tab lands so the pop can ask before it throws a draft away (``TabReselectAction``).
///
/// Created by ``TabReselectModifier`` and injected into the tab's stack through the environment;
/// a pushed page that holds typed input joins with `.tabReselectDraft(isDirty:)`. The registry keeps
/// its ``TabDraftLease``s WEAKLY: a page that has left the stack took its lease with it, so a gone
/// page can never keep the prompt alive, while a page merely covered by a further push still counts.
///
/// `@Observable` only so it can travel as a type-keyed environment object (which a missing value
/// reads as `nil` rather than trapping); nothing observes it — the leases are
/// `@ObservationIgnored` and read only when a tap lands, so an edit on a pushed page costs no redraw
/// of the tab.
@Observable
final class TabDraftRegistry {
    /// A weak slot for one enrolled lease.
    private struct WeakLease {
        weak var lease: TabDraftLease?
    }

    /// Named bound on enrolled leases (R3). One lease per pushed editor page; a real stack holds a
    /// handful, so reaching the cap means the oldest slot is dropped rather than growing unbounded.
    static let maxLeases = 16

    @ObservationIgnored private var leases: [WeakLease] = []

    /// Whether any page still in the stack holds unsaved input.
    var hasUnsavedDraft: Bool {
        leases.contains { $0.lease?.isDirty == true }
    }

    /// Enrolls `lease` once. Idempotent — a page that reappears after the page above it pops
    /// enrolls again harmlessly — and prunes the slots of pages that have already gone.
    func enroll(_ lease: TabDraftLease) {
        leases.removeAll { $0.lease == nil }
        guard !leases.contains(where: { $0.lease === lease }) else { return }
        if leases.count >= Self.maxLeases { leases.removeFirst() }
        leases.append(WeakLease(lease: lease))
    }

    /// Forgets every lease. Called once a pop to the main page has run: every enrolled page is
    /// coming off, so none may speak for the next pushed page even if its state outlives the pop.
    func releaseAll() {
        leases.removeAll()
    }
}

/// Routes `ContentView`'s per-tab re-select token to a pop, a discard-then-pop, or a scroll-to-top,
/// per ``TabReselectAction``.
///
/// Attach it to the tab page's `NavigationStack` — OUTSIDE the stack, never to the root
/// `ScrollView` inside it — so the handler belongs to the page that owns the path and stays alive
/// while other pages are pushed over the root, and so the ``TabDraftRegistry`` it injects reaches
/// every pushed page. The page's root scroll view then takes its `fernletTabBarCompaction` reset
/// token from `scrollToTopToken`, which this modifier bumps only at the root; ContentView's token
/// itself now means "the tab was re-selected".
///
/// `isAtRoot` is a closure read when the tap lands rather than a value captured at the last body
/// pass, so a path the system back gesture just changed is always seen as it is now; the draft
/// registry is read at the same moment.
struct TabReselectModifier: ViewModifier {
    /// ContentView's per-tab re-select token; bumped once per re-tap of the active tab.
    @Binding var reselectToken: Int
    /// The page's own scroll-to-top token, consumed by its root `fernletTabBarCompaction`.
    @Binding var scrollToTopToken: Int
    /// Whether the page's navigation stack is showing its main page (nothing pushed).
    let isAtRoot: () -> Bool
    /// Clears the page's navigation state with ONE write; nested pushes above the first entry
    /// come off with it, together with the view state that drove them.
    let popToRoot: () -> Void
    /// The unsaved-input state of the pages pushed in this tab's stack.
    @State private var drafts = TabDraftRegistry()
    /// Raises the shared discard alert for a re-tap over an unsaved draft.
    @State private var askingToDiscard = false

    func body(content: Content) -> some View {
        content
            .environment(drafts)
            .onChange(of: reselectToken) { _, _ in handleReselect() }
            .discardConfirmation(isPresented: $askingToDiscard) { popAndRelease() }
    }

    /// Acts on one re-tap: exactly one of pop, ask, or scroll.
    private func handleReselect() {
        switch TabReselectAction.forReselect(isAtRoot: isAtRoot(), hasUnsavedDraft: drafts.hasUnsavedDraft) {
        case .popToRoot:
            popAndRelease()
        case .confirmDiscardThenPop:
            askingToDiscard = true
        case .scrollToTop:
            scrollToTopToken &+= 1
        }
    }

    /// Pops to the main page and forgets the leases of the pages that pop took with it.
    private func popAndRelease() {
        popToRoot()
        drafts.releaseAll()
    }
}

/// Reports a pushed page's unsaved input to its tab's ``TabDraftRegistry``, so a re-tap of the tab
/// asks before popping it (``TabReselectAction/confirmDiscardThenPop``).
///
/// Owns the page's ``TabDraftLease`` in `@State`, enrolls it on appear, and keeps its flag current.
/// Outside a tab stack (a sheet presented from `ContentView`) there is no registry and it does nothing.
struct TabReselectDraftModifier: ViewModifier {
    /// Whether the page holds input a pop would throw away.
    let isDirty: Bool
    @Environment(TabDraftRegistry.self) private var registry: TabDraftRegistry?
    @State private var lease = TabDraftLease()

    func body(content: Content) -> some View {
        content
            .onAppear {
                lease.isDirty = isDirty
                registry?.enroll(lease)
            }
            .onChange(of: isDirty) { _, dirty in lease.isDirty = dirty }
    }
}

extension View {
    /// Makes a re-tap of this page's active tab pop its stack to the main page — asking first when a
    /// pushed page holds unsaved input — or, already there, scroll it to the top. See
    /// ``TabReselectModifier``.
    func tabReselect(
        token: Binding<Int>,
        scrollToTopToken: Binding<Int>,
        isAtRoot: @escaping () -> Bool,
        popToRoot: @escaping () -> Void
    ) -> some View {
        modifier(TabReselectModifier(
            reselectToken: token,
            scrollToTopToken: scrollToTopToken,
            isAtRoot: isAtRoot,
            popToRoot: popToRoot
        ))
    }

    /// Declares that this pushed page holds unsaved input while `isDirty` is true, so a re-tap of its
    /// tab raises the discard alert instead of popping straight past it. See
    /// ``TabReselectDraftModifier``.
    func tabReselectDraft(isDirty: Bool) -> some View {
        modifier(TabReselectDraftModifier(isDirty: isDirty))
    }
}

/// Every modal sheet the app can present, routed through `ContentView`'s single
/// `activeSheet` slot (one sheet at a time; chained handoffs dismiss-then-represent).
///
/// Cases with payloads carry the edit target (recipe, period entry) or a deep-link hint
/// (`firstAid`'s optional tool). The string `id` is also the contract for the
/// `FERNLET_UI_TEST_OPEN_SHEET` launch hook (see `UITestSupport`) and the notification/App
/// Intent deep-link tokens, so renaming an id is a cross-file change.
enum FernletSheet: Identifiable {
    case meal
    case recipe
    case water
    case sleep
    case journal
    case workout
    case workoutSuggestion
    case goals
    case hygiene
    case settings
    case recipeBook
    case trends
    /// Lifetime milestones as a large sheet (2026-08-21 artboard 3f): one rule for read-only
    /// destinations from Home — they present as sheets, matching Trends, First aid and the gear.
    case milestones
    case stressExplainer
    /// Calm first-aid tools (breathing / grounding / worry box); the optional tool deep-links
    /// straight into one of them (gentle-offer cards use it).
    case firstAid(FirstAidTool?)
    case logPeriod(targetDate: Date?, editingEntry: CycleDayEntry?)
    case logIntimacy
    case editRecipe(RecipeDefinition)
    case editSavedRecipe(RecipeDefinition)

    /// Stable string identity per case (edit cases append the payload id so distinct edits
    /// re-present). Also the public id space for UI-test and deep-link routing — keep in sync
    /// with `FernletSheet(uiTestID:)`.
    var id: String {
        switch self {
        case .meal: "meal"
        case .recipe: "recipe"
        case .water: "water"
        case .sleep: "sleep"
        case .journal: "journal"
        case .workout: "workout"
        case .workoutSuggestion: "workoutSuggestion"
        case .goals: "goals"
        case .hygiene: "hygiene"
        case .settings: "settings"
        case .recipeBook: "recipeBook"
        case .trends: "trends"
        case .milestones: "milestones"
        case .stressExplainer: "stressExplainer"
        case .firstAid: "firstAid"
        case .logPeriod: "logPeriod"
        case .logIntimacy: "logIntimacy"
        case .editRecipe(let r): "editRecipe-\(r.id)"
        case .editSavedRecipe(let r): "editSavedRecipe-\(r.id)"
        }
    }
}
