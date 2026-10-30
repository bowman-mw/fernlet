#if canImport(UIKit)
import ProximityKit
import UIKit
import LocalPersistence
#endif
import HealthKit
import LocalAuthentication
import SwiftUI
import UniformTypeIdentifiers
import FernletDomainModel
import FernletFoundation
import FernletLock
import FernletScoring
import HealthKitGateway
import AppServices
import FernletUI
import FernletLockUI

/// The Settings hub: a searchable, four-group Form (2026-08-21 restructure, artboard 5a —
/// SETT-14/26/28/29) that routes to every settings sub-page. Each row carries a one-line sub-label
/// breadcrumb saying what is inside it; the groups are **Your day** (Appearance, Goal & nutrition,
/// Reminders, Personal care tasks, Quick-log shortcuts, Sounds & haptics), **Home map** (World build step 5c:
/// ``HomeMapSettingsView``, location, the fog, routes and places), **Friends** (Friends & Blocks,
/// Nearby friends; `b4-mem-settings-friends`), **Data & sources** (AI & data sources,
/// Health), **Privacy & data** (Privacy & Data, App lock, Safety & reporting, Privacy Policy, AI
/// activity log), and **Private** (Period & sensitive content), followed
/// by the Danger zone and — in DEBUG builds only — an Advanced section holding the one Connection
/// log row (SETT-28 folded Debug + Connection Inspector behind `#if DEBUG`).
///
/// Presented as a sheet from the main UI over a `NavigationStack`. Navigation is value-based: every
/// link and every search result pushes a ``SettingsRoute``, resolved by the single
/// `destination(for:)` factory — the scroll-wrapped tabs (appearance, goal & nutrition, AI & data
/// sources, personal care, memories, signals, debug, connection log) are built inline here, while
/// the standalone screens (``PrivacyDataSettingsView``, ``HealthAccessSettingsView``,
/// ``NearbyFriendsSettingsView``, ``PeriodSensitiveSettingsView``, ``QuickLogShortcutsEditor``,
/// ``SoundsHapticsSettingsView``,
/// ``PrivacyPolicyView``, ``AcknowledgmentsView``, `SafetyReportingView`, ``AIAuditLogView``,
/// ``AppLockSettingsView``)
/// return with their own chrome. A non-empty search query swaps the Form for a
/// ``SettingsSearchIndex`` results list.
///
/// The Reminders row deliberately routes to `.goalNutrition` (where the reminders card lives)
/// rather than a page of its own: the reminder search entries are pinned to that route by
/// `SettingsSearchIndexTests`' frozen "notif" fixture, and one destination for one card beats a
/// duplicated card.
///
/// Key collaborators: ``FernletStore`` (`@Bindable`, all setting mutations), `FernletLockService`
/// and `StoragePreferencesStore` from the environment, `HealthKitAuthorizationViewModel` for the
/// body-signals opt-in, and `NotificationService` for the daily check-in reminder (the pending
/// notification request is that feature's persistence — the local `@State` merely mirrors it per
/// visit, and the hub's Reminders sub-label reads the same mirror).
///
/// Invariants this view enforces:
/// - Nothing destructive happens silently: removing a core memory or a personal-care task routes
///   through ``DestructiveConfirmation``, and "Delete everything" presents the typed-gate
///   ``DeleteEverythingSheet``; a wipe raises `deleteFlow.isDeleting` (``DeleteEverythingFlow``)
///   to show ``DeletingEverythingOverlay``, disable the delete/Done buttons, and block interactive
///   dismissal so a second confirm can't interleave.
/// - Display text on hub rows goes through `LocalizedStringKey` parameters (`hubLink` /
///   `hubToggle`), never `String` — a `String` parameter silently opts the call site out of
///   localization.
struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    /// The user's term of address (the app root sets it from the body profile), for copy that
    /// describes them: the memory headings' feeling names and the AI section's companion line.
    @Environment(\.fernletTermOfAddress) private var termOfAddress
    @Bindable var store: FernletStore
    /// World build: set when Settings shows in a World panel, which closes through its own ✕, so the
    /// sheet's Done button steps aside and a finished delete closes the panel; nil in a sheet.
    var onClose: (() -> Void)? = nil
    @Environment(FernletLockService.self) private var lockService
    @Environment(StoragePreferencesStore.self) private var storagePreferencesStore
    /// System / Light / Dark. The app root reads the same key and hands ``FernletAppearanceMode``'s
    /// `colorScheme` (nil for `.system`) to `preferredColorScheme`, so "System" really does follow
    /// the phone; the legacy Dark-mode Bool is migrated once at launch.
    @AppStorage(FernletAppearanceMode.storageKey) private var appearanceMode: FernletAppearanceMode = .system
    /// This screen's own "delete everything" wipe state (busy / success / failure) plus the shared
    /// confirmation glue — deliberately per-screen, never shared with ``PrivacyDataSettingsView``'s.
    @State private var deleteFlow = DeleteEverythingFlow()
    /// Confirmation for consequential Settings changes (see `DestructiveConfirmation`). Hiding period /
    /// intimacy keeps the data, but changes what Fernlet reads and how the score behaves — so it is
    /// confirmed rather than silent.
    @State private var pendingDestructiveAction: DestructiveConfirmation?
    @State private var editingMemory: MemoryNote?
    @State private var memorySearch = ""
    @State private var newCareTaskName = ""
    @State private var newCareTaskGroup = "Anytime"
    @State private var healthKit = HealthKitAuthorizationViewModel()
    // Daily check-in reminder. The pending notification request IS the persistence (it survives
    // relaunches and matches whatever onboarding scheduled), so these mirror it — loaded once
    // per Settings visit, written straight through NotificationService.
    @State private var dailyCheckInEnabled = false
    @State private var dailyCheckInTime = Calendar.current.date(bySettingHour: 19, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var didLoadDailyCheckIn = false
    @State private var dailyCheckInAuthDenied = false
    /// Presents the typed-gate ``DeleteEverythingSheet`` for this screen's Danger-zone row (the
    /// pushed Privacy & Data screen owns its own presentation and its own flow).
    @State private var showDeleteEverything = false
    /// Sub-labels drop at accessibility sizes (5a·AX3): the breadcrumb line is the first casualty.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// The World's framed look (set at the app's root): Settings draws its own framed search field
    /// and framed rows under it, and today's system chrome without it.
    @Environment(\.fernletFramedLook) private var framedLook
    /// Settings search query (item 10). Non-empty swaps the Form for a results List; the search bar
    /// lives on the stable `settingsContent` so it persists across that swap.
    @State private var settingsSearch = ""
    // Debug tab only: tier-2 records load post-render (a disk read of the device-local sidecar).
    @State private var debugTierTwoMemories: [TierTwoMemoryRecord]?
    #if DEBUG
    // Debug tab only: the Phase-0 cryptographic format census, loaded post-render for the same
    // reason — it scans the sealed store, both media roots, a keychain row and five sidecar files.
    // Nil until the scan returns; see `cryptoFormatCensusSection`. `#if DEBUG` because
    // `CryptoFormatCensus` itself is compiled out of Release — the whole surface is absent there,
    // not merely unreachable.
    @State private var cryptoFormatCensus: CryptoFormatCensusReport?
    /// One in-flight census at a time (R3). Unlike the reschedule/sync tasks below this is not a
    /// debounce: the scan blocks a cooperative worker for its whole run and ignores cancellation
    /// (see ``CryptoFormatCensus``), so a push → pop → push before it returns would stack a SECOND
    /// full sweep of the sealed store and both media roots behind the first. Held here — on the
    /// sheet, which outlives each destination push — so re-entry re-awaits the running scan.
    @State private var cryptoFormatCensusTask: Task<Void, Never>?
    /// The Phase 3 gate readout's in-flight local scan — held HERE for exactly the reason the
    /// census's comment above gives (the sheet outlives each destination push). Only the in-flight
    /// HANDLE lives here; every purchased reading lives on `store.phase3ReadoutSession`, because
    /// that sitting also spans a sheet DISMISSAL — the sealed-column keyed pass can only be funded
    /// by a hub unlock, which means leaving Settings and coming back.
    @State private var phase3ScanTask: Task<Void, Never>?
    #endif
    /// One in-flight reminder reschedule at a time (R3): the DatePicker emits a change per wheel
    /// tick, and they all write the same notification identifier.
    @State private var checkInRescheduleTask: Task<Void, Never>?
    /// One in-flight HealthKit body-profile sync at a time (R3): Stepper/Picker ticks would otherwise
    /// each spawn their own `saveBodyProfileMeasurements` write for a single edit session.
    @State private var profileSyncTask: Task<Void, Never>?
    /// One in-flight search-result announcement at a time (T2-14) — the debounce itself. See
    /// ``announceSearchResultCount(_:)``.
    @State private var searchAnnouncementTask: Task<Void, Never>?

    /// The pushed pages. Empty on open, except a DEBUG screenshot run's `FERNLET_UI_TEST_BB_SCENARIO=goal`,
    /// which opens on Goal & nutrition (`bb-goal`).
    /// Type-erased, so a page that pushes its own value type keeps working inside the stack.
    @State private var settingsPath = NavigationPath(UITestSupport.bodybuildingScenario == "goal" ? [SettingsRoute.goalNutrition] : [])

    var body: some View {
        NavigationStack(path: $settingsPath) {
            settingsRoot
                .navigationDestination(for: SettingsRoute.self) { route in
                    destination(for: route)
                        // Each pushed page's keyboard "Done" (the nutrition targets' number pads,
                        // core memory's search, the care-task field): the sheet chrome's Done sits
                        // outside this stack and reaches no page in it.
                        .keyboardDoneToolbar()
                }
                // T2-14: the Form ⇄ results swap is silent to VoiceOver — nothing moves the cursor
                // and the field's own value is the typed query, not the outcome. Watches the COUNT,
                // not the query, so keystrokes that leave the same number of matches standing say
                // nothing; see `announceSearchResultCount(_:)` for the second gate.
                .onChange(of: searchResultCount) { _, count in
                    announceSearchResultCount(count)
                }
        }
        // The Settings sheet is a separate presentation from the tab content, so ContentView's
        // `.tint(Color.moss)` never reached it — every hub Toggle rendered the system green.
        .tint(Color.moss)
        .fernletPageBackground()
        .overlay {
            if deleteFlow.isDeleting {
                DeletingEverythingOverlay()
            }
        }
        // No swipe-to-dismiss mid-wipe: a wipe is multi-second and the sheet must not close (or re-run)
        // out from under it. In a World panel the plate's ✕ is held off the same way.
        .interactiveDismissDisabled(deleteFlow.isDeleting)
        .worldPanelHeld(deleteFlow.isDeleting)
        .destructiveConfirmation($pendingDestructiveAction)
        // Success ("Done") dismisses the sheet — the visit is over; failure keeps it put for a retry.
        .deleteEverythingAlerts(deleteFlow, successButtonTitle: "Done", successButtonRole: nil) {
            if let onClose { onClose() } else { dismiss() }
        }
        // The typed-gate confirm (artboard 5e). The offer and iCloud claims are computed at
        // presentation time; nothing mutates until the sheet's armed confirm calls `runWipe`.
        .sheet(isPresented: $showDeleteEverything) {
            DeleteEverythingSheet(
                offer: deleteFlow.healthSampleOffer(
                    masterEnabled: storagePreferencesStore.preferences.healthKitMasterEnabled,
                    everRequestedWritableCapability: nil
                ),
                hasICloudDayCopy: storagePreferencesStore.preferences.hasICloudDayCopy,
                hasSealedBackup: storagePreferencesStore.preferences.hasSealedBackup
            ) { includeHealth in
                deleteFlow.runWipe(store: store, includingHealthSamples: includeHealth)
            }
        }
    }

    /// Settings' first page. Under the World's framed look (`b2-settings-root`): the framed search
    /// field pinned under the plate (or under the sheet's header), then the page, with no navigation
    /// bar, so nothing sits between the plate and the field. Without the look: today's system search
    /// drawer and the navigation bar's Done.
    @ViewBuilder
    private var settingsRoot: some View {
        if framedLook != nil {
            // The field sits ABOVE the list, not in the list's safe-area inset: the first keystroke
            // swaps the page for the results (`settingsContent`), and a field hosted in the swapped
            // list's inset lost the keyboard on that swap, so only the first letter was ever typed.
            VStack(spacing: 0) {
                SettingsSearchField(title: "Search settings", text: $settingsSearch)
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                settingsContent
            }
            // The dotted page behind the field too (the list paints only its own area).
            .fernletPageBackground()
            .modifier(SettingsRootChrome(inPanel: onClose != nil, isDeleting: deleteFlow.isDeleting) { dismiss() })
        } else {
            settingsContent
                .navigationTitle(Text("Settings"))
                // navigationBarDrawer keeps the field at the top (classic settings idiom). The
                // iOS 26 default docks a floating capsule over the sheet's bottom rows, where it
                // swallows taps on whatever row settles behind it.
                .searchable(text: $settingsSearch, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search settings")
                // Setting names, not sentences: the automatic capitalization turned a typed
                // "lock" into "Lock" while the user was still choosing what to search for.
                .textInputAutocapitalization(.never)
                // Done lives in the nav bar, not a permanent bottom inset: the inset pill plus the
                // search field left exactly one row visible at accessibility text sizes, and every
                // other sheet closes from its chrome.
                .toolbar {
                    if onClose == nil {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { dismiss() }
                                .font(.fernlet(.label))
                                .foregroundStyle(Color.moss)
                                .disabled(deleteFlow.isDeleting)
                                .accessibilityIdentifier("settings.done")
                        }
                    }
                }
        }
    }

    /// Whether the search field currently has a query. Drives the Form ⇄ results swap.
    private var isSearching: Bool {
        !settingsSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// How many settings the current query matches, or `nil` while the field is empty and the Form
    /// — not a result list — is what is on screen. `nil` rather than `0` so clearing the field is
    /// silent instead of announcing "0 settings" at a user who just cancelled a search.
    private var searchResultCount: Int? {
        guard isSearching else { return nil }
        return SettingsSearchIndex.results(for: settingsSearch).count
    }

    /// The plural-correct "6 settings" sentence.
    ///
    /// A catalog key with the number as an ARGUMENT, never an English `"s"` glued on in Swift: a
    /// `count == 1 ? "setting" : "settings"` ternary welds the app to a two-form plural rule most
    /// languages do not have, and produces a string no translator ever sees.
    private static func searchResultCountText(_ count: Int) -> String {
        String(localized: "settings.search.resultCount", defaultValue: "\(count) settings",
               comment: "Spoken count of settings search results, e.g. '6 settings'. Needs a plural variation per language; English also needs the one-setting form.")
    }

    /// Speaks how many settings the query now matches, debounced so the field does not talk once
    /// per keystroke.
    ///
    /// Announcement rather than a value on the field: `.searchable` vends a system search control
    /// this view cannot attach a value to, and the field's value is legitimately the typed query —
    /// overwriting it would cost a blind user the ability to hear back what they typed. The results
    /// are a plain `List` whose rows are the accessibility elements, and wrapping a `List` in an
    /// accessibility container to hang a value on it changes the list's own semantics. So on this
    /// surface the announcement is the whole mechanism, and the debounce is what makes it bearable:
    /// typing "l-o-c-k" walks the count 12 → 6 → 4 → 4 and speaks only "4 settings", because each
    /// new count cancels the announcement the previous one scheduled. A cancelled sleep simply ends
    /// the superseded task, exactly as `rescheduleDailyCheckIn(at:)` below.
    ///
    /// A count, never a matched row: an announcement is spoken aloud into the room, and the
    /// announcer's standing rule is to announce the event and not the payload.
    private func announceSearchResultCount(_ count: Int?) {
        searchAnnouncementTask?.cancel()
        guard let count else { return }
        searchAnnouncementTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(450))
            } catch {
                return  // superseded by a newer keystroke (or the sheet went away)
            }
            guard !Task.isCancelled else { return }
            FernletAnnouncer.system.announce(.status, resolved: Self.searchResultCountText(count))
        }
    }

    @ViewBuilder
    private var settingsContent: some View {
        if isSearching {
            searchResultsList
        } else {
            settingsForm
        }
    }

    /// Search results: one value-based link per matching leaf (title + breadcrumb subtitle), routed
    /// through the same `.navigationDestination`. A quiet row stands in when nothing matches.
    ///
    /// Rows render ``SettingsSearchEntry/displayTitle`` and ``SettingsSearchEntry/displayBreadcrumb``
    /// — the display halves of the entry's token/display fork. `entry.title` and `entry.breadcrumb`
    /// are frozen English tokens and must never reach a `Text`: as a `String` either would take
    /// `Text`'s verbatim initializer and render untranslated.
    private var searchResultsList: some View {
        // A Form, so under the framed look the results are one framed card of rows with dotted
        // rules, like the page they replace (`b2-settings-root`).
        Form {
            Section {
                let results = SettingsSearchIndex.results(for: settingsSearch)
                if results.isEmpty {
                    Text("No matching settings")
                        .font(framedLook == nil ? .fernlet(.body) : FernletFramedFont.rowTitle)
                        .foregroundStyle(framedLook?.dim ?? Color.slate)
                        .listRowBackground(Color.cream)
                } else {
                    ForEach(results) { entry in
                        NavigationLink(value: entry.route) {
                            FernletRowLabel(title: Text(entry.displayTitle), detail: Text(entry.displayBreadcrumb))
                        }
                        .listRowBackground(Color.cream)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .fernletPageBackground()
    }

    /// The route factory: the single place each sub-page destination is built, replacing the former
    /// inline closure destinations. Reuses `settingsDestination(title:)` for the scroll-wrapped tabs;
    /// the standalone screens (Privacy & Data, App lock, …) return directly with their own chrome.
    @ViewBuilder
    private func destination(for route: SettingsRoute) -> some View {
        switch route {
        case .appearance:
            settingsDestination(title: "Appearance") { appearanceTab }
        case .goalNutrition:
            settingsDestination(title: "Goal & nutrition") { generalTab }
        case .personalCare:
            settingsDestination(title: "Personal care tasks") { personalCareSettings }
        case .layoutShortcuts:
            QuickLogShortcutsEditor(store: store)
        case .soundsHaptics:
            SoundsHapticsSettingsView()
        case .homeMap:
            HomeMapSettingsView(store: store)
        case .aiDataSources:
            settingsDestination(title: "AI & data sources") { aiDataSourcesTab }
        case .health:
            HealthAccessSettingsView(store: store)
        case .coreMemory:
            settingsDestination(title: "Core memory") { memoriesTab }
        case .signals:
            settingsDestination(title: "Signals") { signalsTab }
        case .debug:
            settingsDestination(title: "Debug") { debugTab }
        case .connectionInspector:
            settingsDestination(title: "Connection log") { connectionInspectorTab }
        case .connectionHistory:
            ConnectionInspectorHistoryView(inspector: store.connectionInspector)
        case .privacyData:
            PrivacyDataSettingsView(store: store)
                .environment(lockService)
        case .aiAuditLog:
            AIAuditLogView()
        case .privacyPolicy:
            PrivacyPolicyView()
        case .acknowledgments:
            AcknowledgmentsView()
        case .safetyReporting:
            SafetyReportingView()
        case .appLock:
            AppLockSettingsView()
                .environment(lockService)
                .fernletLockGate(scope: .appLockSettings, active: lockService.isLockConfigured)
                .environment(lockService)
        case .sharing:
            SharingSettingsView(store: store)
        case .nearbyFriends:
            NearbyFriendsSettingsView(store: store)
        case .friendsBlocks:
            // The page the Friends tab's header used to push (b2-friend-list), with Back to Settings.
            FriendListView(store: store, isTabBarCompact: .constant(false), tabResetToken: .constant(0))
                .fernletPushedPage("Friends & Blocks")
        case .periodSensitive:
            PeriodSensitiveSettingsView(store: store)
        }
    }

    private var settingsForm: some View {
        Form {
            // R8: the App Review demo build's "sample data / Leave demo" section (`ReviewDemo`).
            #if FERNLET_DEMO
            ReviewDemoSettingsSection(store: store)
            #endif
            yourDaySection
            homeMapSection
            friendsSection
            dataSourcesSection
            privacyHubSection
            friendsPrivateSection
            dangerSection
            #if DEBUG
            advancedSection
            #endif
        }
        .scrollContentBackground(.hidden)
        .background(Color.parchment)
        // The Reminders sub-label mirrors the pending notification request; load it once per
        // visit so the hub can say "Daily check-in · 8:30 pm" without the page being opened.
        .task { await loadDailyCheckInState() }
    }

    /// A hub section header in the app's type system rather than system SF.
    ///
    /// ``SectionLabel`` now sets its own `.textCase(.uppercase)` inside its body, closer to the
    /// `Text` than any environment value a Form sets — so the Form's automatic uppercasing can
    /// neither double it nor be doubled by it, and the `.textCase(nil)` guard this used to carry
    /// (already inert against the old `String.uppercased()`) is gone.
    private func hubSectionHeader(_ title: LocalizedStringKey) -> some View {
        SectionLabel(title)
    }

    /// A hub navigation row: the standard value-based link, drawn in DM Sans like every other list
    /// in the app (a bare `NavigationLink("…", value:)` renders in system SF).
    ///
    /// `title` is `LocalizedStringKey`, never `String`: a `String` parameter silently opts every
    /// call site out of localization — the literal looks auto-localizing, extracts into no catalog,
    /// and renders English forever on a clean build. All fifteen call sites pass a literal, so none
    /// needed editing and none carries runtime text; if one ever must, it gets a distinctly-labelled
    /// `verbatim:` sibling rather than a same-label `String` overload (which would win for a plain
    /// literal and quietly re-introduce the bug).
    private func hubLink(_ title: LocalizedStringKey, _ route: SettingsRoute) -> some View {
        NavigationLink(value: route) {
            FernletRowLabel(title)
        }
    }

    /// A hub row with a one-line sub-label breadcrumb (artboard 5a: each row states what is inside
    /// it). `subtitle` is a `Text` because several sub-labels carry runtime values (the reminder
    /// time, the care-task count, the Health share counts); authored halves still localize at the
    /// call site through `Text`'s `LocalizedStringKey` initializer. Sub-labels drop at
    /// accessibility sizes (5a·AX3: the breadcrumb line is the first casualty).
    private func hubLink(_ title: LocalizedStringKey, subtitle: Text, _ route: SettingsRoute) -> some View {
        NavigationLink(value: route) {
            // The framed row's name and second line (`.sl`, `b2-settings-root`).
            FernletRowLabel(title: Text(title), detail: dynamicTypeSize.isAccessibilitySize ? nil : subtitle)
        }
        // The spoken/queryable label stays the row NAME alone: folding the sub-label into it made
        // every row a sentence (and broke every `buttons["Goal & nutrition"]`-style lookup other
        // suites rely on). But the sub-label is still information — Reminders' check-in time, the
        // care-task count, Health's share counts are LIVE state — so it rides `accessibilityValue`:
        // VoiceOver speaks it after the name, and label-based lookups stay intact.
        .accessibilityLabel(Text(title))
        .accessibilityValue(subtitle)
    }

    // MARK: - Hub groups (artboard 5a)

    /// "Your day": what the user configures about their own day. Appearance keeps its row here
    /// (spec note 3: every row on the old hub has a stated home).
    private var yourDaySection: some View {
        Section {
            hubLink("Appearance", subtitle: Text("Theme, backgrounds, companion, Today panel"), .appearance)
                .accessibilityIdentifier("settings.row.appearance")
            hubLink("Goal & nutrition", subtitle: Text("Goal, body, targets, hydration, calories"), .goalNutrition)
                .accessibilityIdentifier("settings.row.goalNutrition")
            hubLink("Reminders", subtitle: remindersRowSubtitle, .goalNutrition)
                .accessibilityIdentifier("settings.row.reminders")
            hubLink("Personal care tasks", subtitle: personalCareRowSubtitle, .personalCare)
                .accessibilityIdentifier("settings.row.personalCare")
            hubLink("Quick-log shortcuts", subtitle: Text("Six tiles in Log"), .layoutShortcuts)
                .accessibilityIdentifier("settings.row.quickLog")
            hubLink("Sounds & haptics", subtitle: Text("Haptics, workout sounds, spoken cues"), .soundsHaptics)
                .accessibilityIdentifier("settings.row.soundsHaptics")
        } header: {
            hubSectionHeader("Your day")
        }
        .listRowBackground(Color.cream)
    }

    /// "Home map" (World build step 5c; `b2-settings-root` draws it between Your day and the groups
    /// below): location, the fog, routes and places, one page (`b1-settings-map`).
    private var homeMapSection: some View {
        Section {
            hubLink("Home map", subtitle: Text("Location, fog, routes, places"), .homeMap)
                .accessibilityIdentifier("settings.row.homeMap")
        } header: {
            hubSectionHeader("Home map")
        }
        .listRowBackground(Color.cream)
    }

    /// "Data & sources": what feeds Fernlet — the AI/web/weather/body-signal switches and Health.
    private var dataSourcesSection: some View {
        Section {
            hubLink("AI & data sources", subtitle: Text("On-device AI, web lookup, weather, body signals"), .aiDataSources)
                .accessibilityIdentifier("settings.row.aiDataSources")
            hubLink("Health", subtitle: healthRowSubtitle, .health)
                .accessibilityIdentifier("settings.row.health")
        } header: {
            hubSectionHeader("Data & sources")
        }
        .listRowBackground(Color.cream)
    }

    /// "Privacy & data" keeps what it is for: storage, backups, export, delete — plus the
    /// standalone privacy screens. The friend toggles left for ``NearbyFriendsSettingsView``.
    private var privacyHubSection: some View {
        Section {
            hubLink("Privacy & Data", subtitle: Text("Storage, backups, export, delete"), .privacyData)
                .accessibilityIdentifier("settings.row.privacyData")
            hubLink("Sharing settings", subtitle: Text("Trainer summaries and manual plan exchange"), .sharing)
                .accessibilityIdentifier("settings.row.sharing")
            hubLink("App lock", .appLock)
                .accessibilityIdentifier("settings.row.appLock")
            hubLink("Safety & reporting", .safetyReporting)
                .accessibilityIdentifier("settings.row.safety")
            hubLink("Privacy Policy", .privacyPolicy)
                .accessibilityIdentifier("settings.row.privacyPolicy")
            // The notices Fernlet's licenses ask it to carry (CryptoSwift's acknowledgment first).
            hubLink("Acknowledgments", .acknowledgments)
                .accessibilityIdentifier("settings.row.acknowledgments")
            // The "what left my device" ledger — a disclosure surface, not a control.
            hubLink("AI activity log", .aiAuditLog)
                .accessibilityIdentifier("settings.aiAuditLog")
        } header: {
            hubSectionHeader("Privacy & data")
        }
        .listRowBackground(Color.cream)
    }

    /// "Friends" (World Review Batch 4, `b4-mem-settings-friends`): Friends & Blocks — the friend list and
    /// the name you appear as, which left the Friends tab's header when the tab became the Album — and
    /// Nearby friends, each saying what it holds now.
    private var friendsSection: some View {
        Section {
            hubLink("Friends & Blocks", subtitle: friendsRowSubtitle, .friendsBlocks)
                .accessibilityIdentifier("settings.row.friendsBlocks")
            hubLink("Nearby friends", subtitle: nearbyFriendsRowSubtitle, .nearbyFriends)
                .accessibilityIdentifier("settings.row.nearbyFriends")
        } header: {
            hubSectionHeader("Friends")
        }
        .listRowBackground(Color.cream)
    }

    /// "Private": the sensitive-surface gates (Nearby friends moved up to the Friends group). Carries
    /// the hub's one-sentence standing promise as its footer — the ~90-word paragraph became this
    /// line (SETT-14); the detail moved to the pages that own it.
    private var friendsPrivateSection: some View {
        Section {
            hubLink("Period & sensitive content", subtitle: Text("Visibility, gating, app lock"), .periodSensitive)
                .accessibilityIdentifier("settings.row.periodSensitive")
        } header: {
            hubSectionHeader("Private")
        } footer: {
            Text("Everything stays on your device unless you turn it on.")
        }
        .listRowBackground(Color.cream)
    }

    #if DEBUG
    /// DEBUG-only Advanced section (SETT-28): the old Debug and Connection Inspector rows folded
    /// into one Connection log row, compiled out of release builds entirely (search withholds the
    /// routes there too — see `SettingsSearchIndex.results(for:)`).
    private var advancedSection: some View {
        Section {
            hubLink("Connection log", .connectionInspector)
                .accessibilityIdentifier("settings.row.connectionLog")
            NavigationLink {
                NetworkMeshFeasibilityProbeView()
                    .fernletPushedPage("Mesh network feasibility")
            } label: {
                FernletRowLabel("Mesh network feasibility")
            }
            .accessibilityIdentifier("settings.row.meshNetworkFeasibility")
        } header: {
            hubSectionHeader("Advanced")
        }
        .listRowBackground(Color.cream)
    }
    #endif

    // MARK: - Hub row sub-labels (live values)

    /// "Daily check-in · 8:30 PM", or the off state — read from the same per-visit mirror the
    /// reminders card uses.
    private var remindersRowSubtitle: Text {
        if dailyCheckInEnabled {
            Text("Daily check-in · \(dailyCheckInTime.formatted(date: .omitted, time: .shortened))")
        } else {
            Text("Daily check-in off")
        }
    }

    /// "You appear as Redesign iPhone 17 · 2 friends": the name nearby people see, and how many kept
    /// friends there are (not blocked, not removed).
    private var friendsRowSubtitle: Text {
        let friends = store.trustedProximityPeers.filter { $0.blockedAt == nil && $0.revokedAt == nil }.count
        return Text("You appear as \(store.resolvedProximityDisplayName) · ^[\(friends) friends](inflect: true)")
    }

    /// "Presence on" / "Presence off": whether friends can see you're nearby.
    private var nearbyFriendsRowSubtitle: Text {
        store.settings.allowNearbyPresence ? Text("Presence on") : Text("Presence off")
    }

    /// "N tasks". (The design canvas's "N daily, M weekly" cannot be said truthfully — care tasks
    /// group by morning/anytime/evening, not by cadence.)
    private var personalCareRowSubtitle: Text {
        Text("^[\(store.personalCareTasks.count) tasks](inflect: true)")
    }

    /// "N of M kinds shared" — real counts over the offered capability cards — or the off state.
    private var healthRowSubtitle: Text {
        let counts = HealthAccessSettingsView.sharedKindCounts(
            preferences: storagePreferencesStore.preferences,
            visible: store.visibleHealthCapabilities
        )
        if storagePreferencesStore.preferences.healthKitMasterEnabled {
            return Text("\(counts.shared) of \(counts.total) kinds shared")
        }
        return Text("Health is off")
    }

    /// A settings switch in the app's type system. The moss switch colour comes from the
    /// sheet-level `.tint(Color.moss)`.
    ///
    /// `title` is `LocalizedStringKey`, never `String` — same rule and same reasoning as
    /// ``hubLink(_:_:)``: a `String` parameter silently opts every call site out of localization
    /// (the literal looks auto-localizing, extracts into no catalog, and renders English forever on
    /// a clean build). Every call site passes a literal; if one ever must carry runtime text, it
    /// gets a distinctly-labelled `verbatim:` sibling rather than a same-label `String` overload
    /// (which would win for a plain literal and quietly re-introduce the bug). The signature is
    /// source-pinned by `SettingsSearchIndexTests`, and the moved sub-pages
    /// (``PeriodSensitiveSettingsView``, ``NearbyFriendsSettingsView``) follow the same shape.
    ///
    /// In a framed section it is one row (`.sr` with its switch): the name, and `detail` as the row's
    /// second line when given (`b2-settings-ai`).
    private func hubToggle(_ title: LocalizedStringKey, detail: Text? = nil, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            // A two-line row takes the kit's row padding above and below its words.
            FernletRowLabel(title: Text(title), detail: detail)
                .padding(.vertical, detail == nil ? 0 : 7)
        }
    }

    private var dangerSection: some View {
        Section {
            resetSection
        } header: {
            hubSectionHeader("Danger zone")
        }
        .listRowBackground(Color.cream)
    }

    private var connectionInspectorModeBinding: Binding<ConnectionInspectorMode> {
        Binding(
            get: { store.settings.connectionInspectorMode },
            set: { store.setConnectionInspectorMode($0) }
        )
    }

    /// The scroll-wrapped page shell shared by the inline tabs. `title` is `LocalizedStringKey`
    /// (never `String` — same rule as ``hubLink(_:_:)``); every call site passes a literal.
    private func settingsDestination<Content: View>(
        title: LocalizedStringResource,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ScrollView {
            // The framed page's margins (`.pnl`): 16 pt in, 14 under the plate, as a framed Form.
            content()
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 30)
        }
        .scrollContentBackground(.hidden)
        .fernletPageBackground()
        // In the World panel the title and Back go on the wooden plate (`b1-frame-push`); in the
        // Settings sheet it is the navigation title, as before.
        .fernletPushedPage(title)
    }

    private var appearanceTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel("Appearance")
            appearanceModeCard
            SectionLabel("Companion feelings")
            // A change re-derives the widget's emotion timeline, so republish it at once.
            CompanionFeelingsSettingsCard(onChange: { store.publishWidgetSnapshot() })
            // `b2-settings-appearance` (redrawn with `b2-colors`): today's two background pickers
            // moved into App colors (Paper, with Wood and Accent), one row here that pushes it.
            SectionLabel("Colors")
            FernletFramedSection(header: nil) {
                NavigationLink {
                    AppColorsPage(store: store)
                } label: {
                    AppColorsSettingsRow()
                }
                .buttonStyle(FernletRowButtonStyle(showsChevron: true))
                .accessibilityIdentifier("settings.appColors")
            }
            todayPanelSection
        }
    }

    /// System / Light / Dark as the framed segmented control (`b2-settings-appearance`), plus the
    /// follows-your-phone note, on one card. The control ticks when the mode really changes.
    private var appearanceModeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            FernletSegmentedPicker("Appearance", selection: $appearanceMode,
                                   options: FernletAppearanceMode.allCases) { Text(verbatim: $0.label) }
            Text("“System” follows your phone's Light/Dark setting, the way onboarding already does.")
                .font(FernletFramedFont.body)
                .foregroundStyle(framedLook?.dim ?? Color.slate)
                .fernletWrappingText()
        }
        .settingsCard()
    }

    /// The Today panel's row on the Appearance page (World build, design `b1-today-editor`, approved
    /// 2026-10-23): "Cards and their order" opens Arrange Today (``WorldTodayEditor``), which replaced
    /// the Home widgets editor here. The stored order and its ids are unchanged.
    ///
    /// NOTE: quick-log editing lives in ``QuickLogShortcutsEditor`` and edits the STORED array —
    /// never a visibility-filtered one (the destructive-filtering record lives on that type).
    private var todayPanelSection: some View {
        FernletFramedSection("Today panel") {
            NavigationLink {
                WorldTodayEditor(store: store)
                    .fernletPushedPage("Arrange Today")
                    .background { WorldPageBackground().ignoresSafeArea() }
            } label: {
                FernletRowLabel("Cards and their order", detail: "Opens Arrange Today")
            }
            .buttonStyle(FernletRowButtonStyle())
            .accessibilityIdentifier("settings.todayPanel")
        }
    }

    private var memoriesTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit or remove the notes Fernlet keeps from journals, plus the local trends it is inferring.")
                .font(FernletFramedFont.body)
                .foregroundStyle(framedLook?.dim ?? Color.slate)
                .fernletWrappingText()
                .padding(.horizontal, 4)

            // The framed search field (`b2-settings-memory`), the same one Settings' first page has.
            SettingsSearchField(title: "Search or type \"forget [keyword]\"", text: $memorySearch,
                                identifier: "settings.memorySearch")

            if let keyword = forgetKeyword {
                forgetShellView(keyword: keyword)
            }

            let displayed = filteredMemories
            if displayed.isEmpty && memorySearch.isEmpty {
                FernletCard { EmptyState(text: "Nothing yet. Memories grow as you write.") }
            } else if displayed.isEmpty {
                FernletCard { EmptyState(text: "No memories match that search.") }
            } else {
                let keys = groupedMemoryKeys(for: displayed)
                let groups = groupedMemories(for: displayed)
                ForEach(keys, id: \.self) { key in
                    // `key` is the persisted `MemoryNote.category` token, upper-cased for grouping.
                    // The heading draws it through `MemoryCategoryName`, which names the categories
                    // Fernlet itself writes (a journal feeling, "other") in the reader's language and
                    // leaves any other token as it was stored.
                    FernletFramedSection(header: Text(verbatim: MemoryCategoryName.heading(forGroup: key, addressing: termOfAddress))) {
                        ForEach(groups[key] ?? []) { memory in
                            memoryRow(memory)
                        }
                    }
                }
            }
        }
        .sheet(item: $editingMemory) { memory in
            // Full height, never .medium: the character counter, the source date and Delete all sat
            // below the fold of the half sheet. Paper with the wooden grabber (`b3-memory-editor`).
            MemoryEditorSheet(store: store, memory: memory)
                .fernletSheet()
        }
    }

    private var forgetKeyword: String? {
        let trimmed = memorySearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.hasPrefix("forget ") else { return nil }
        let keyword = String(trimmed.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
        return keyword.isEmpty ? nil : keyword
    }

    private var filteredMemories: [MemoryNote] {
        let trimmed = memorySearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return store.memories }
        let needle = forgetKeyword ?? trimmed.lowercased()
        return store.memories.filter { Self.memory($0, matches: needle) }
    }

    /// Search and "forget" match what the row SHOWS (`displayText` — for an emotion-only memory, the
    /// sentence built from its feeling) as well as the stored category token.
    private static func memory(_ memory: MemoryNote, matches needle: String) -> Bool {
        memory.displayText.localizedCaseInsensitiveContains(needle) ||
            memory.category.localizedCaseInsensitiveContains(needle)
    }

    @ViewBuilder private func forgetShellView(keyword: String) -> some View {
        let matches = store.memories.filter { Self.memory($0, matches: keyword) }
        if matches.isEmpty {
            FernletCard { EmptyState(text: "No memories match \"\(keyword)\".") }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                // Grammar agreement, not an English "y"/"ies" spliced in by count: the old splice
                // reached no catalog and welded the sentence to English's two-form plural.
                Text("Forget ^[\(matches.count) memory](inflect: true) matching \"\(keyword)\"?")
                    .font(.fernlet(.body))
                    .foregroundStyle(Color.bark)
                HStack(spacing: 16) {
                    Button(role: .destructive) {
                        matches.forEach { store.deleteMemory($0) }
                        memorySearch = ""
                    } label: {
                        Label("Delete \(matches.count)", systemImage: "trash")
                    }
                    .buttonStyle(DestructiveCardButtonStyle())
                    Button("Cancel") { memorySearch = "" }
                        .font(.fernlet(.label))
                        .foregroundStyle(Color.slate)
                }
                .frame(minHeight: 44)
            }
            .padding(14)
            .background(framedLook?.warn ?? Color.terracotta.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                // The framed warning (`.notice3.warn`): the look's warn fill in a 2-pt ink frame.
                if let framedLook {
                    RoundedRectangle(cornerRadius: 12).strokeBorder(framedLook.ink, lineWidth: FernletFramedLook.frameWidth)
                }
            }
        }
    }

    private var signalsTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Local trends Fernlet is inferring from journals, meals, sleep, and workouts.")
                .font(FernletFramedFont.body)
                .foregroundStyle(framedLook?.dim ?? Color.slate)
                .fernletWrappingText()
                .padding(.horizontal, 4)
            if store.derivedSignals.isEmpty {
                FernletCard { EmptyState(text: "More logs will make trends useful.") }
            } else {
                ForEach(store.derivedSignals) { signal in
                    if let framedLook {
                        SettingsSignalCard(signal: signal, look: framedLook)
                    } else {
                        SignalDetailRow(signal: signal)
                    }
                }
            }
        }
    }

    /// Shown under the goal cards when the user has pinned nutrition targets or an explicit training
    /// split: a preset only sets the *goal*, so those custom choices quietly win over the goal's plan.
    /// nil when nothing is pinned (the goal's own summaries then describe the plan in effect).
    ///
    /// One whole sentence per combination: it used to be assembled from English fragments
    /// ("custom nutrition targets" + " and " + …), which no translator could reorder or agree.
    private var goalOverrideFootnote: String? {
        let pinsTargets = store.settings.hasAnyNutritionOverride
        let pinsSplit = store.settings.workoutProfile.selectedSplitID != nil
        switch (pinsTargets, pinsSplit) {
        case (true, true):
            return String(localized: "settings.goal.overrideFootnote.targetsAndSplit",
                          defaultValue: "Your custom nutrition targets and chosen training split stay as you set them — clear them to follow this goal's plan.",
                          comment: "Goal & nutrition, under the goal cards: the user pinned both their own nutrition targets and a training split, which a goal preset does not override.")
        case (true, false):
            return String(localized: "settings.goal.overrideFootnote.targets",
                          defaultValue: "Your custom nutrition targets stay as you set them — clear them to follow this goal's plan.",
                          comment: "Goal & nutrition, under the goal cards: the user pinned their own nutrition targets, which a goal preset does not override.")
        case (false, true):
            return String(localized: "settings.goal.overrideFootnote.split",
                          defaultValue: "Your chosen training split stay as you set them — clear them to follow this goal's plan.",
                          comment: "Goal & nutrition, under the goal cards: the user picked a training split, which a goal preset does not override. One split: in translation the verb and pronoun agree with it ('stays as you set it').")
        case (false, false):
            return nil
        }
    }

    /// A binding onto one settings field that also **schedules the save**.
    ///
    /// `FernletSettings` has no `didSet`, so a bare `$store.settings.x` binding mutates the blob and
    /// waits for some *other* change to schedule a snapshot save. A user who flipped a Settings
    /// switch and force-quit without logging anything found it reverted on relaunch. Every switch,
    /// stepper and editor on this screen goes through here (or through a `store.setX` setter, which
    /// schedules its own save) so the change is durable the moment it is made.
    private func settingsBinding<Value>(_ keyPath: WritableKeyPath<FernletSettings, Value>) -> Binding<Value> {
        Binding(
            get: { store.settings[keyPath: keyPath] },
            set: { newValue in
                store.settings[keyPath: keyPath] = newValue
                store.scheduleSnapshotSave()
            }
        )
    }

    /// The profile screen shows the EFFECTIVE profile (typed, with this device's HealthKit import laid
    /// over it) and hands edits to `applyEditedBodyProfile`, which writes only the fields the user
    /// changed into the synced settings — a Health value merely shown here never lands there
    /// (2026-09-23).
    private var healthSyncedProfileBinding: Binding<UserNutritionProfile> {
        Binding(
            get: { store.effectiveUserProfile },
            set: { profile in
                store.applyEditedBodyProfile(profile)
                store.scheduleSnapshotSave()
                syncBodyProfileToHealth(profile)
            }
        )
    }

    /// Mirrors the edited body profile into HealthKit, at most one write in flight (R3).
    ///
    /// Weight and height are Steppers: holding one emits a value per tick, and
    /// `syncBodyProfileMeasurements` has no coalescing of its own, so without the cancel-previous a
    /// single edit session fans out into an unbounded number of concurrent HealthKit writes. The
    /// short sleep is the debounce; the latest value wins.
    private func syncBodyProfileToHealth(_ profile: UserNutritionProfile) {
        profileSyncTask?.cancel()
        profileSyncTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                return  // superseded by a newer edit (or the view went away)
            }
            guard !Task.isCancelled else { return }
            await healthKit.syncBodyProfileMeasurements(profile)
        }
    }

    /// The Goal & nutrition page: goal, body & preferences, hydration, reminders. The AI/coach/
    /// body-signal/personal-care sections that used to hide under this heading moved to their own
    /// homes in the 2026-08-21 restructure (AI & data sources, the trainer screen, Personal care
    /// tasks). Reminders stays here — the hub's Reminders row routes to this page.
    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            goalSection
            bodyAndPreferencesSection
            hydrationSection
            remindersSection
        }
    }

    /// The AI & data sources grouping page (artboard 5a): the on-device AI/web/weather switches,
    /// the body-signals opt-in, and the doors into Core memory and Signals.
    private var aiDataSourcesTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            aiSection
            bodySignalsSection
            memoryAndSignalsLinks
        }
    }

    /// Doors into the two inspection pages this group owns.
    private var memoryAndSignalsLinks: some View {
        FernletFramedSection("What Fernlet keeps") {
            settingsLinkRow("Core memory", route: .coreMemory)
            settingsLinkRow("Signals", route: .signals)
        }
    }

    /// A framed link row (`.sr` with its chevron) to a page pushed from inside a tab.
    private func settingsLinkRow(_ title: LocalizedStringKey, route: SettingsRoute) -> some View {
        NavigationLink(value: route) {
            FernletRowLabel(title)
        }
        .buttonStyle(FernletRowButtonStyle())
    }

    /// The goal presets, the sick/calories switches, and the footnote naming anything pinned that
    /// quietly overrides the chosen goal's plan.
    @ViewBuilder
    private var goalSection: some View {
        SectionLabel("Goal")
        // Preset cards: each goal shows its paired nutrition + training setup, so one choice reads as
        // configuring both. Replaces the bare Picker + lone tagline. The binding routes through
        // `setSelectedGoal` so the pick schedules a snapshot save (a bare keypath binding never did).
        GoalPresetCards(selectedGoal: Binding(
            get: { store.settings.selectedGoal },
            set: {
                store.setSelectedGoal($0)
                // Bodybuilding seats its Bathroom tile in Care's place, once (`bb-bowel`).
                store.seatBathroomTileIfNeeded()
            }
        ), weightManagementDeficitPercent: NutritionTargetCalculator.weightManagementDeficitPercent(for: store.settings))
        if let note = goalOverrideFootnote {
            Text(note)
                .font(FernletFramedFont.note)
                .foregroundStyle(framedLook?.dim ?? Color.slate)
                .fernletWrappingText()
                .padding(.horizontal, 4)
        }
        // 5c (SETT-15): the per-day sick flag lives on the day — the "I'm unwell today" row on
        // Home's Today card. Settings keeps only this control-free explanation of what gentle
        // scoring means, written from what `Scoring` actually does (workout weight → 0,
        // redistributed to sleep/hydration/care; hydration target ×1.2; companion → .sick).
        FernletFramedSection(header: nil, footer: Text("Feeling unwell? Mark “I'm unwell today” on the Today card, on Home. Scoring goes gentle for that day only: workouts stop counting against you, rest, water and personal care count for a little more, your water target nudges up, and your companion rests. It clears itself tomorrow.")) {
            hubToggle("Show calories", isOn: settingsBinding(\.showCalories))
        }
    }

    /// The body profile (HealthKit-synced) and the nutrition targets editor.
    ///
    /// No outer SectionLabel: the two cards below label themselves ("BODY PROFILE", "PREFERENCES"),
    /// and a third uppercase caption directly above them read as a doubled heading.
    @ViewBuilder
    private var bodyAndPreferencesSection: some View {
        ProfileEditor(profile: healthSyncedProfileBinding, preferences: settingsBinding(\.nutritionPreferences))

        NutritionTargetsEditor(store: store)
    }

    /// The AI switches: manual off, web nutrition lookup, weather-aware prompts, and the "Today" row and
    /// voice line from `FernletStore.aiStatusPresentation` — today's effective status, or why this iPhone
    /// cannot run the on-device model.
    private var aiSection: some View {
        // Framed rows (`b2-settings-ai`): each switch with its disclosure as the row's second line,
        // today's status as a value row, and the companion's line under the card.
        FernletFramedSection(header: Text("AI"),
                             footer: Text(FernletVoice.message(for: store.aiStatusPresentation.voiceLine, addressing: termOfAddress))) {
            // A positive switch: ON means the helper is available. "Manual off mode" was a double
            // negative — a green switch meant the AI was off — while every other switch in this
            // card reads the normal way round.
            hubToggle("On-device AI helper", isOn: aiEnabledBinding)
            FernletRowLabel("Today", value: Text(store.aiStatusPresentation.label))
            hubToggle("Web nutrition lookup", detail: Text("When you first use this, Fernlet will ask before sending your typed product search to DuckDuckGo. Once allowed, you can also tap to look up an unknown scanned barcode on Open Food Facts — only the barcode's number is sent. Turn it off here at any time to revoke permission."), isOn: webNutritionLookupBinding)
                .disabled(store.settings.aiStatus == .off)
            hubToggle("Weather-aware recovery prompts", detail: Text("On heavy, gloomy days Fernlet can offer a gentle recovery nudge. Uses your approximate location for weather only, never stored or shared."), isOn: weatherPromptsBinding)
            // The Apple Weather credit WeatherKit's terms ask for, where the feature is chosen: its own
            // row under the weather switch.
            AppleWeatherNotice()
        }
    }

    /// The weather switch: turning it on asks WeatherKit first and keeps whatever it answered.
    private var weatherPromptsBinding: Binding<Bool> {
        Binding(
            get: { store.settings.weatherPromptsEnabled },
            set: { newValue in
                if newValue {
                    Task {
                        let granted = await WeatherKitService.shared.requestAuthorization()
                        store.settings.weatherPromptsEnabled = granted
                        store.scheduleSnapshotSave()
                    }
                } else {
                    store.settings.weatherPromptsEnabled = false
                    store.scheduleSnapshotSave()
                }
            }
        )
    }

    private var webNutritionLookupBinding: Binding<Bool> {
        Binding(
            get: { store.settings.webNutritionLookupEnabled },
            set: { enabled in
                if enabled {
                    store.requestWebNutritionLookupConsent()
                } else {
                    store.revokeWebNutritionLookupConsent()
                }
            }
        )
    }

    /// The body-tension opt-in, its two plain-language disclosures, and the Health-needed note.
    @ViewBuilder
    private var bodySignalsSection: some View {
        FernletFramedSection(header: Text("Body signals"),
                             footer: Text("This is a wellbeing reflection, not medical advice. If you're worried about how you feel, please talk to a health professional.")) {
            hubToggle("Notice body tension", detail: Text("When this is on, Fernlet gently compares your heart rate variability, resting heart rate, respiration, and sleeping wrist temperature from Apple Health with your own usual range — never anyone else's — and may quietly note when your body seems a bit more tense than usual. Estimated and stored on this device only."), isOn: stressAwarenessBinding)
        }
        if store.settings.stressAwarenessEnabled && !storagePreferencesStore.preferences.healthKitMasterEnabled {
            FernletNotice("Body signals needs Apple Health. Turn on “Share with Health” under Settings › Health to feed it.", tone: .warn)
        }
    }

    /// The daily check-in reminder. Keeps its own `.task` mirror of the pending notification request
    /// and the reschedule-on-time-change handler.
    private var remindersSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            FernletFramedSection(header: Text("Reminders"),
                                 footer: Text("One gentle nudge a day — however the day went, a small note of care still counts. Change or turn it off any time.")) {
                hubToggle("Daily check-in", isOn: dailyCheckInBinding)
                if dailyCheckInEnabled {
                    DatePicker("Time", selection: $dailyCheckInTime, displayedComponents: .hourAndMinute)
                        .font(FernletFramedFont.rowTitle)
                        .foregroundStyle(framedLook?.text ?? Color.bark)
                }
            }
            if dailyCheckInAuthDenied {
                FernletNotice("Notifications are off for Fernlet in iOS Settings — allow them there and this toggle will work.", tone: .warn)
            }
        }
        .task { await loadDailyCheckInState() }
        .onChange(of: dailyCheckInTime) { _, newValue in
            guard didLoadDailyCheckIn, dailyCheckInEnabled else { return }
            rescheduleDailyCheckIn(at: newValue)
        }
    }

    /// Reschedules the one daily-check-in notification, at most one task in flight (R3).
    ///
    /// Dragging the DatePicker wheel emits a change per tick; without the cancel-previous the ticks
    /// would race on one notification identifier and the LAST TO FINISH — not the last value picked
    /// — would win. The short sleep is the debounce; a cancelled sleep simply ends the superseded
    /// task.
    private func rescheduleDailyCheckIn(at time: Date) {
        checkInRescheduleTask?.cancel()
        checkInRescheduleTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(300))
            } catch {
                return  // superseded by a newer tick (or the view went away)
            }
            guard !Task.isCancelled else { return }
            await scheduleDailyCheckIn(at: time)
        }
    }

    /// Bottle size and the daily bottle target, each a framed row with the framed stepper
    /// (`b2-settings-goal`). The stepper is what VoiceOver hears (its name is the row's words), so
    /// the drawn words are hidden from it.
    private var hydrationSection: some View {
        FernletFramedSection("Hydration") {
            HStack(spacing: 12) {
                Text("Bottle: \(store.settings.bottleOz) oz")
                    .font(FernletFramedFont.rowTitle)
                    .foregroundStyle(framedLook?.text ?? Color.bark)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityHidden(true)
                FernletStepper("Bottle: \(store.settings.bottleOz) oz", value: settingsBinding(\.bottleOz), in: 4...64, step: 1)
            }
            HStack(spacing: 12) {
                // Grammar agreement on the count: the plain literal fixed "bottles" for every number,
                // so a target of one read "1 bottles" and translators had no plural to work with.
                Text("Daily target: ^[\(store.settings.hydrationTarget) bottle](inflect: true)")
                    .font(FernletFramedFont.rowTitle)
                    .foregroundStyle(framedLook?.text ?? Color.bark)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityHidden(true)
                FernletStepper("Daily target: ^[\(store.settings.hydrationTarget) bottle](inflect: true)",
                               value: settingsBinding(\.hydrationTarget), in: 1...30, step: 1)
            }
        }
    }

    /// The AI switch, read the way it is drawn: ON means the on-device helper may run.
    private var aiEnabledBinding: Binding<Bool> {
        Binding(
            get: { store.settings.aiStatus != .off },
            set: { newValue in
                store.settings.aiStatus = newValue ? .ready : .off
                store.scheduleSnapshotSave()
            }
        )
    }

    /// Body-signals opt-in. Enabling is constructive and user-initiated, so it also (audited)
    /// switches on the `bodyContext` capability when Health integration is already enabled —
    /// the stress fetch fails closed on that per-capability gate — and triggers the contextual
    /// Health authorization prompt for the bodyContext read types. Disabling flips the flag
    /// and promptly scrubs the device-local sidecar (via `FernletStore.setStressAwarenessEnabled`).
    private var stressAwarenessBinding: Binding<Bool> {
        Binding(
            get: { store.settings.stressAwarenessEnabled },
            set: { newValue in
                store.setStressAwarenessEnabled(newValue)
                guard newValue else { return }
                if storagePreferencesStore.preferences.healthKitMasterEnabled {
                    if storagePreferencesStore.preferences.healthKitCapabilityEnabled[HealthCapability.bodyContext.rawValue] != true {
                        FernletAuditLog.log(
                            "privacy.healthKit.capabilityEnabled",
                            context: ["capability": HealthCapability.bodyContext.rawValue, "source": "bodySignalsOptIn"]
                        )
                        storagePreferencesStore.update { preferences in
                            preferences.healthKitCapabilityEnabled[HealthCapability.bodyContext.rawValue] = true
                        }
                    }
                    Task { await healthKit.request(.bodyContext) }
                }
            }
        )
    }

    /// Daily check-in toggle: enabling requests notification permission then schedules at the
    /// picked time; disabling cancels the pending request (`cancelDailyCheckIn` finally has a
    /// caller — before this, onboarding could only ever turn the reminder on).
    private var dailyCheckInBinding: Binding<Bool> {
        Binding(
            get: { dailyCheckInEnabled },
            set: { newValue in
                if newValue {
                    Task {
                        if await NotificationService.requestAuthorization() {
                            dailyCheckInAuthDenied = false
                            dailyCheckInEnabled = true
                            await scheduleDailyCheckIn(at: dailyCheckInTime)
                        } else {
                            dailyCheckInAuthDenied = true
                            dailyCheckInEnabled = false
                        }
                    }
                } else {
                    dailyCheckInEnabled = false
                    NotificationService.cancelDailyCheckIn()
                }
            }
        )
    }

    /// Mirrors the pending notification request into the toggle/time picker once per visit.
    private func loadDailyCheckInState() async {
        guard !didLoadDailyCheckIn else { return }
        if let scheduled = await NotificationService.scheduledDailyCheckIn() {
            dailyCheckInEnabled = true
            dailyCheckInTime = Calendar.current.date(
                bySettingHour: scheduled.hour, minute: scheduled.minute, second: 0, of: Date()
            ) ?? dailyCheckInTime
        }
        didLoadDailyCheckIn = true
    }

    private func scheduleDailyCheckIn(at time: Date) async {
        let components = Calendar.current.dateComponents([.hour, .minute], from: time)
        await NotificationService.scheduleDailyCheckIn(hour: components.hour ?? 19, minute: components.minute ?? 0)
    }

    /// The UI half of the personal-care caps. Both numbers now live on the domain type
    /// (`PersonalCareTask.maxTasks` / `.maxLabelLength`), which enforces them in `normalized(_:)` on
    /// every write — no writer can exceed them. This screen keeps its own check so the button
    /// disables *before* the tap instead of the row being silently clamped afterwards, and reads the
    /// domain constants so the two can never drift apart.
    private static let maxCustomCareTasks = PersonalCareTask.maxTasks
    /// R3 cap on the free-text task label — the domain's ``PersonalCareTask/maxLabelLength``.
    private static let maxCareTaskLabelLength = PersonalCareTask.maxLabelLength

    /// Add is unavailable for an empty label and once the task list is at its cap.
    private var isAddCareTaskDisabled: Bool {
        newCareTaskName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || store.personalCareTasks.count >= Self.maxCustomCareTasks
    }

    /// Raises the shared destructive confirmation for one personal-care task. The minus used to
    /// remove a saved task outright, with no confirmation and nothing to undo it with.
    private func confirmRemoveCareTask(_ task: PersonalCareTask) {
        pendingDestructiveAction = DestructiveConfirmation(
            // `displayLabel`, not the stored `label`: `PersonalCareTask` bakes the English label
            // into the settings blob when defaults are first written, so the stored string is inert
            // for built-ins and `displayLabel` is what resolves the current language. Its own doc
            // comment mandates exactly this, and this dialog was reading around it.
            title: "Remove \(task.displayLabel)?",
            message: "It comes off your personal care list. Days you've already ticked it stay as they are.",
            confirmLabel: "Remove",
            auditEvent: "settings.personalCare.removeConfirmed"
        ) {
            store.removePersonalCareTask(task)
        }
    }

    /// Appends one personal-care task, re-checking both caps at the point of use.
    private func addPersonalCareTask() {
        let label = String(newCareTaskName.prefix(Self.maxCareTaskLabelLength))
        guard !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard store.personalCareTasks.count < Self.maxCustomCareTasks else {
            FernletAuditLog.log("settings.personalCare.addRejected", context: ["reason": "atCap"])
            return
        }
        store.addPersonalCareTask(label: label, group: newCareTaskGroup)
        newCareTaskName = ""
    }

    private var personalCareSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel("Personal care tasks")
            newCareTaskEditor
            ForEach(PersonalCareTask.groupCases) { group in
                careTaskGroupList(group)
            }
        }
    }

    /// The group the next task joins, as a case over the stored token (`newCareTaskGroup`).
    private var newCareTaskGroupBinding: Binding<CareGroup> {
        Binding(get: { CareGroup(rawValue: newCareTaskGroup) ?? .anytime },
                set: { newCareTaskGroup = $0.token })
    }

    /// The add-a-task composer (`b2-settings-care`): the label field (length-capped), Morning /
    /// Anytime / Evening as the framed segmented control, the full-width Add button, and the
    /// at-capacity note, on one framed card.
    private var newCareTaskEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Moisturizer, meds, stretch...", text: $newCareTaskName,
                      prompt: .fieldPrompt("Moisturizer, meds, stretch..."))
                .sheetTextInput()
                // R3: cap the free-text label where it enters. The persisted settings array is
                // synced, so an unbounded label is unbounded growth in the snapshot.
                .onChange(of: newCareTaskName) { _, newValue in
                    if newValue.count > Self.maxCareTaskLabelLength {
                        newCareTaskName = String(newValue.prefix(Self.maxCareTaskLabelLength))
                    }
                }
            // The segment SHOWS `group.label` but STORES `group.token`. Showing and storing the
            // same string is precisely the bug `CareGroup` exists to prevent: the stored value is
            // the filter predicate and rides the synced settings blob. The control ticks on a change.
            FernletSegmentedPicker("Time of day", selection: newCareTaskGroupBinding,
                                   options: PersonalCareTask.groupCases) { Text(verbatim: $0.label) }
            Button {
                addPersonalCareTask()
            } label: {
                Label("Add task", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(ActionPillButtonStyle(.primary))
            .disabled(isAddCareTaskDisabled)
            if store.personalCareTasks.count >= Self.maxCustomCareTasks {
                Text("That's the most personal care tasks Fernlet keeps (\(Self.maxCustomCareTasks)). Remove one to add another.")
                    .font(FernletFramedFont.note)
                    .foregroundStyle(framedLook?.dim ?? Color.slate)
                    .fernletWrappingText()
                    .accessibilityIdentifier("settings.care.limitReached")
            }
        }
        .settingsCard()
    }

    /// One group's saved tasks as framed rows under the group's label: the task's pixel icon in a
    /// framed tile, its name, and a framed terracotta minus that asks before removing it. Renders
    /// nothing for an empty group.
    @ViewBuilder
    private func careTaskGroupList(_ group: CareGroup) -> some View {
        let tasks = store.personalCareTasks.filter { $0.careGroup == group }
        if !tasks.isEmpty {
            FernletFramedSection(header: Text(verbatim: group.label)) {
                ForEach(tasks) { task in
                    careTaskRow(task)
                }
            }
        }
    }

    /// One saved task's row.
    private func careTaskRow(_ task: PersonalCareTask) -> some View {
        HStack(spacing: 12) {
            FernletIconTile(size: 34) {
                WorldSpriteView(sprite: CareTaskSprite.sprite(forSystemImage: task.systemImage), scale: 2)
            }
            // `displayLabel`: the stored `label` is the frozen English a built-in task was first
            // written with.
            FernletRowLabel(title: Text(task.displayLabel))
            Button { confirmRemoveCareTask(task) } label: {
                RemoveMinusTile()
            }
            .buttonStyle(.plain)
            .fernletIconButton("Remove \(task.displayLabel)")
        }
        .padding(.vertical, 8)
    }

    private var debugCard: some View {
        FernletCard {
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel("Debug")
                // One storage line, derived: the card used to state "Storage: local JSON database"
                // above a File: line reading "Core Data + iCloud", contradicting itself.
                Text("Storage: \(store.storageLocation)")
                Text("Today key: \(store.todayKey)")
            }
            .font(.fernlet(.labelSmall))
            .foregroundStyle(Color.slate)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var debugTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Prototype only — not production-private. Debug surfaces for local inspection during development.")
                .font(.fernlet(.body))
                .foregroundStyle(Color.terracotta)
                .fernletWrappingText()

            proximityDebugSection

            debugCard

            tierTwoMemorySection

            derivedSignalsSection

            #if DEBUG
            cryptoFormatCensusSection

            phase3GateReadoutLink
            #endif
        }
    }

    /// The Album tab's debug switch (the Friends tab before `b4-mem-name`) and what turning it on
    /// actually exposes.
    private var proximityDebugSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Album tab")
            Toggle(
                "Proximity debug tools",
                isOn: Binding(
                    get: { store.settings.showProximityDebugTools },
                    set: { store.setShowProximityDebugTools($0) }
                )
            )
            Text("Shows the connection inspector button and a Force override on Album › Friends nearby that bypasses distance requirements.")
                .font(.fernlet(.bodySmall))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()
        }
    }

    /// The tier-2 memory inspector. Loads post-render via its own `.task`: the read is disk I/O on the
    /// device-local Tier-2 sidecar, which has no place in a NavigationStack push's first body pass.
    private var tierTwoMemorySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Tier 2 memory (test-only view)")
            Text("Tier 2 memories are inferred context records. In production these will not be readable. This view exists for prototype inspection only.")
                .font(.fernlet(.bodySmall))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()

            // Until the load lands, say so — the previous three-branch form rendered neither the
            // list nor the empty state on the initial push, which reads as a broken page rather
            // than a deliberate on-demand load.
            if debugTierTwoMemories == nil {
                FernletCard { EmptyState(text: "Loading tier 2 memories…") }
            } else if let tier2 = debugTierTwoMemories, tier2.isEmpty {
                FernletCard { EmptyState(text: "No tier 2 memories yet. They are extracted from journals when Foundation Models are available.") }
            } else if let tier2 = debugTierTwoMemories {
                ForEach(tier2) { record in
                    tierTwoMemoryRow(record)
                }
            }
        }
        // The load the comment above describes. Runs once per push, after the first frame, so
        // the disk read never blocks the navigation animation.
        .task {
            guard debugTierTwoMemories == nil else { return }
            debugTierTwoMemories = store.tierTwoMemories
        }
    }

    private func tierTwoMemoryRow(_ record: TierTwoMemoryRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                // `uppercased()` — the ROOT-locale mapping — and deliberately NOT
                // `.textCase(.uppercase)`, which uppercases in the USER's locale. This string is a
                // Tier-2 memory CATEGORY: a frozen English classifier token persisted on the
                // record, not display copy, and there is no catalog entry for the transform to run
                // after. Locale-driven casing on frozen English is how "side item" becomes
                // "SİDE İTEM" for a Turkish user (review A4 follow-up F5). Localizing the category
                // itself is a token/display fork, and it belongs to the deferred class listed in
                // `Tests/FernletTests/LocalizationBoundaryTests.swift`'s header ("UNCATALOGUED
                // DISPLAY COPY") — not a casing change.
                Text(verbatim: record.category.uppercased())
                    .font(.fernlet(.labelSmall))
                    .foregroundStyle(Color.slate)
                Spacer()
                Text(record.extractedDate.formatted(.dateTime.month(.abbreviated).day().year()))
                    .font(.fernlet(.labelSmall))
                    .foregroundStyle(Color.slate)
            }
            Text(record.text)
                .font(.fernlet(.body))
                .foregroundStyle(Color.bark)
                .fernletWrappingText()
            if !record.active {
                Text("Inactive")
                    .font(.fernlet(.labelSmall))
                    .foregroundStyle(Color.terracotta)
            }
        }
        .padding(14)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))
    }

    /// The computed derived signals, read straight from the store.
    private var derivedSignalsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Derived signals (test-only view)")
            let signals = store.derivedSignals
            if signals.isEmpty {
                FernletCard { EmptyState(text: "No signals computed yet. More logs will make trends useful.") }
            } else {
                ForEach(signals) { signal in
                    derivedSignalRow(signal)
                }
            }
        }
    }

    private func derivedSignalRow(_ signal: DerivedSignalRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                // The display name, never `signalName`: that is a frozen logic token ("moodTrend")
                // six gates compare, and it used to be drawn here raw.
                Text(verbatim: SignalPresentation.title(for: signal.signalName))
                    .font(.fernlet(.labelSmall))
                    .foregroundStyle(Color.slate)
                Spacer()
                Text(SignalPresentation.valueLabel(for: signal.value, addressing: termOfAddress))
                    .font(.fernlet(.labelSmall))
                    .foregroundStyle(SignalPresentation.color(for: signal.value))
            }
            Text("Window: \(signal.windowStart) → \(signal.windowEnd)")
                .font(.fernlet(.labelSmall))
                .foregroundStyle(Color.slate)
        }
        .padding(12)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
    }

    #if DEBUG
    /// The Phase-0 cryptographic format census (Docs/Plan-Crypto-Standardization-2026-08-27.md):
    /// how many stored blobs on this device are still in a legacy at-rest format, per surface.
    ///
    /// Loads post-render via its own `.task`, exactly like ``tierTwoMemorySection`` and for a
    /// heavier version of the same reason: the pass reads the sealed Core Data store, both media
    /// roots, a keychain row and five sidecar files. ``CryptoFormatCensus/run(inputs:)`` does all of
    /// that on a detached utility task; this view only renders what comes back.
    ///
    /// The `.task` re-entry guard is two-part, and the second half is the one that matters. Once a
    /// report is in hand `cryptoFormatCensus != nil` short-circuits every later push; WHILE a scan
    /// is running there is no report yet, so `cryptoFormatCensusTask` stands in for it and a
    /// re-push awaits the scan already underway instead of launching another. SwiftUI cancels this
    /// `.task` on disappear, but the detached scan inside does not observe cancellation — without
    /// the handle, a push → pop → push would leave two full sweeps racing to assign the same state.
    private var cryptoFormatCensusSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Crypto format census (test-only view)")
            Text("Counts stored blobs by their format MARKER BYTES only — nothing is decrypted, and nothing is written or saved. One row per cryptographic surface; a surface that cannot be counted shows a dash and says why, never a zero.")
                .font(.fernlet(.bodySmall))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()
            Text("That promise is unchanged, and it is why three of the six Phase 3 gates cannot be answered here. Those are answered next door, in the Phase 3 gate readout, at a stated cost.")
                .font(.fernlet(.bodySmall))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()

            if let report = cryptoFormatCensus {
                ForEach(report.rows) { row in
                    cryptoFormatCensusRow(row)
                }
                cryptoFormatCensusCopyButton(report)
            } else {
                FernletCard { EmptyState(text: "Counting every sealed surface…") }
            }
        }
        // One pass per SHEET, after the first frame — see the comment above.
        .task {
            guard cryptoFormatCensus == nil else { return }
            let scan: Task<Void, Never>
            if let inFlight = cryptoFormatCensusTask {
                scan = inFlight  // a re-push during the first scan: wait on it, never start a second
            } else {
                scan = Task {
                    cryptoFormatCensus = await CryptoFormatCensus.run(inputs: .production(for: store))
                }
                cryptoFormatCensusTask = scan
            }
            await scan.value
        }
    }

    /// One census row: the surface, its legacy count (or a dash), the per-bucket detail, and the
    /// caveat that says what the number is worth. The dash and the terracotta caveat are the whole
    /// point — an unavailable count must never render as "0 legacy blobs".
    private func cryptoFormatCensusRow(_ row: CryptoFormatCensusRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.displayName)
                    .font(.fernlet(.labelSmall))
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()
                Spacer()
                Text("legacy \(row.legacyCountText)")
                    .font(.fernlet(.label))
                    .foregroundStyle(row.hasCount ? Color.bark : Color.terracotta)
            }
            Text(row.detail)
                .font(.fernlet(.labelSmall))
                .foregroundStyle(Color.bark)
                .fernletWrappingText()
            if let caveat = row.caveat {
                Text(caveat)
                    .font(.fernlet(.labelSmall))
                    .foregroundStyle(Color.terracotta)
                    .fernletWrappingText()
            }
        }
        .padding(14)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))
    }

    /// Copies the census reading. It had none, so every reading was hand-transcribed or
    /// screenshotted; the readout next door has one, and the pair should be symmetric.
    ///
    /// `setItems(_:options:)` with `.localOnly: true` is the required spelling (PB1): the general
    /// pasteboard is Handoff-synced to every device on the same Apple Account.
    private func cryptoFormatCensusCopyButton(_ report: CryptoFormatCensusReport) -> some View {
        Button {
            FernletAuditLog.log("debug.cryptoFormatCensus.copied")
            let text = report.rows
                .map { "\($0.displayName): legacy \($0.legacyCountText) — \($0.detail)\($0.caveat.map { " [\($0)]" } ?? "")" }
                .joined(separator: "\n")
            UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: text]],
                                          options: [.localOnly: true])
        } label: {
            Label("Copy the census reading", systemImage: "doc.on.doc")
        }
        .accessibilityIdentifier("settings.cryptoFormatCensus.copy")
    }

    /// The Phase 3 gate readout — a sibling of the census, not a section inside it.
    ///
    /// A pushed destination for three reasons: `debugTab`'s body stays trivially small, the new
    /// surface gets its own toolbar, and "sibling to, not folded into" becomes literal in the code
    /// as well as in the copy. No `SettingsRoute` case is added, so `SettingsSearchIndex` is
    /// untouched — this is a DEBUG surface and does not belong in a searchable settings index.
    private var phase3GateReadoutLink: some View {
        NavigationLink {
            Phase3GateReadoutView(store: store, scanTask: $phase3ScanTask)
                .fernletPushedPage("Phase 3 gate readout")
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel("Phase 3 gate readout (test-only view)")
                Text("The census above counts marker bytes and writes nothing. This one also reads completion latches, can fetch and decrypt three iCloud manifests on request, can run a media at-rest conversion pass, and can clear one latch to arm a keyed pass on the next hub unlock.")
                    .font(.fernlet(.labelSmall))
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))
        }
        .accessibilityIdentifier("settings.row.phase3GateReadout")
    }
    #endif

    private var connectionInspectorTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Connection Inspector captures proximity pairing diagnostics for local troubleshooting.")
                .font(.fernlet(.body))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()

            VStack(alignment: .leading, spacing: 12) {
                SectionLabel("Mode")
                Picker("Connection Inspector", selection: connectionInspectorModeBinding) {
                    ForEach(ConnectionInspectorMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Text(connectionInspectorModeDescription)
                    .font(.fernlet(.bodySmall))
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()
            }
            .padding(14)
            .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))

            NavigationLink {
                ConnectionInspectorHistoryView(inspector: store.connectionInspector)
            } label: {
                HStack {
                    Label("Connection History", systemImage: "clock.arrow.circlepath")
                    Spacer()
                    Text("\(store.connectionInspector.historicalLogs.count)")
                        .font(.fernlet(.stat))
                        .foregroundStyle(Color.slate)
                }
                .font(.fernlet(.label))
                .foregroundStyle(Color.bark)
                .padding(14)
                .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)

            #if DEBUG
            // SETT-28 folded the old Debug hub row into this page: the development inspection
            // surface stays reachable in DEBUG builds only, one level down from Connection log.
            FernletFramedSection(header: nil) {
                settingsLinkRow("Developer tools", route: .debug)
            }
            #endif
        }
    }

    /// The line under the mode picker. `LocalizedStringKey`: as a `String` the three sentences took
    /// `Text`'s verbatim initializer and never reached the catalog.
    private var connectionInspectorModeDescription: LocalizedStringKey {
        switch store.settings.connectionInspectorMode {
        case .disabled:
            return "No overlay and no saved history."
        case .passive:
            return "Records session history without showing the live overlay."
        case .live:
            return "Records session history and shows the live inspector when you open it manually."
        }
    }

    /// "Delete everything", not "Reset everything": the old label promised a scope `resetAll()` never
    /// delivered — it left every logged day on disk to reload on the next launch — and the old two-tap
    /// reveal named no data and stated no consequences. Both entry points now present the shared
    /// typed-gate ``DeleteEverythingSheet`` over the single `deleteAllData` funnel.
    private var resetSection: some View {
        // The same terracotta text + trash row App lock's danger zone uses, rather than a third
        // destructive style (system red here, terracotta there, a filled button in Privacy & Data).
        Button(role: .destructive) {
            showDeleteEverything = true
        } label: {
            // The framed danger row (`.sr.danger`): the name in terracotta, semibold, no chevron;
            // the row style makes the whole row the tap target.
            FernletRowLabel("Delete everything", destructive: true)
        }
        .buttonStyle(FernletRowButtonStyle(showsChevron: false))
        .disabled(deleteFlow.isDeleting)
        .accessibilityIdentifier("settings.deleteAll")
    }

    /// Raises the shared destructive confirmation for one core memory. Nothing is removed until the
    /// user confirms — the mutation lives only inside `perform`.
    private func confirmDeleteMemory(_ memory: MemoryNote) {
        pendingDestructiveAction = DestructiveConfirmation(
            title: "Delete this memory?",
            message: "\"\(memory.displayText)\"\n\nFernlet forgets it for good. Your journal entry stays.",
            confirmLabel: "Delete",
            auditEvent: "settings.memory.deleteConfirmed"
        ) {
            store.deleteMemory(memory)
        }
    }

    private func groupedMemories(for memories: [MemoryNote]) -> [String: [MemoryNote]] {
        Dictionary(grouping: memories) { $0.category.uppercased() }
    }

    private func groupedMemoryKeys(for memories: [MemoryNote]) -> [String] {
        groupedMemories(for: memories).keys.sorted()
    }

    /// One memory as a framed row (`b2-settings-memory`): its sentence and date, then Edit and Delete
    /// as 32-pt framed pixel-icon buttons.
    private func memoryRow(_ memory: MemoryNote) -> some View {
        HStack(alignment: .center, spacing: 8) {
            // `displayText`: an emotion-only journal memory stores its feeling as a token and no
            // words, so its sentence is built here at render time (MemoryNoteDisplay.swift).
            FernletRowLabel(title: Text(memory.displayText),
                            detail: Text(memory.sourceDate.formatted(.dateTime.month(.abbreviated).day().year())))
                .padding(.vertical, 10)
            Button { editingMemory = memory } label: {
                FernletIconTile(size: 32, isControl: true) { WorldSpriteView(sprite: WorldSprites.pen, scale: 2) }
            }
            .buttonStyle(.plain)
            .fernletIconButton("Edit memory")
            // A memory is saved user data, so removing it is confirmed like every other delete —
            // it used to vanish on one tap with no undo.
            Button { confirmDeleteMemory(memory) } label: {
                FernletIconTile(size: 32, isControl: true) { FernletIcon(.close, scale: 2) }
            }
            .buttonStyle(.plain)
            .fernletIconButton("Delete memory")
        }
    }
}

/// Sheet for editing a single core memory: its category, its text (capped at 240 characters), and a
/// two-step inline delete.
///
/// Presented by ``SettingsSheet``'s Core memory tab via `.sheet(item:)`. The source date is shown
/// read-only; Save routes through `FernletStore.updateMemory` and Delete through
/// `FernletStore.deleteMemory`, so the sheet itself persists nothing.
private struct MemoryEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    /// The user's term of address, which a feeling category's chip agrees with.
    @Environment(\.fernletTermOfAddress) private var termOfAddress
    @Bindable var store: FernletStore
    let memory: MemoryNote
    @State private var category: String
    @State private var text: String
    @State private var confirmDelete = false

    init(store: FernletStore, memory: MemoryNote) {
        self.store = store
        self.memory = memory
        _category = State(initialValue: memory.category)
        _text = State(initialValue: memory.text)
    }

    /// Category chips, the memory editor, its counter, the source date, and the delete affordance.
    private var editorScrollContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Chips, not free text: the list groups memories by category, and a free
            // TextField let one memory land in a category of its own by a typo.
            SheetField("Category") {
                FlowLayout(spacing: 8) {
                    ForEach(categoryChoices, id: \.self) { choice in
                        // The chip SHOWS a name but STORES the token: `choice` is what the list
                        // groups by, so only the drawn half goes through `MemoryCategoryName`. A stored
                        // "Food" already draws the "food" chip as chosen: re-tapping it takes the token
                        // without a tick, because nothing on screen changed.
                        Button {
                            if category.lowercased() == choice {
                                category = choice
                            } else {
                                FernletFeedback.system.select(choice, in: &category)
                            }
                        } label: {
                            Text(verbatim: MemoryCategoryName.chipLabel(for: choice, addressing: termOfAddress))
                        }
                        .buttonStyle(ChipButtonStyle(selected: category.lowercased() == choice))
                    }
                }
            }

            SheetField("Memory") {
                SheetTextEditor(text: $text, placeholder: "What should Fernlet remember?", minHeight: 150)
            }

            Text("\(text.count)/240")
                .font(.fernlet(.stat))
                .foregroundStyle(Color.slate)
                .frame(maxWidth: .infinity, alignment: .trailing)

            // The source date as a key-value row under a dotted rule (`.kv`, `b3-memory-editor`).
            FernletKeyValueRow("Source date", value: Text(memory.sourceDate.formatted(.dateTime.month(.wide).day().year())))

            deleteSection
                .frame(maxWidth: .infinity)
        }
        .padding(20)
        .padding(.bottom, 10)
    }

    /// Delete, with its inline two-step confirmation.
    @ViewBuilder
    private var deleteSection: some View {
        if confirmDelete {
            VStack(alignment: .leading, spacing: 10) {
                Text("Delete this memory?")
                    .font(.fernlet(.header))
                    .foregroundStyle(Color.bark)
                HStack(spacing: 16) {
                    Button("Delete", role: .destructive) {
                        store.deleteMemory(memory)
                        dismiss()
                    }
                    .foregroundStyle(Color.terracottaInk)
                    Button("Cancel") { confirmDelete = false }
                        .foregroundStyle(Color.slate)
                }
                .font(.fernlet(.label))
                .frame(minHeight: 44)
            }
        } else {
            Button("Delete memory", role: .destructive) { confirmDelete = true }
                .font(.fernlet(.label))
                .foregroundStyle(Color.terracottaInk)
                .frame(minHeight: 44)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                editorScrollContent
            }
            .onChange(of: text) { _, newValue in
                if newValue.count > 240 { text = String(newValue.prefix(240)) }
            }

            SheetSaveBar(disabled: text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                store.updateMemory(memory, category: category, text: text)
                dismiss()
            }
        }
        .fernletSheetStyle()
        // The drag handle was the only way out — every sibling entry sheet offers a Cancel, and a
        // dirty draft now asks before it is thrown away. The guard's header puts the title inside
        // the sheet, under Cancel (`b1-frame-sheet`).
        .fernletDraftGuard(isDirty: category != memory.category || text != memory.text,
                           title: Text("Core memory")) { dismiss() }
    }

    /// The categories already in use, plus "other" as the escape hatch, lower-cased for storage and
    /// title-cased only for display.
    private var categoryChoices: [String] {
        var seen = Set<String>()
        var choices: [String] = []
        for candidate in store.memories.map(\.category) + [category, "other"] {
            let normalized = candidate.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { continue }
            choices.append(normalized)
        }
        return choices.sorted()
    }
}

// MARK: - Components

// MARK: - App Lock settings view

/// The App lock settings page: lock status, passcode change, manual lock, the biometric toggle, and
/// the reset-lock danger zone.
///
/// Pushed from ``SettingsSheet`` via `SettingsRoute.appLock` (wrapped in `fernletLockGate` when a
/// passcode is configured, so reaching this page requires an unlock). All state lives in the
/// environment's `FernletLockService`. With no passcode the status reads "No passcode" / "Private
/// opens with a tap." and the page offers setting one up (`FernletLockSetupView`, which asks for a
/// fresh Face ID / iPhone-passcode check before a passcode takes over existing entries). With one,
/// **Turn off passcode** confirms what goes with it (Face ID unlock, the duress code, any recovery
/// device), takes the current passcode on the shared verify sheet, and calls
/// `FernletLockService.removeCredential(current:)`: the key moves back to device custody and
/// nothing is deleted (period-data design 2026-09-30, §10.3). Enabling biometrics requires
/// re-entering the current passcode (the same verify sheet); disabling does not. Resetting the lock
/// is confirmed with an explicit warning that the entries saved in Fernlet are deleted — the reset
/// destroys the keys, not just the passcode.
///
/// It also hosts the duress entry points (security-hardening Phase 7): ``DuressPINSetupView`` for
/// setting the duress code and choosing its response, and the two halves of the in-person recovery
/// ceremony. Those live here rather than on a page of their own precisely because this page is
/// already `.appLockSettings`-gated — reaching it proves the REAL passcode, which is what makes
/// `configureDuress` and `enrollRecoveryCustodian` real-PIN-gated by construction instead of by a
/// re-prompt.
struct AppLockSettingsView: View {
    @Environment(FernletLockService.self) private var lockService
    @Environment(\.dismiss) private var dismiss
    /// The World's framed look (`b2-settings-applock`): framed cards and rows on the dotted page.
    @Environment(\.fernletFramedLook) private var look

    @State private var showSetup = false
    @State private var showChangePasscode = false
    @State private var showResetConfirm = false
    /// Presents the nothing-silent alert when the reset destroyed the keys and the rows but could
    /// not rebuild the sealed store file (it used to be swallowed by a `try?`).
    @State private var showResetRebuildFailure = false
    /// Presents the shared passcode-verify sheet — for a biometric toggle, or for Turn off passcode
    /// (``verifyTurnsOffPasscode``). One sheet, one PIN pad, so the page's audited pad shape is
    /// unchanged (`LockGateAccessibilityBoundaryTests`).
    @State private var showPasscodeVerify = false
    /// Whether the verify sheet is confirming Turn off passcode rather than a biometric toggle.
    @State private var verifyTurnsOffPasscode = false
    /// Presents the Turn off passcode confirmation (design §10.3).
    @State private var showTurnOffConfirm = false
    @State private var verifyCurrentPasscode = ""
    @State private var verifyError: String?
    /// Shown on the biometric card when turning biometrics OFF failed. Disabling needs no passcode,
    /// so there is no verify sheet to carry the message — without this the toggle would just snap
    /// back silently.
    @State private var biometricDisableError: String?
    @State private var pendingBiometricEnable = false
    /// Duress-code setup (security-hardening Phase 7, step 9).
    @State private var showDuressSetup = false
    /// The custodian half of the recovery ceremony, offered whether or not THIS phone has a lock.
    @State private var showRecoveryCustodian = false
    /// The return ceremony, offered only on a phone left in the post-`recoveryLock` state.
    @State private var showRecoveryReturn = false

    var body: some View {
        resetPresentations(
            cardsColumn
                .scrollContentBackground(.hidden)
                .fernletPageBackground()
                // The plate carries the title and Back (`b1-frame-push`).
                .fernletPushedPage("App lock")
                .sheet(isPresented: $showSetup) {
                    FernletLockSetupView(grantingScope: .appLockSettings)
                        .environment(lockService)
                }
                .sheet(isPresented: $showChangePasscode) {
                    FernletLockChangePasscodeView()
                        .environment(lockService)
                }
                .sheet(isPresented: $showPasscodeVerify) {
                    passcodeVerifySheet
                }
                .sheet(isPresented: $showDuressSetup) {
                    DuressPINSetupView()
                        .environment(lockService)
                }
                .sheet(isPresented: $showRecoveryCustodian) {
                    // The row says "Be a recovery device", so the sheet opens on that role instead
                    // of asking "which phone is this?" with the opposite answer as its primary.
                    DuressRecoveryEnrollmentSheet(initialRole: .recoveryDevice)
                        .environment(lockService)
                }
                .sheet(isPresented: $showRecoveryReturn) {
                    DuressRecoveryReturnSheet()
                        .environment(lockService)
                }
        )
    }

    /// The page itself: status, then either the manage/biometric/duress/danger cards or the setup CTA.
    private var cardsColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                statusCard

                if lockService.isLockConfigured {
                    actionsCard
                    biometricCard
                    duressCard
                    dangerCard
                } else {
                    setupCTACard
                    duressCard
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 30)
        }
    }

    /// The reset ceremony: its confirmation dialog and the nothing-silent alert for the one failure
    /// the reset can leave behind (keys and rows destroyed, sealed store file not rebuilt).
    private func resetPresentations(_ content: some View) -> some View {
        content
            // An alert, deliberately: on iOS 26 a `.confirmationDialog` renders as a popover that
            // SUPPRESSES the `.cancel`-role button, so this — which makes sealed notes permanently
            // unreadable — showed a lone red "Reset app lock" and no visible way out.
            .alert(
                "Reset app lock?",
                isPresented: $showResetConfirm
            ) {
                Button("Cancel", role: .cancel) { }
                Button("Reset app lock", role: .destructive) { resetAppLock() }
            } message: {
                Text(Self.resetMessage)
            }
            .alert("App lock reset", isPresented: $showResetRebuildFailure) {
                Button("OK", role: .cancel) { dismiss() }
            } message: {
                Text("Your app lock and its notes were destroyed, but the sealed store could not be rebuilt. Please relaunch Fernlet.")
            }
            // Not destructive-red: turning the passcode off deletes nothing (design §10.3).
            .alert("Turn off the passcode?", isPresented: $showTurnOffConfirm) {
                Button("Cancel", role: .cancel) { }
                Button("Turn off passcode") {
                    verifyTurnsOffPasscode = true
                    showPasscodeVerify = true
                }
            } message: {
                Text("Private will open with a tap instead. Your entries stay encrypted on this iPhone and nothing is deleted. \(biometricName(lockService.biometricType)) unlock, your duress code and any recovery device are removed.",
                     comment: "Message of the confirmation before the app passcode is turned off. The placeholder is Face ID or Touch ID (an Apple product name). Nothing is deleted: the entries stay encrypted on this iPhone, and the Private tab opens with a tap afterwards.")
            }
    }

    /// The Reset app lock confirmation's message: the same words as the gate's confirmation
    /// (`lock.reset.confirm.message.v2` in FernletLockUI): the loss is the whole cycle history saved in
    /// Fernlet now, not "notes" beside a Health copy (period-data design 2026-09-30, §10.5), and the Sealed
    /// backup restores afterwards from Privacy & Data's owner-checked "Restore". Then, on its own line,
    /// that Where you've been goes too (World build round 5: the owner allowed a reset to clear it only if
    /// this screen says so plainly; its log is sealed under the hub key the reset replaces).
    private static var resetMessage: String {
        String(localized: "settings.appLock.reset.message.v2",
               defaultValue: "Your journal, cycle history and intimacy entries saved in Fernlet will be permanently deleted. Anything Fernlet copied to Apple Health stays there. If Sealed backup is on, restore it from Privacy & Data afterwards, before you add new entries.",
               comment: "Message in the Reset app lock confirmation in Settings. Keep it identical to the lock screen's own reset confirmation. The journal and intimacy backups restore only into an empty store, so the sentence tells the user to restore before adding new entries.")
            + "\n\n"
            + String(localized: "settings.appLock.reset.whereYouveBeen", defaultValue: "This also deletes the places you've been.",
                     comment: "Last line of the Reset app lock confirmation in Settings: the reset also deletes the 30-day timeline of places kept in Private (its Where you've been page), for good. Owner-approved wording, 2026-10-25. Keep it identical to the lock screen's.")
    }

    /// Destroys the lock and its keys, dismissing only if the sealed store was rebuilt.
    private func resetAppLock() {
        do {
            try lockService.reset()
            dismiss()
        } catch {
            // Keys and rows are gone either way; the store FILE could not be re-created.
            // Stay on this screen and say so rather than dismissing on a promise the app
            // did not keep.
            print("[Fernlet] App-lock reset could not rebuild the sealed store: \(error)")
            FernletAuditLog.log("lock.reset.rebuild.failed")
            showResetRebuildFailure = true
        }
    }

    // MARK: Cards

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Status")
            HStack(spacing: 12) {
                // The status as a framed square (`b2-settings-applock`); its word says the state.
                Rectangle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
                    .padding(2)
                    .background(look?.ink ?? Color.clear)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(statusLabel)
                        .font(FernletFramedFont.cardTitle)
                        .foregroundStyle(look?.text ?? Color.bark)
                    if lockService.isLockConfigured, let kind = lockService.credentialKind {
                        Text(kindLabel(kind))
                            .font(FernletFramedFont.rowDetail)
                            .foregroundStyle(look?.dim ?? Color.slate)
                    } else if !lockService.isLockConfigured {
                        Text("Private opens with a tap.",
                             comment: "Subtitle under 'No passcode' on the App lock settings page: with no app passcode, the Private tab opens with one tap on its Unlock button.")
                            .font(FernletFramedFont.rowDetail)
                            .foregroundStyle(look?.dim ?? Color.slate)
                            .fernletWrappingText()
                    }
                }
                Spacer()
            }
        }
        .settingsCard()
    }

    // Moved here from Privacy & Data, where it sat under an "App lock data" header above the
    // Delete everything button and described neither. The note under Manage.
    private var actionsCard: some View {
        FernletFramedSection(header: Text("Manage"),
                             footer: Text("Fernlet protects your data with its own passcode, separate from your device passcode. Removing your device passcode won't affect your Fernlet app lock or erase your protected data.")) {
            Button {
                showChangePasscode = true
            } label: {
                settingsRow("Change passcode")
            }
            .buttonStyle(FernletRowButtonStyle())

            // No chevron: this acts here and now, it doesn't navigate anywhere.
            Button {
                lockService.lock(reason: .manual)
            } label: {
                settingsRow("Lock now")
            }
            .buttonStyle(FernletRowButtonStyle(showsChevron: false))

            // Confirmed first, then the current passcode on the shared verify sheet (design §10.3).
            Button {
                showTurnOffConfirm = true
            } label: {
                settingsRow("Turn off passcode")
            }
            .buttonStyle(FernletRowButtonStyle())
            .accessibilityIdentifier("appLock.turnOffPasscode")
        }
    }

    private var biometricCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            // `verbatim:` on the merits as well as for the type: "Face ID" and "Touch ID" are
            // Apple product names that Apple itself ships untranslated in most locales.
            FernletFramedSection(header: Text(verbatim: biometricName(lockService.biometricType))) {
                if lockService.biometricType != .none {
                    Toggle(isOn: biometricToggleBinding) {
                        settingsRow("Use \(biometricName(lockService.biometricType))")
                    }
                } else {
                    Text("No biometric authentication available on this device.")
                        .font(FernletFramedFont.rowTitle)
                        .foregroundStyle(look?.dim ?? Color.slate)
                        .fernletWrappingText()
                        .padding(.vertical, 12)
                }
            }
            // The toggle re-reads `lockService.biometricEnabled`, so a failed disable would
            // otherwise just snap the switch back with no explanation.
            if let biometricDisableError {
                FernletNotice(text: Text(biometricDisableError), tone: .warn) { EmptyView() }
                    .accessibilityIdentifier("applock.biometric.disableError")
            }
        }
    }

    /// Duress code + recovery device (security-hardening Phase 7).
    ///
    /// Three rows with three different availability rules, deliberately:
    /// - **Duress code** needs a configured lock, because a duress code is an alternative way to
    ///   enter one.
    /// - **Be a recovery device** is offered ALWAYS, including on a phone with no app lock of its
    ///   own. Acting as somebody else's recovery device uses only the proximity identity keys, and
    ///   requiring a lock here would mean a user's spare phone could not be their recovery device.
    ///   It discloses nothing about THIS phone: the row reads the same whether or not a duress code
    ///   is configured, which is the property the whole feature depends on.
    /// - **Recover this phone** appears whenever a custodian is enrolled — deliberately WIDER than
    ///   `isAwaitingCustodianRecovery`. A phone left by `DuressMode.recoveryLock` shows "set up app
    ///   lock", and a user who takes that offer before reaching their custodian leaves that state
    ///   (`isAwaitingCustodianRecovery` reads the ABSENCE of a verifier) while the recovery material
    ///   survives. Gating on the narrow state would make the route back unreachable at exactly that
    ///   moment. On a phone that never fired a duress response the row is harmless: the ceremony
    ///   re-installs the same content key under a new passcode, and it sits behind the
    ///   `.appLockSettings` gate either way.
    ///
    /// **The whole section fails closed during a duress session.** `FernletLockService.handleDuress`
    /// refuses to grant `.appLockSettings` to a duress PIN, so a decoy should never be looking at
    /// this card — but this is the screen that would otherwise let whoever is holding the phone read
    /// that a duress code exists, change it, remove it, enrol a recovery device of their own
    /// choosing, or reset the lock. It renders what a phone with no app lock and no custodian
    /// renders instead, which is also what an un-configured device shows, so hiding it discloses
    /// nothing on its own.
    private var duressCard: some View {
        FernletFramedSection("Duress & recovery") {
            if lockService.isLockConfigured && !lockService.isDuressSessionActive {
                Button {
                    showDuressSetup = true
                } label: {
                    settingsRow("Duress code")
                }
                .buttonStyle(FernletRowButtonStyle())
                .accessibilityIdentifier("appLock.duressCode")
            }

            if lockService.hasRecoveryCustodian && !lockService.isDuressSessionActive {
                Button {
                    showRecoveryReturn = true
                } label: {
                    settingsRow("Recover this phone")
                }
                .buttonStyle(FernletRowButtonStyle())
                .accessibilityIdentifier("appLock.recoverThisPhone")
            }

            Button {
                showRecoveryCustodian = true
            } label: {
                settingsRow("Be a recovery device")
            }
            .buttonStyle(FernletRowButtonStyle())
            .accessibilityIdentifier("appLock.beRecoveryDevice")
        }
    }

    private var dangerCard: some View {
        FernletFramedSection("Danger zone") {
            Button(role: .destructive) {
                showResetConfirm = true
            } label: {
                settingsRow("Reset app lock", destructive: true)
            }
            .buttonStyle(FernletRowButtonStyle(showsChevron: false))
        }
    }

    /// No passcode yet: what Private does now, and the full-width framed Set up app lock with the
    /// pixel lock (`b2-settings-applock`).
    private var setupCTACard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Private opens with a tap while no passcode is set. Add a passcode to be asked for it before Private opens.",
                 comment: "The App lock settings page with no app passcode: what the Private tab does now, and what adding a passcode changes. Must not call the no-passcode state locked, protected or secured.")
                .font(FernletFramedFont.body)
                .foregroundStyle(look?.dim ?? Color.slate)
                .fernletWrappingText()

            Button { showSetup = true } label: {
                Label {
                    Text("Set up app lock")
                } icon: {
                    FernletIcon(.lock, scale: 2, tint: look?.onAccent ?? Color.onMoss)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(ActionPillButtonStyle(.primary))
        }
        .settingsCard()
    }

    // MARK: Passcode verify sheet

    /// The current-passcode prompt the verify sheet shows for its purpose.
    @ViewBuilder private var passcodeVerifyPrompt: some View {
        if verifyTurnsOffPasscode {
            Text("Enter your current passcode to turn it off.",
                 comment: "Prompt on the verify sheet shown after confirming Turn off passcode in App lock settings.")
        } else if pendingBiometricEnable {
            // Two whole sentences rather than an English "enable"/"disable" spliced into one.
            Text("Enter your current passcode to enable \(biometricName(lockService.biometricType)).",
                 comment: "Prompt on the verify sheet before biometric unlock is turned on. The placeholder is Face ID or Touch ID (an Apple product name).")
        } else {
            Text("Enter your current passcode to disable \(biometricName(lockService.biometricType)).",
                 comment: "Prompt on the verify sheet before biometric unlock is turned off. The placeholder is Face ID or Touch ID (an Apple product name).")
        }
    }

    /// The shared current-passcode sheet: a biometric toggle, or Turn off passcode.
    private var passcodeVerifySheet: some View {
        NavigationStack {
            ZStack {
                (look?.paper ?? Color.parchment).ignoresSafeArea()
                VStack(alignment: .leading, spacing: 20) {
                    passcodeVerifyPrompt
                        .font(.fernlet(.body))
                        .foregroundStyle(Color.slate)
                        .fernletWrappingText()

                    if let err = verifyError {
                        Text(err)
                            .font(.fernlet(.body))
                            .foregroundStyle(Color.terracotta)
                    }

                    if lockService.credentialKind == .alphanumeric {
                        SecureField("Current password", text: $verifyCurrentPasscode, prompt: .fieldPrompt("Current password"))
                            .textContentType(.password)
                            .sheetTextInput()

                        Spacer()

                        Button { commitPasscodeVerify() } label: {
                            Text("Confirm").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(ActionPillButtonStyle(.primary))
                        .disabled(verifyCurrentPasscode.isEmpty)
                    } else {
                        // The lock gate's shape: dots in the upper third, keypad anchored above the
                        // safe area where the thumb is. Stacked from the top it left the bottom
                        // half of the sheet empty and the digits up by the nav bar.
                        let total = lockService.credentialKind == .pin4 ? 4 : 6
                        pinDotsRow(current: verifyCurrentPasscode, total: total)
                            .frame(maxWidth: .infinity)

                        Spacer(minLength: 12)

                        // Submits from the tap that fills it (`onFilled`), never from an `onChange` on
                        // the entry, which a busy main thread can coalesce away and strand a full pad.
                        FernletNumericPad(value: $verifyCurrentPasscode, maxLength: total, onFilled: commitPasscodeVerify)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(24)
                // Hosts the shared PIN pad, whose tiles grow with Dynamic Type; without this the
                // bottom key row falls off the sheet at the accessibility sizes and in landscape.
                .fernletLockPadPage()
            }
            // Cancel top left and the title inside the sheet (`b3-passcode-verify`).
            .fernletSheetToolbar(title: "Verify passcode", onCancel: {
                showPasscodeVerify = false
                verifyTurnsOffPasscode = false
                verifyCurrentPasscode = ""
                verifyError = nil
            })
        }
        .tint(Color.moss)
        .fernletSheet()
    }

    /// Commits whatever the verify sheet is confirming. Turn off passcode calls
    /// `removeCredential(current:)`: a wrong passcode — and a duress code, which the service answers
    /// exactly like a mistype after running its response — reads as a mistype here.
    private func commitPasscodeVerify() {
        let turnsOffPasscode = verifyTurnsOffPasscode
        Task { @MainActor in
            do {
                if turnsOffPasscode {
                    try await lockService.removeCredential(current: verifyCurrentPasscode)
                } else {
                    try await lockService.setBiometricEnabled(pendingBiometricEnable, passcode: verifyCurrentPasscode)
                }
                showPasscodeVerify = false
                verifyTurnsOffPasscode = false
                verifyCurrentPasscode = ""
                verifyError = nil
            } catch {
                verifyCurrentPasscode = ""
                verifyError = error.localizedDescription
                // Same rule the unlock screen adopted in batch A1: a passcode that did not verify
                // clears the field and renders a line nothing focuses, so without this the only
                // signal is an empty field — indistinguishable from a mis-typed digit. Felt too (A6).
                FernletFeedback.system.play(.failed)
                FernletAnnouncer.system.announce(.error, resolved: error.localizedDescription)
            }
        }
    }

    // MARK: Helpers

    private var biometricToggleBinding: Binding<Bool> {
        Binding(
            get: { lockService.biometricEnabled },
            set: { newValue in
                if newValue == lockService.biometricEnabled { return }
                if newValue {
                    // Enabling requires passcode verification
                    pendingBiometricEnable = true
                    verifyTurnsOffPasscode = false
                    showPasscodeVerify = true
                } else {
                    // Disabling doesn't need verification
                    disableBiometrics()
                }
            }
        )
    }

    /// Turns biometrics off. No passcode is required to disable, but the failure is not silent: the
    /// toggle re-reads `lockService.biometricEnabled`, so a throw would leave it snapping back with
    /// no explanation unless the error is logged and shown.
    private func disableBiometrics() {
        Task { @MainActor in
            do {
                try await lockService.setBiometricEnabled(false, passcode: "")
                biometricDisableError = nil
            } catch {
                FernletAuditLog.log("lock.biometric.disableFailed")
                biometricDisableError = error.localizedDescription
                // The toggle springs back on failure; the explanation is a line under it that
                // nothing focuses. Spoken and felt (A6), so "it just flipped back" stops being the
                // whole story.
                FernletFeedback.system.play(.failed)
                FernletAnnouncer.system.announce(.error, resolved: error.localizedDescription)
            }
        }
    }

    /// The status headline. Both no-passcode states read "No passcode" (design §10.3) — the
    /// tap-opened Private tab proves no credential, so it is never "Unlocked" here.
    private var statusLabel: LocalizedStringKey {
        switch lockService.state {
        case .notConfigured, .openedWithoutPasscode: return "No passcode"
        case .locked(let d):
            if let d { return "Locked (cooldown until \(d.formatted(.dateTime.hour().minute())))" }
            return lockService.requiresReset ? "Locked (reset required)" : "Locked"
        case .unlocked: return "Unlocked"
        }
    }

    private var statusColor: Color {
        switch lockService.state {
        case .notConfigured, .openedWithoutPasscode: Color.softTaupe
        case .locked: Color.terracotta
        case .unlocked: Color.moss
        }
    }

    /// The status card's credential line. `LocalizedStringKey`: as a `String` it was drawn verbatim.
    private func kindLabel(_ kind: FernletLockCredentialKind) -> LocalizedStringKey {
        switch kind {
        case .pin4: "4-digit PIN"
        case .pin6: "6-digit PIN"
        case .alphanumeric: "Alphanumeric password"
        }
    }

    /// A row's name (`.sl`), terracotta and semibold when it destroys something (`.sr.danger`). The
    /// row's button style draws the chevron.
    private func settingsRow(_ title: LocalizedStringKey, destructive: Bool = false) -> some View {
        FernletRowLabel(title, destructive: destructive)
    }
}

// MARK: - Change passcode view (presented as sheet from AppLockSettingsView)

/// Three-step change-passcode flow: verify the current passcode, pick a new kind and enter it, then
/// confirm and commit.
///
/// Presented as a sheet from ``AppLockSettingsView``. Verification goes through
/// `FernletLockService.unlock` and the commit through `changeCredential`, so the sealed stores are
/// re-keyed by the service — this view only shepherds the input. PIN entries auto-advance when the
/// digit count fills; alphanumeric steps use an explicit Continue button (minimum 8 characters for
/// the new password).
private struct FernletLockChangePasscodeView: View {
    @Environment(FernletLockService.self) private var lockService
    @Environment(\.dismiss) private var dismiss
    /// The World's framed look (`b3-change-passcode`): paper, framed cards, framed pad.
    @Environment(\.fernletFramedLook) private var look

    @State private var currentPasscode = ""
    @State private var newPasscode = ""
    @State private var confirmPasscode = ""
    @State private var selectedKind: FernletLockCredentialKind
    @State private var step: ChangeStep = .verifyOld
    @State private var errorMessage: String?

    init() {
        _selectedKind = State(initialValue: .pin6)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                (look?.paper ?? Color.parchment).ignoresSafeArea()
                // All three steps host the shared PIN pad, whose tiles grow with Dynamic Type;
                // without this the bottom key row falls off the sheet at the accessibility sizes
                // and in landscape, on a flow whose only other exit is Cancel.
                stepContent
                    .padding(24)
                    .fernletLockPadPage()
            }
            // Cancel top left, the title inside the sheet (`b1-frame-sheet`).
            .fernletSheetToolbar(title: "Change passcode", onCancel: { dismiss() })
        }
        .tint(Color.moss)
        .fernletSheet()
        .onAppear { selectedKind = lockService.credentialKind ?? .pin6 }
    }

    @ViewBuilder private var stepContent: some View {
        switch step {
        case .verifyOld:
            verifyOldStep
        case .enterNew:
            enterNewStep
        case .confirmNew:
            confirmNewStep
        }
    }

    // Verify current passcode
    private var verifyOldStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            SectionLabel("Current passcode")
            // Says WHY it is asking again seconds after the gate accepted the same passcode: the
            // re-key needs it, and an unexplained re-prompt reads as the app not having listened.
            Text("Enter your current passcode again — Fernlet needs it to re-key your sealed notes.")
                .font(.fernlet(.body))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()

            if let msg = errorMessage { errorBanner(msg) }

            let oldKind = lockService.credentialKind ?? .pin6
            if oldKind == .alphanumeric {
                SecureField("Current password", text: $currentPasscode, prompt: .fieldPrompt("Current password"))
                    .textContentType(.password)
                    .sheetTextInput()
                Spacer()
                continueButton { advanceFromVerifyOld() }
            } else {
                let total = oldKind == .pin4 ? 4 : 6
                pinDotsRow(current: currentPasscode, total: total)
                    .frame(maxWidth: .infinity)
                Spacer(minLength: 12)
                // Each step's pad advances from the tap that fills it (`onFilled`), not an `onChange`.
                FernletNumericPad(value: $currentPasscode, maxLength: total, onFilled: advanceFromVerifyOld)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func advanceFromVerifyOld() {
        Task { @MainActor in
            do {
                // Presented from the (already `.appLockSettings`-unlocked) App lock page, so the
                // re-verification stays in that scope rather than escalating to the Private Hub.
                _ = try await lockService.unlock(passcode: currentPasscode, for: .appLockSettings)
                errorMessage = nil
                step = .enterNew
            } catch {
                currentPasscode = ""
                fail(error.localizedDescription)
            }
        }
    }

    /// Shows `message` as this flow's error and plays the error haptic beside it (A12). The lock
    /// setup, change-passcode and duress-code flows each carry this same helper and the same one
    /// `done` on success, one-to-one: a duress code is set up exactly as a passcode is changed, so the
    /// two must feel identical as well as look identical. Imperative rather than keyed on
    /// `errorMessage`, so a second identical mismatch is felt too.
    private func fail(_ message: String) {
        errorMessage = message
        FernletFeedback.system.play(.failed)
    }

    // Enter new passcode
    private var enterNewStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            SectionLabel("New passcode")
            Text("Choose a lock type for your new passcode.")
                .font(.fernlet(.body))
                .foregroundStyle(Color.slate)

            VStack(spacing: 12) {
                changeKindCard(.pin4, title: "4-digit PIN")
                changeKindCard(.pin6, title: "6-digit PIN")
                changeKindCard(.alphanumeric, title: "Password")
            }

            if let msg = errorMessage { errorBanner(msg) }
            if selectedKind == .alphanumeric {
                SecureField("New password", text: $newPasscode, prompt: .fieldPrompt("New password"))
                    .textContentType(.newPassword)
                    .sheetTextInput()
                Spacer()
                continueButton(disabled: newPasscode.count < 8) { step = .confirmNew }
            } else {
                let total = selectedKind == .pin4 ? 4 : 6
                pinDotsRow(current: newPasscode, total: total)
                    .frame(maxWidth: .infinity)
                Spacer(minLength: 12)
                FernletNumericPad(value: $newPasscode, maxLength: total) { step = .confirmNew }
                    .frame(maxWidth: .infinity)
            }
        }
        .onChange(of: selectedKind) { _, _ in newPasscode = "" }
    }

    /// One lock-type row. `title` is a `LocalizedStringKey`: as a `String` the three literals passed to
    /// it never reached the catalog.
    private func changeKindCard(_ kind: FernletLockCredentialKind, title: LocalizedStringKey) -> some View {
        Button { selectedKind = kind } label: {
            if let look {
                // The framed radio card, as the lock setup draws it (`b3-lock-kind`).
                Text(title)
                    .font(FernletFramedFont.rowTitleBold)
                    .foregroundStyle(look.text)
                    .modifier(LockRadioCardChrome(isSelected: kind == selectedKind, look: look))
            } else {
                standardKindRow(kind, title: title)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(kind == selectedKind ? [.isSelected] : [])
    }

    /// Today's lock-type row: a radio circle and the name on cream.
    private func standardKindRow(_ kind: FernletLockCredentialKind, title: LocalizedStringKey) -> some View {
        HStack(spacing: 14) {
            Image(systemName: kind == selectedKind ? "checkmark.circle.fill" : "circle")
                .font(.title3.weight(.semibold))
                .foregroundStyle(kind == selectedKind ? Color.moss : Color.slate)
            Text(title)
                .font(.fernlet(.label))
                .foregroundStyle(Color.bark)
            Spacer()
        }
        .padding(14)
        .background(
            kind == selectedKind ? Color.moss.opacity(0.06) : Color.cream,
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(
                    kind == selectedKind ? Color.moss.opacity(0.4) : Color.bark.opacity(0.08),
                    lineWidth: 1
                )
        )
    }

    // Confirm new passcode
    private var confirmNewStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            SectionLabel("Confirm new passcode")
            if let msg = errorMessage { errorBanner(msg) }
            if selectedKind == .alphanumeric {
                SecureField("Confirm new password", text: $confirmPasscode, prompt: .fieldPrompt("Confirm new password"))
                    .textContentType(.newPassword)
                    .sheetTextInput()
                Spacer()
                continueButton(disabled: confirmPasscode.isEmpty) { commitChange() }
            } else {
                let total = selectedKind == .pin4 ? 4 : 6
                pinDotsRow(current: confirmPasscode, total: total)
                    .frame(maxWidth: .infinity)
                Spacer(minLength: 12)
                FernletNumericPad(value: $confirmPasscode, maxLength: total, onFilled: commitChange)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func commitChange() {
        guard newPasscode == confirmPasscode else {
            confirmPasscode = ""
            fail(String(localized: "settings.changePasscode.mismatch",
                        defaultValue: "Passcodes don't match. Try again.",
                        comment: "Change passcode, confirm step: the second entry did not match the new passcode."))
            return
        }
        Task { @MainActor in
            do {
                let newCredential: FernletLockCredential
                switch selectedKind {
                case .pin4: newCredential = .pin4(newPasscode)
                case .pin6: newCredential = .pin6(newPasscode)
                case .alphanumeric: newCredential = .alphanumeric(newPasscode)
                }
                try await lockService.changeCredential(current: currentPasscode, new: newCredential)
                // A12: the same `done` the lock setup and duress flows play.
                FernletFeedback.system.play(.done)
                dismiss()
            } catch {
                confirmPasscode = ""
                fail(error.localizedDescription)
            }
        }
    }

    /// The framed primary, full width; faded (fill only, never the word) while disabled.
    private func continueButton(disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text("Continue").frame(maxWidth: .infinity)
        }
        .buttonStyle(ActionPillButtonStyle(.primary))
        .disabled(disabled)
    }

    /// A step's error as the framed warning notice.
    private func errorBanner(_ msg: String) -> some View {
        FernletNotice(text: Text(verbatim: msg), tone: .warn) { EmptyView() }
    }

    /// The three sequential screens of the change-passcode flow.
    ///
    /// Strictly forward: `verifyOld` gates entry, `enterNew` collects the replacement, `confirmNew`
    /// re-enters it and commits; a mismatch or service error resets the offending field in place.
    private enum ChangeStep { case verifyOld, enterNew, confirmNew }
}

// MARK: - Away-hearts consent copy

/// The away-delivery consent paragraph the Nearby friends page renders while the feature is ON.
///
/// It lives in THIS file on purpose: `HeartDropAppWiringTests` source-pins two locked claims to
/// `SettingsSheet.swift` — that the drop-off is "separate from iCloud Sync" (the dead-drop is
/// independent of the sync preference; a user who declined sync must not assume this rides it) and
/// that "Turning it off deletes the hearts still waiting there" (queued hearts are purged, not
/// resumed). ``NearbyFriendsSettingsView`` renders it; do not inline the copy there.
enum AwayDeliveryConsentCopy {
    /// The full consent disclosure, shown under the "Deliver hearts later" toggle while it is on.
    static let disclosure: LocalizedStringKey = "When a friend isn't nearby, a heart is sealed end-to-end and left in a shared iCloud drop-off under a rotating tag only that friend's device can recognize — delivered when they next open Fernlet. This is separate from iCloud Sync: only hearts go there, never your own data, and it works whether or not you sync Fernlet. Turning it off deletes the hearts still waiting there, so they won't be delivered later."
}

// MARK: - Display names for stored tokens

/// The names the Core memory page draws for a memory's stored `category` token.
///
/// `MemoryNote.category` is persisted and synced, and it is what the page groups by and the editor's
/// chips store — so it never localizes. The categories Fernlet itself writes are a journal entry's
/// ``FeelingTag`` raw value and the editor's "other"; those draw localized names here. Any other token
/// (one an older build or the user wrote) draws exactly as before: capitalized on a chip, upper-cased
/// in the root locale on a heading. A feeling's name is the mood chip's own label, agreed with the
/// user's term of address (`address`, the page's `fernletTermOfAddress`), since it names how they felt.
nonisolated enum MemoryCategoryName {
    /// The localized name for a category token Fernlet writes, or nil for any other token.
    static func knownName(for token: String, addressing address: TermOfAddress) -> String? {
        if let feeling = FeelingTag(rawValue: token) { return feeling.label(addressing: address) }
        guard token == "other" else { return nil }
        return String(localized: "settings.memory.category.other", defaultValue: "Other",
                      comment: "Core memory: the category for a memory that fits no other group. A chip in the memory editor, and a group heading (drawn in capitals).")
    }

    /// A group heading for `groupKey`, the upper-cased token the page groups by. A known category
    /// draws its localized name (the heading's `.textCase(.uppercase)` capitalizes it after the
    /// lookup); any other token draws as it always has.
    static func heading(forGroup groupKey: String, addressing address: TermOfAddress) -> String {
        knownName(for: groupKey.lowercased(), addressing: address) ?? groupKey
    }

    /// An editor chip's label for `token` (stored lower-cased).
    static func chipLabel(for token: String, addressing address: TermOfAddress) -> String {
        knownName(for: token, addressing: address) ?? token.capitalized
    }
}

// MARK: - Shared pin dots row helper (used in SettingsSheet-internal views)

private func pinDotsRow(current: String, total: Int) -> some View {
    SettingsPinDots(entered: current.count, total: total)
}
