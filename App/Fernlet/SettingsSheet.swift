#if canImport(UIKit)
import ProximityKit
import UIKit
import LocalPersistence
#endif
import HealthKit
import LocalAuthentication
import SwiftUI
import FernletDomainModel
import FernletFoundation
import FernletLock
import FernletScoring
import HealthKitGateway
import AppServices
import FernletUI
import FernletLockUI

/// The Settings hub: a searchable, sectioned Form that routes to every settings sub-page and hosts
/// the app-wide toggles that don't warrant a page of their own.
///
/// Presented as a sheet from the main UI over a `NavigationStack`. Navigation is value-based: every
/// link and every search result pushes a ``SettingsRoute``, resolved by the single
/// `destination(for:)` factory — the scroll-wrapped tabs (appearance, goal & nutrition, layout,
/// health, sleep, move, memories, signals, debug, connection inspector) are built inline here, while
/// the standalone screens (``PrivacyDataSettingsView``, ``PrivacyPolicyView``, `SafetyReportingView`,
/// ``AIAuditLogView``, ``AppLockSettingsView``) return with their own chrome. A non-empty search
/// query swaps the Form for a ``SettingsSearchIndex`` results list.
///
/// Key collaborators: ``FernletStore`` (`@Bindable`, all setting mutations), `FernletLockService`
/// and `StoragePreferencesStore` from the environment, `HealthKitAuthorizationViewModel` for the
/// Health tab, and `NotificationService` for the daily check-in reminder (the pending notification
/// request is that feature's persistence — the local `@State` merely mirrors it per visit).
///
/// Invariants this view enforces:
/// - Nothing destructive happens silently: hiding period/intimacy tracking, removing a core memory
///   or a personal-care task, and "Delete everything"
///   route through ``DestructiveConfirmation`` / ``DeleteAllDataConfirmation``, and a wipe raises
///   `deleteFlow.isDeleting` (``DeleteEverythingFlow``) to show ``DeletingEverythingOverlay``,
///   disable the delete/Done buttons, and block interactive dismissal so a second confirm can't
///   interleave.
/// - The quick-log editor edits the STORED shortcut array, never a visibility-filtered one, so
///   hiding a sensitive surface can't destroy the saved layout (see `quickLogEditorItems`).
/// - Sensitive Health actions re-check visibility at the point of use (`canUseHealthCapability`),
///   not just the point of display.
struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Bindable var store: FernletStore
    @Environment(FernletLockService.self) private var lockService
    @Environment(StoragePreferencesStore.self) private var storagePreferencesStore
    /// System / Light / Dark. The app root reads the same key and hands ``FernletAppearanceMode``'s
    /// `colorScheme` (nil for `.system`) to `preferredColorScheme`, so "System" really does follow
    /// the phone; the legacy Dark-mode Bool is migrated once at launch.
    @AppStorage(FernletAppearanceMode.storageKey) private var appearanceMode: FernletAppearanceMode = .system
    @AppStorage(FernletThemeDefaults.customLightBackgroundKey) private var customLightBackgroundHex = FernletThemeDefaults.lightBackgroundHex
    @AppStorage(FernletThemeDefaults.customDarkBackgroundKey) private var customDarkBackgroundHex = FernletThemeDefaults.darkBackgroundHex
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
    /// Hearts require presence (Group 2): when the user turns hearts ON while Nearby Friends is
    /// off, offer to enable presence too — hearts are dead without it.
    @State private var offerPresenceForHearts = false
    /// Settings search query (item 10). Non-empty swaps the Form for a results List; the search bar
    /// lives on the stable `settingsContent` so it persists across that swap.
    @State private var settingsSearch = ""
    // Debug tab only: tier-2 records load post-render (repository decodes the whole DB per read).
    @State private var debugTierTwoMemories: [TierTwoMemoryRecord]?
    /// One in-flight reminder reschedule at a time (R3): the DatePicker emits a change per wheel
    /// tick, and they all write the same notification identifier.
    @State private var checkInRescheduleTask: Task<Void, Never>?
    /// One in-flight HealthKit body-profile sync at a time (R3): Stepper/Picker ticks would otherwise
    /// each spawn their own `saveBodyProfileMeasurements` write for a single edit session.
    @State private var profileSyncTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            settingsContent
                .navigationTitle("Settings")
                .navigationDestination(for: SettingsRoute.self) { route in
                    destination(for: route)
                }
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
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                            .font(.fernlet(.label))
                            .foregroundStyle(Color.moss)
                            .disabled(deleteFlow.isDeleting)
                            .accessibilityIdentifier("settings.done")
                    }
                }
        }
        // The Settings sheet is a separate presentation from the tab content, so ContentView's
        // `.tint(Color.moss)` never reached it — every hub Toggle rendered the system green.
        .tint(Color.moss)
        .background(Color.parchment)
        .overlay {
            if deleteFlow.isDeleting {
                DeletingEverythingOverlay()
            }
        }
        // No swipe-to-dismiss mid-wipe: a wipe is multi-second and the sheet must not close (or re-run)
        // out from under it.
        .interactiveDismissDisabled(deleteFlow.isDeleting)
        .destructiveConfirmation($pendingDestructiveAction)
        // Success ("Done") dismisses the sheet — the visit is over; failure keeps it put for a retry.
        .deleteEverythingAlerts(deleteFlow, successButtonTitle: "Done", successButtonRole: nil) {
            dismiss()
        }
        .onAppear { healthKit.refresh() }
    }

    /// Whether the search field currently has a query. Drives the Form ⇄ results swap.
    private var isSearching: Bool {
        !settingsSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
    /// Rows render ``SettingsSearchEntry/displayTitle`` — the display half of the entry's
    /// token/display fork. `entry.title` is the frozen English matching input and must never reach a
    /// `Text`: as a `String` it would take `Text`'s verbatim initializer and render untranslated.
    private var searchResultsList: some View {
        List {
            let results = SettingsSearchIndex.results(for: settingsSearch)
            if results.isEmpty {
                Text("No matching settings")
                    .font(.fernlet(.body))
                    .foregroundStyle(Color.slate)
                    .listRowBackground(Color.cream)
            } else {
                ForEach(results) { entry in
                    NavigationLink(value: entry.route) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.displayTitle)
                                .font(.fernlet(.label))
                                .foregroundStyle(Color.bark)
                            Text(entry.breadcrumb)
                                .font(.fernlet(.labelSmall))
                                .foregroundStyle(Color.slate)
                        }
                    }
                    .listRowBackground(Color.cream)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.parchment)
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
        case .layoutShortcuts:
            settingsDestination(title: "Layout & shortcuts") { layoutTab }
        case .health:
            settingsDestination(title: "Health") { healthTab }
        case .sleep:
            settingsDestination(title: "Sleep") { sleepTab }
        case .move:
            settingsDestination(title: "Move") { moveTab }
        case .coreMemory:
            settingsDestination(title: "Core memory") { memoriesTab }
        case .signals:
            settingsDestination(title: "Signals") { signalsTab }
        case .debug:
            settingsDestination(title: "Debug") { debugTab }
        case .connectionInspector:
            settingsDestination(title: "Connection Inspector") { connectionInspectorTab }
        case .connectionHistory:
            ConnectionInspectorHistoryView(inspector: store.connectionInspector)
        case .privacyData:
            PrivacyDataSettingsView(store: store)
                .environment(lockService)
        case .aiAuditLog:
            AIAuditLogView()
        case .privacyPolicy:
            PrivacyPolicyView()
        case .safetyReporting:
            SafetyReportingView()
        case .appLock:
            AppLockSettingsView()
                .environment(lockService)
                .fernletLockGate(scope: .appLockSettings, active: lockService.state != .notConfigured)
                .environment(lockService)
        }
    }

    private var settingsForm: some View {
        Form {
            generalSection
            wellnessSection
            periodSection
            intimacySection
            advancedSection
            privacySection
            dangerSection
        }
        .scrollContentBackground(.hidden)
        .background(Color.parchment)
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
            Text(title)
                .font(.fernlet(.label))
                .foregroundStyle(Color.bark)
        }
    }

    private var generalSection: some View {
        Section {
            hubLink("Appearance", .appearance)
            hubLink("Goal & nutrition", .goalNutrition)
            hubLink("Layout & shortcuts", .layoutShortcuts)
        } header: {
            hubSectionHeader("General")
        }
        .listRowBackground(Color.cream)
    }

    private var wellnessSection: some View {
        Section {
            hubLink("Health", .health)
            hubLink("Sleep", .sleep)
            hubLink("Move", .move)
                .accessibilityIdentifier("settings.move")
        } header: {
            hubSectionHeader("Wellness")
        }
        .listRowBackground(Color.cream)
    }

    private var periodSection: some View {
        Section {
            hubToggle("Period tracking", isOn: periodTrackingVisibleBinding)
                .accessibilityIdentifier("settings.period.visible")
            // Cosmetic sub-options: these still read cycle data, so they only make sense —
            // and are only offered — while the hard gate above is on.
            if store.isPeriodTrackingVisible {
                hubToggle("Hide predictions", isOn: hidePredictionsBinding)
                hubToggle("Hide fertile window", isOn: hideFertileWindowBinding)
                hubToggle("Period-aware care", isOn: periodAwareScoringBinding)
            }
        } header: {
            hubSectionHeader("Period")
        } footer: {
            if store.isPeriodTrackingVisible {
                Text("When on, gentle cycle-phase trends can soften your daily score and surface a cycle chip and outlook on Home. Off by default, and only takes effect after a few cycles are logged.\n\nTurning off Period tracking hides every cycle surface and stops Fernlet reading your cycle data. Your entries are kept, not deleted.")
            } else {
                Text("Cycle surfaces are hidden and Fernlet isn't reading your cycle data. Your entries are kept — turn this back on any time to see them again. Entries in Apple Health stay there either way.")
            }
        }
        .listRowBackground(Color.cream)
    }

    private var intimacySection: some View {
        Section {
            if store.isIntimateLoggingAllowed {
                hubToggle("Intimacy tracking", isOn: intimacyTrackingVisibleBinding)
                    .accessibilityIdentifier("settings.intimacy.visible")
            } else {
                // Age is a floor, not a preference — say the true reason rather than showing a
                // toggle that would silently do nothing. The notice also carries the only way
                // back for someone who installed before this gate existed, or who has since
                // had a birthday.
                AgeGateNotice(
                    gate: .intimacy,
                    featureName: "Intimacy tracking",
                    ageAssurance: store.ageAssurance
                )
            }
        } header: {
            hubSectionHeader("Intimacy")
        } footer: {
            if store.isIntimateLoggingAllowed {
                Text(store.settings.intimacyTrackingVisible
                     ? "Private intimacy notes, sealed on this device. Turning this off hides the feature and stops Fernlet reading it. Your notes are kept, not deleted."
                     : "Intimacy surfaces are hidden and Fernlet isn't reading them. Your notes are kept — turn this back on any time. Entries in Apple Health stay there either way.")
            }
        }
        .listRowBackground(Color.cream)
    }

    private var advancedSection: some View {
        Section {
            hubLink("Core memory", .coreMemory)
            hubLink("Signals", .signals)
            #if DEBUG
            // A development inspection surface, headed "Prototype only — not production-private".
            // It has no business in a shipping user's hub, so it compiles out of release builds
            // (the UI-test suite runs Debug, where the row is still here).
            hubLink("Debug", .debug)
            #endif
            // Connection Inspector keeps its own row; the History page it already links to no
            // longer duplicates it here.
            hubLink("Connection Inspector", .connectionInspector)
        } header: {
            hubSectionHeader("Advanced")
        }
        .listRowBackground(Color.cream)
    }

    /// The privacy hub: links to the standalone privacy screens plus every nearby-sharing consent
    /// switch. The hearts-need-presence offer alert stays attached to this section, because it is
    /// raised by the hearts toggle inside it.
    private var privacySection: some View {
        Section {
            hubLink("Privacy & Data", .privacyData)
            // The "what left my device" ledger. It belongs beside the privacy screens rather than
            // under the AI switches: it is a disclosure surface, not a control.
            hubLink("AI activity log", .aiAuditLog)
                .accessibilityIdentifier("settings.aiAuditLog")
            hubLink("Privacy Policy", .privacyPolicy)
            hubLink("Safety & reporting", .safetyReporting)
            hubLink("App lock", .appLock)
            nearbySharingToggles
            awayDeliveryControls
            presenceToggles
        } header: {
            hubSectionHeader("Privacy")
        } footer: {
            // The standing promise used to be a serif paragraph above the first section, which at
            // accessibility sizes left one row on screen. It belongs with the controls it describes.
            Text("Your data stays on this phone unless you turn on iCloud sync.\n\nNearby friends presence lets friends you've kept see when you're close by. Fernlet broadcasts only rotating tags that your friends' devices can recognize — never your name or a stable identifier — and only while the app is open and unlocked. Nearby hearts uses that same presence connection to send a friend a heart in person, so it needs Nearby Friends turned on. If you keep presence on but turn hearts off, friends can still see you're nearby, but any heart sent to you is quietly dropped.")
        }
        .alert("Turn on Nearby Friends?", isPresented: $offerPresenceForHearts) {
            Button("Turn on") { store.setAllowNearbyPresence(true) }
            Button("Not now", role: .cancel) {}
        } message: {
            Text("Hearts are sent in person over Nearby Friends. Turn it on so you can see when friends are close by and send them a heart. Fernlet broadcasts only rotating tags your friends can recognize — never your name.")
        }
        .listRowBackground(Color.cream)
    }

    /// The in-person sharing consents: recipes, clothing shops, and hearts (which need presence).
    @ViewBuilder
    private var nearbySharingToggles: some View {
        hubToggle(
            "Allow nearby recipe shares",
            isOn: Binding(
                get: { store.settings.allowNearbyRecipeShares },
                set: { store.setAllowNearbyRecipeShares($0) }
            )
        )
        // Phase 3a: payload-layer control — the shop rides the friend session (no
        // standalone radio), so this governs whether shop catalogs are shared at all.
        hubToggle(
            "Share clothing shops with friends",
            isOn: Binding(
                get: { store.settings.allowNearbyClothingShares },
                set: { store.setAllowNearbyClothingShares($0) }
            )
        )
        // Phase 4b: hearts ride the presence radio (no standalone radio). This governs
        // whether hearts are sent AND received; the presence toggle below still runs.
        // Hearts require presence (Group 2): enabling hearts while Nearby Friends is off
        // offers to enable presence, since hearts cannot function without it.
        hubToggle(
            "Allow nearby hearts",
            isOn: Binding(
                get: { store.settings.allowNearbyHearts },
                set: { newValue in
                    store.setAllowNearbyHearts(newValue)
                    if newValue && !store.settings.allowNearbyPresence {
                        offerPresenceForHearts = true
                    }
                }
            )
        )
        if store.settings.allowNearbyHearts && !store.settings.allowNearbyPresence {
            Text("Hearts need Nearby Friends turned on to work — turn it on below.")
                .font(.fernlet(.bodySmall))
                .foregroundStyle(Color.slate)
        }
        // In-session messaging has no toggle — session membership is its consent gate — so
        // its 13+ age requirement is the one thing that can withhold it. Surfaced here
        // because the chat button simply doesn't appear in-session, which on its own would
        // read as a bug rather than a rule.
        if !store.ageAssurance.allows(.chat) {
            AgeGateNotice(
                gate: .chat,
                featureName: "Messaging friends nearby",
                ageAssurance: store.ageAssurance
            )
        }
    }

    /// Away delivery (bitchat adoptions Increment 3): the one proximity feature that touches the
    /// network, so it carries its own explicit opt-in — separate from iCloud Sync (public dead-drop,
    /// not the synced store) — plus every state where the "on" promise isn't being kept.
    @ViewBuilder
    private var awayDeliveryControls: some View {
        hubToggle(
            "Deliver hearts when apart",
            isOn: Binding(
                get: { store.settings.heartsAwayDelivery },
                set: { store.setHeartsAwayDelivery($0) }
            )
        )
        if store.settings.heartsAwayDelivery {
            Text("When a friend isn't nearby, a heart is sealed end-to-end and left in a shared iCloud drop-off under a rotating tag only that friend's device can recognize — delivered when they next open Fernlet. This is separate from iCloud Sync: only hearts go there, never your own data, and it works whether or not you sync Fernlet. Turning it off deletes the hearts still waiting there, so they won't be delivered later.")
                .font(.fernlet(.bodySmall))
                .foregroundStyle(Color.slate)
            // Nothing-silent: the toggle being on is a promise of delivery, so every
            // state where that promise isn't being kept gets said out loud here.
            if let problem = awayDeliveryProblemText {
                HStack(alignment: .top, spacing: 10) {
                    Text(problem)
                        .font(.fernlet(.bodySmall))
                        .foregroundStyle(Color.goldenrod)
                        // Identifiers sit on the leaves, not the HStack: an identifier
                        // on the container shadows its children for UI tests.
                        .accessibilityIdentifier("settings.heartsAway.problem")
                    Spacer(minLength: 0)
                    Button("Dismiss") {
                        store.heartDropService.acknowledgeDeliveryProblem()
                    }
                    .font(.fernlet(.labelSmall))
                    .foregroundStyle(Color.moss)
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("settings.heartsAway.dismissProblem")
                }
            }
        } else if store.heartsAwayPurgePending {
            // Consent is off but our own sealed records are still on the public
            // database, because the delete didn't go through. Say so rather than let
            // "off" imply they were removed; the foreground listener retries.
            Text("Some hearts Fernlet left in the iCloud drop-off couldn't be removed yet — it'll keep trying while you're online.")
                .font(.fernlet(.bodySmall))
                .foregroundStyle(Color.goldenrod)
                .accessibilityIdentifier("settings.heartsAway.purgePending")
        }
    }

    /// The standing presence radio and the fuzzy-vibe share that rides it.
    @ViewBuilder
    private var presenceToggles: some View {
        // Phase 4a: the standing presence radio — rotating pairwise tags only.
        hubToggle(
            "Nearby friends presence",
            isOn: Binding(
                get: { store.settings.allowNearbyPresence },
                set: { store.setAllowNearbyPresence($0) }
            )
        )
        // Phase 4: share a fuzzy vibe (thriving/okay/struggling) + your avatar with kept
        // friends when you meet in person. Never a number, goal, or cycle. Default off.
        hubToggle(
            "Share your vibe with friends",
            isOn: Binding(
                get: { store.settings.allowNearbyFriendState },
                set: { store.setAllowNearbyFriendState($0) }
            )
        )
    }

    /// A hub switch in the app's type system. The moss switch colour comes from the sheet-level
    /// `.tint(Color.moss)`, so every hub toggle now matches the Privacy & Data ones.
    ///
    /// `title` is `LocalizedStringKey`, never `String` — same rule and same reasoning as
    /// ``hubLink(_:_:)``: a `String` parameter silently opts every call site out of localization
    /// (the literal looks auto-localizing, extracts into no catalog, and renders English forever on
    /// a clean build). All eleven call sites pass a literal, so none needed editing and none
    /// carries runtime text; if one ever must, it gets a distinctly-labelled `verbatim:` sibling
    /// rather than a same-label `String` overload (which would win for a plain literal and quietly
    /// re-introduce the bug).
    private func hubToggle(_ title: LocalizedStringKey, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title)
                .font(.fernlet(.label))
                .foregroundStyle(Color.bark)
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

    /// Why away hearts aren't being delivered right now, or nil when the drop-off is healthy.
    /// Deliberately phrased for the feature (the friend row phrases the same conditions per friend):
    /// this is the surface that has to answer "I turned it on — is it actually working?".
    private var awayDeliveryProblemText: String? {
        AwayHeartsCopy.settingsLine(for: store.heartDropService.deliveryProblem)
    }

    /// Turning cycle tracking OFF is confirmed; turning it back ON is not. Hiding is not destructive —
    /// entries are kept — but it has a consequence the user cannot otherwise predict: cycle-phase
    /// softening stops, so on a hard cycle day their score drops and the companion looks sadder right
    /// after they chose privacy. Saying so up front is the difference between a considered choice and
    /// an unexplained punishment.
    private var periodTrackingVisibleBinding: Binding<Bool> {
        Binding(
            get: { store.isPeriodTrackingVisible },
            set: { newValue in
                guard !newValue else {
                    store.setPeriodTrackingVisible(true)
                    return
                }
                pendingDestructiveAction = DestructiveConfirmation(
                    title: "Turn off period tracking?",
                    message: "Fernlet will hide every cycle surface and stop reading your cycle data. "
                        + "Your entries are kept — turn this back on any time to see them again.\n\n"
                        + "Your daily score may change: Fernlet will stop softening it around your cycle. "
                        + "Anything you've saved in Apple Health stays in Apple Health.",
                    confirmLabel: "Turn off",
                    auditEvent: "settings.period.hideConfirmed"
                ) {
                    store.setPeriodTrackingVisible(false)
                }
            }
        )
    }

    private var intimacyTrackingVisibleBinding: Binding<Bool> {
        Binding(
            get: { store.settings.intimacyTrackingVisible },
            set: { newValue in
                guard !newValue else {
                    store.setIntimacyTrackingVisible(true)
                    return
                }
                pendingDestructiveAction = DestructiveConfirmation(
                    title: "Turn off intimacy tracking?",
                    message: "Fernlet will hide intimacy logging and stop reading it. Your notes are "
                        + "kept — turn this back on any time to see them again.\n\n"
                        + "Anything you've saved in Apple Health stays in Apple Health.",
                    confirmLabel: "Turn off",
                    auditEvent: "settings.intimacy.hideConfirmed"
                ) {
                    store.setIntimacyTrackingVisible(false)
                }
            }
        )
    }

    private var hidePredictionsBinding: Binding<Bool> {
        Binding(
            get: { store.settings.hidePredictions },
            set: { store.setHidePredictions($0) }
        )
    }

    private var hideFertileWindowBinding: Binding<Bool> {
        Binding(
            get: { store.settings.hideFertileWindow },
            set: { store.setHideFertileWindow($0) }
        )
    }

    private var periodAwareScoringBinding: Binding<Bool> {
        Binding(
            get: { store.settings.periodAwareScoringEnabled },
            set: { store.setPeriodAwareScoringEnabled($0) }
        )
    }

    private var connectionInspectorModeBinding: Binding<ConnectionInspectorMode> {
        Binding(
            get: { store.settings.connectionInspectorMode },
            set: { store.setConnectionInspectorMode($0) }
        )
    }

    private func settingsDestination<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ScrollView {
            content()
                .padding(20)
                .padding(.bottom, 20)
        }
        .scrollContentBackground(.hidden)
        .background(Color.parchment)
        .navigationTitle(title)
    }

    private var appearanceTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                SheetField("Appearance") {
                    FlowLayout(spacing: 8) {
                        ForEach(FernletAppearanceMode.allCases) { mode in
                            Button(mode.label) { appearanceMode = mode }
                                .buttonStyle(ChipButtonStyle(selected: appearanceMode == mode))
                        }
                    }
                }
                Text("“System” follows your phone's Light/Dark setting, the way onboarding already does.")
                    .font(.fernlet(.bodySmall))
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))
            SectionLabel("Backgrounds")
            VStack(alignment: .leading, spacing: 12) {
                Text("Choose separate backgrounds for light and dark mode. Cards and input boxes stay in the same color family so the existing text colors remain readable.")
                    .font(.fernlet(.body))
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()

                themeColorRow(
                    title: "Light mode",
                    color: themeColorBinding(
                        keyPath: \.customLightBackgroundHex,
                        defaultHex: FernletThemeDefaults.lightBackgroundHex
                    ),
                    hex: customLightBackgroundHex,
                    defaultHex: FernletThemeDefaults.lightBackgroundHex
                ) {
                    customLightBackgroundHex = FernletThemeDefaults.lightBackgroundHex
                }

                themeColorRow(
                    title: "Dark mode",
                    color: themeColorBinding(
                        keyPath: \.customDarkBackgroundHex,
                        defaultHex: FernletThemeDefaults.darkBackgroundHex
                    ),
                    hex: customDarkBackgroundHex,
                    defaultHex: FernletThemeDefaults.darkBackgroundHex
                ) {
                    customDarkBackgroundHex = FernletThemeDefaults.darkBackgroundHex
                }
            }
            .padding(14)
            .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private func themeColorRow(title: String, color: Binding<Color>, hex: String, defaultHex: String, reset: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            ColorPicker(title, selection: color, supportsOpacity: false)
                .font(.fernlet(.label))
                .foregroundStyle(Color.bark)
            Text(hex.uppercased())
                .font(.fernlet(.stat))
                .foregroundStyle(Color.slate)
            Button("Reset", action: reset)
                .buttonStyle(.plain)
                .font(.fernlet(.label))
                .foregroundStyle(Color.moss)
                .disabled(hex.caseInsensitiveCompare(defaultHex) == .orderedSame)
        }
        .padding(12)
        .background(Color.parchment.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
    }

    private func themeColorBinding(keyPath: ReferenceWritableKeyPath<SettingsSheet, String>, defaultHex: String) -> Binding<Color> {
        Binding(
            get: {
                #if canImport(UIKit)
                return Color(UIColor(hex: self[keyPath: keyPath]) ?? UIColor(hex: defaultHex) ?? .systemBackground)
                #else
                return Color.parchment
                #endif
            },
            set: { newValue in
                #if canImport(UIKit)
                self[keyPath: keyPath] = UIColor(newValue).hexString ?? defaultHex
                #endif
            }
        )
    }

    private var layoutTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel("Home widgets")
            VStack(alignment: .leading, spacing: 8) {
                Text("Choose what appears on the main page and put the widgets in the order you want. Your companion always stays on Home — you can move it, but not remove it.")
                    .font(.fernlet(.body))
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()

                ForEach(Array(store.settings.homeWidgets.enumerated()), id: \.element.id) { index, widget in
                    homeWidgetLayoutRow(widget, index: index)
                }

                FlowLayout(spacing: 8) {
                    ForEach(availableHomeWidgets) { widget in
                        Button {
                            addHomeWidget(widget)
                        } label: {
                            Label(widget.title, systemImage: widget.systemImage)
                        }
                        .buttonStyle(ChipButtonStyle(selected: false))
                    }
                }

                Button("Reset home widgets") {
                    store.setHomeWidgets(HomeWidget.defaultWidgets)
                }
                .buttonStyle(.plain)
                .font(.fernlet(.label))
                .foregroundStyle(Color.moss)
            }
            .padding(14)
            .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))

            SectionLabel("Quick log")
            VStack(alignment: .leading, spacing: 8) {
                Text("Choose the six home shortcuts and put them in the order you want.")
                    .font(.fernlet(.body))
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()

                ForEach(0..<6, id: \.self) { index in
                    quickLogLayoutRow(index)
                }
            }
            .padding(14)
            .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))

        }
        .onAppear {
            store.setHomeWidgets(store.settings.homeWidgets)
        }
        // NOTE: this used to persist `visibleQuickLog(...)` back via `setQuickLogItems` on appear and
        // on every gate change. That was survivable while the only gate was the 18+ age check (which
        // effectively never flips mid-use), but it is destructive under a user-facing toggle: hiding a
        // surface would strip its shortcut from the SAVED array, and un-hiding could not put it back —
        // the choice is gone. Filtering is display-only now; the stored array keeps every choice.
    }

    private var availableHomeWidgets: [HomeWidget] {
        HomeWidget.allCases.filter { !store.settings.homeWidgets.contains($0) }
    }

    private func homeWidgetLayoutRow(_ widget: HomeWidget, index: Int) -> some View {
        HStack(spacing: 10) {
            reorderControls(
                name: widget.title,
                canMoveUp: index > 0,
                canMoveDown: index < store.settings.homeWidgets.count - 1
            ) { offset in
                moveHomeWidget(from: index, by: offset)
            }

            Label(widget.title, systemImage: widget.systemImage)
                .font(.fernlet(.label))
                .foregroundStyle(Color.bark)
                // Without the priority the fixed chevron/remove frames squeezed the label until
                // "Companion" broke mid-word as "Companio / n" at accessibility sizes.
                .fernletWrappingText()
                .layoutPriority(1)

            Spacer(minLength: 4)

            // The companion is the surface the whole app is built around, so it stays pinned:
            // reorderable, but never one stray tap away from being gone.
            if widget != .companion {
                Button {
                    removeHomeWidget(widget)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.slate)
                }
                .buttonStyle(.plain)
                .fernletIconButton("Remove \(widget.title) from Home")
            }
        }
        .padding(10)
        .background(Color.parchment.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
    }

    /// The stacked move-up / move-down controls shared by the widget and quick-log rows.
    ///
    /// 44pt targets with spoken labels: the old 28×24pt chevrons were both under the minimum target
    /// and announced by VoiceOver as "chevron.up". An unavailable end-of-list arrow is hidden rather
    /// than greyed — colour alone was the only signal that it did nothing.
    private func reorderControls(
        name: String,
        canMoveUp: Bool,
        canMoveDown: Bool,
        move: @escaping (Int) -> Void
    ) -> some View {
        VStack(spacing: 0) {
            Button { move(-1) } label: { Image(systemName: "chevron.up") }
                .fernletIconButton("Move \(name) up")
                .disabled(!canMoveUp)
                .opacity(canMoveUp ? 1 : 0)
                .accessibilityHidden(!canMoveUp)

            Button { move(1) } label: { Image(systemName: "chevron.down") }
                .fernletIconButton("Move \(name) down")
                .disabled(!canMoveDown)
                .opacity(canMoveDown ? 1 : 0)
                .accessibilityHidden(!canMoveDown)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.slate)
    }

    private func addHomeWidget(_ widget: HomeWidget) {
        var widgets = store.settings.homeWidgets
        guard !widgets.contains(widget) else { return }
        widgets.append(widget)
        store.setHomeWidgets(widgets)
    }

    private func removeHomeWidget(_ widget: HomeWidget) {
        var widgets = store.settings.homeWidgets
        widgets.removeAll { $0 == widget }
        store.setHomeWidgets(widgets)
    }

    private func moveHomeWidget(from index: Int, by offset: Int) {
        let destination = index + offset
        var widgets = store.settings.homeWidgets
        guard widgets.indices.contains(index), widgets.indices.contains(destination) else { return }
        widgets.swapAt(index, destination)
        store.setHomeWidgets(widgets)
    }

    private func quickLogLayoutRow(_ index: Int) -> some View {
        let currentItem = quickLogEditorItems[index]

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                reorderControls(
                    name: "slot \(index + 1)",
                    canMoveUp: index > 0,
                    canMoveDown: index < 5
                ) { offset in
                    moveQuickLogItem(from: index, by: offset)
                }

                Label("Slot \(index + 1): \(currentItem.title)", systemImage: currentItem.systemImage)
                    .font(.fernlet(.label))
                    .foregroundStyle(Color.bark)
                    .fernletWrappingText()
                    .layoutPriority(1)

                Spacer(minLength: 4)
            }

            FlowLayout(spacing: 8) {
                ForEach(availableQuickLogItems(for: index)) { item in
                    Button {
                        setQuickLogItem(item, at: index)
                    } label: {
                        Label(item.title, systemImage: item.systemImage)
                    }
                    .buttonStyle(ChipButtonStyle(selected: currentItem == item))
                }
            }
        }
        .padding(10)
        .background(Color.parchment.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
    }

    /// The layout this editor edits: the STORED array, deliberately NOT visibility-filtered.
    ///
    /// The editor's writes round-trip through `setQuickLogItems`, so feeding it a filtered list would
    /// be destructive: `normalizedQuickLog` caps at 6 and back-fills, so a hidden `.periodTracking`
    /// would be dropped from the SAVED layout and replaced by auto-filled padding — and un-hiding
    /// could not bring it back. Editing the stored array keeps every choice intact.
    ///
    /// Consequence: while a surface is hidden its shortcut still shows in THIS editor. That is not a
    /// leak (a quick-log preference is not cycle data), it is honest about what the saved layout is,
    /// and the user is standing next to the visibility toggle. Home is where filtering happens; the
    /// picker below still refuses to ADD a hidden surface.
    private var quickLogEditorItems: [FernletShortcut] {
        FernletShortcut.normalizedQuickLog(store.settings.quickLogItems)
    }

    private func availableQuickLogItems(for index: Int) -> [FernletShortcut] {
        let items = quickLogEditorItems
        let currentItem = items[index]
        let selectedElsewhere = Set(items.enumerated().compactMap { itemIndex, item in
            itemIndex == index ? nil : item
        })

        // Keep `currentItem` selectable even when hidden, so the chip for an already-chosen slot
        // renders as selected rather than vanishing mid-edit.
        return FernletShortcut.selectableQuickLogItems(visibility: store.sensitiveSurfaceVisibility).filter { item in
            item == currentItem || !selectedElsewhere.contains(item)
        }
    }

    private func setQuickLogItem(_ item: FernletShortcut, at index: Int) {
        guard store.isIntimateLoggingAllowed || item != .intimacyTracking else { return }
        var items = quickLogEditorItems
        if let existingIndex = items.firstIndex(of: item), existingIndex != index {
            items[existingIndex] = items[index]
        }
        items[index] = item
        store.setQuickLogItems(items)
    }

    private func moveQuickLogItem(from index: Int, by offset: Int) {
        let destination = index + offset
        guard (0..<6).contains(destination) else { return }
        var items = quickLogEditorItems
        items.swapAt(index, destination)
        store.setQuickLogItems(items)
    }

    private var moveTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel("Apple Fitness sync")
            VStack(alignment: .leading, spacing: 10) {
                Text("When enabled, Fernlet writes your logged workouts to Apple Health so they appear in the Fitness app, and pulls workouts logged elsewhere back into Fernlet.")
                    .font(.fernlet(.body))
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()

                // No internal milestone tag, and no permanently disabled button pretending to be an
                // action: this says what is true today and where the working control lives.
                VStack(alignment: .leading, spacing: 4) {
                    Text("Not ready yet")
                        .font(.fernlet(.labelSmall))
                        .foregroundStyle(Color.slate)
                    Text("This isn't switched on yet. Workouts you log already sync to Apple Health when you allow it under Health.")
                        .font(.fernlet(.body))
                        .foregroundStyle(Color.bark)
                        .fernletWrappingText()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private var memoriesTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit or remove the notes Fernlet keeps from journals, plus the local trends it is inferring.")
                .font(.fernlet(.body))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()

            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.subheadline)
                    .foregroundStyle(Color.slate)
                TextField("Search or type \"forget [keyword]\"", text: $memorySearch)
                    .font(.fernlet(.body))
                    .autocorrectionDisabled()
                if !memorySearch.isEmpty {
                    Button { memorySearch = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Color.slate)
                    }
                    .buttonStyle(.plain)
                    .fernletIconButton("Clear search")
                }
            }
            .padding(12)
            .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))

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
                    // `verbatim:` — `key` is a persisted `MemoryNote.category` token being used as
                    // a grouping heading, not authored copy. Rendering the token is a pre-existing
                    // defect; `verbatim:` makes it honest rather than pretending it localizes.
                    SectionLabel(verbatim: key)
                    ForEach(groups[key] ?? []) { memory in
                        memoryRow(memory)
                    }
                }
            }
        }
        .sheet(item: $editingMemory) { memory in
            MemoryEditorSheet(store: store, memory: memory)
                // Full height, not .medium: the character counter, the source date and Delete all
                // sat below the fold of the half sheet.
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(20)
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
        return store.memories.filter {
            $0.text.localizedCaseInsensitiveContains(needle) ||
            $0.category.localizedCaseInsensitiveContains(needle)
        }
    }

    @ViewBuilder private func forgetShellView(keyword: String) -> some View {
        let matches = store.memories.filter {
            $0.text.localizedCaseInsensitiveContains(keyword) ||
            $0.category.localizedCaseInsensitiveContains(keyword)
        }
        if matches.isEmpty {
            FernletCard { EmptyState(text: "No memories match \"\(keyword)\".") }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("Forget \(matches.count) memor\(matches.count == 1 ? "y" : "ies") matching \"\(keyword)\"?")
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
            .background(Color.terracotta.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private var signalsTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Local trends Fernlet is inferring from journals, meals, sleep, and workouts.")
                .font(.fernlet(.body))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()
            if store.derivedSignals.isEmpty {
                FernletCard { EmptyState(text: "More logs will make trends useful.") }
            } else {
                ForEach(store.derivedSignals) { signal in
                    SignalDetailRow(signal: signal)
                }
            }
        }
    }

    private var sleepTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Last sleep logged for today.")
                .font(.fernlet(.body))
                .foregroundStyle(Color.slate)
            FernletCard {
                if let sleep = store.day.sleep {
                    HStack {
                        Circle().fill(sleep.quality == .poor ? Color.terracotta : Color.moss).frame(width: 10, height: 10)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(sleep.quality.label).font(.fernlet(.header)).foregroundStyle(Color.bark)
                            Text(sleep.hours.map { "\($0, specifier: "%.1f") hours" } ?? "Hours not logged")
                                .font(.fernlet(.stat)).foregroundStyle(Color.slate)
                        }
                        Spacer()
                    }
                } else {
                    EmptyState(text: "No sleep logged yet.")
                }
            }
        }
    }

    private var healthTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Fernlet asks for Health access only when a feature needs it, and you can say no to any of them.")
                .font(.fernlet(.body))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()

            // `snapshot.isAvailable` folds "no Health store on this hardware" and "master toggle
            // off" into one false — and the toggle defaults to off, so a single branch here told
            // every fresh install their device can't do Health. Triage the real cause instead.
            switch healthKit.availabilityState {
            case .deviceUnavailable:
                FernletCard { EmptyState(text: "Health data is not available on this device.", systemImage: "heart.slash") }
            case .integrationOff:
                healthIntegrationOffCard
            case .available:
                ForEach(store.visibleHealthCapabilities) { capability in
                    healthCapabilityRow(capability)
                }
            }

            // The cards above already explain both unavailable states; repeating the service's own
            // copy of that sentence underneath them read as a glitch.
            if !healthKit.statusMessage.isEmpty && healthKit.availabilityState == .available {
                Text(healthKit.statusMessage)
                    .font(.fernlet(.bodySmall))
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()
            }
        }
    }

    /// The integration-off state: the device can do Health, but the master toggle is off — where
    /// every fresh install starts, since the toggle defaults to off. Names the real cause and
    /// routes to Privacy & Data through the same value-based `.privacyData` destination the hub
    /// links push; the toggle itself stays on that screen with its consent copy and audit logging.
    private var healthIntegrationOffCard: some View {
        FernletCard {
            VStack(spacing: 12) {
                EmptyState(text: "Health is switched off for Fernlet.", systemImage: "heart.slash")
                NavigationLink(value: SettingsRoute.privacyData) {
                    Label("Turn on Health in Privacy & Data", systemImage: "heart.text.square")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .font(.fernlet(.label))
                .foregroundStyle(Color.onMoss)
                .padding(.vertical, 11)
                .background(Color.mossFill, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private func healthCapabilityRow(_ capability: HealthCapability) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: healthIcon(for: capability))
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(Color.moss)
                    .frame(width: 34, height: 34)
                    .background(Color.moss.opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 4) {
                    Text(capability.title)
                        .font(.fernlet(.header))
                        .foregroundStyle(Color.bark)
                    Text(capability.summary)
                        .font(.fernlet(.bodySmall))
                        .foregroundStyle(Color.slate)
                        .fernletWrappingText()
                    Text(writeStatusSummary(for: capability))
                        .font(.fernlet(.labelSmall))
                        .foregroundStyle(Color.slate)
                }
                Spacer(minLength: 8)
            }

            Button {
                handleHealthPrimaryAction(for: capability)
            } label: {
                Label(healthActionTitle(for: capability), systemImage: healthActionSystemImage(for: capability))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .font(.fernlet(.label))
            .foregroundStyle(Color.onMoss)
            .padding(.vertical, 11)
            .background(Color.mossFill, in: RoundedRectangle(cornerRadius: 12))
            .disabled(healthKit.isRequesting)
            .opacity(healthKit.isRequesting ? 0.55 : 1)

            if canShowRevokeAccess(for: capability) {
                Button {
                    openHealthPermissionSettings(for: capability)
                } label: {
                    Label("Revoke access", systemImage: "xmark.shield")
                }
                .buttonStyle(DestructiveCardButtonStyle())
            }
        }
        .padding(14)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))
    }

    private func writeStatusSummary(for capability: HealthCapability) -> String {
        let statuses = HealthAuthorizationPresentation.writeTypeIdentifiers(for: capability).compactMap { identifier in
            healthKit.snapshot.status(for: identifier)?.fernletLabel
        }
        if statuses.isEmpty { return "Read-only access requested when enabled." }
        let unique = Array(Set(statuses)).sorted()
        return "Write status: \(unique.joined(separator: ", "))"
    }

    private func hasWritableAccess(for capability: HealthCapability) -> Bool {
        HealthAuthorizationPresentation.writeTypeIdentifiers(for: capability).contains { identifier in
            healthKit.snapshot.status(for: identifier) == .sharingAuthorized
        }
    }

    private func hasAccessActionCompleted(for capability: HealthCapability) -> Bool {
        hasWritableAccess(for: capability) || healthKit.hasRequested(capability)
    }

    private func canShowRevokeAccess(for capability: HealthCapability) -> Bool {
        hasAccessActionCompleted(for: capability)
    }

    private func healthActionTitle(for capability: HealthCapability) -> String {
        hasAccessActionCompleted(for: capability) ? "Update data" : "Give access"
    }

    private func healthActionSystemImage(for capability: HealthCapability) -> String {
        hasAccessActionCompleted(for: capability) ? "arrow.clockwise" : "heart.text.square"
    }

    private func handleHealthPrimaryAction(for capability: HealthCapability) {
        guard canUseHealthCapability(capability) else { return }
        if hasAccessActionCompleted(for: capability) {
            updateHealthData(for: capability)
            return
        }

        switch capability {
        case .bodyProfile:
            Task {
                if let profile = await healthKit.importBodyProfile(current: store.settings.userProfile) {
                    store.settings.userProfile = profile
                    store.scheduleSnapshotSave()
                }
            }
        case .cycleTracking, .bodyContext, .workoutLogging, .activityContext, .mindfulness, .intimateLogging:
            Task {
                await healthKit.request(capability)
                if let context = await healthKit.updateHealthContext(for: capability) {
                    store.updateHealthContext(context)
                }
            }
        }
    }

    private func canUseHealthCapability(_ capability: HealthCapability) -> Bool {
        // Age first: it has its own explanatory message, and "you're under 18" must not be reported as
        // "you turned this off".
        guard capability != .intimateLogging || store.isIntimateLoggingAllowed else {
            healthKit.showIntimateLoggingAgeWallMessage()
            return false
        }
        // Defense in depth against the read this action performs. `visibleHealthCapabilities` already
        // withholds the row, so this should be unreachable from the UI — but the action reads HealthKit
        // and writes straight back into the day's health context, which is precisely the hole the
        // visibility gate exists to close. Re-check at the point of use, not just the point of display.
        // Visibility only, deliberately not lock state: the ambient paths already drop cycle reads while
        // locked via `allowedHealthCapabilities`, and refusing this explicit, user-initiated action on
        // lock state would be an unrelated behavior change that fails silently.
        switch capability {
        case .cycleTracking: return store.isPeriodTrackingVisible
        case .intimateLogging: return store.isIntimacyTrackingVisible
        default: return true
        }
    }

    private func updateHealthData(for capability: HealthCapability) {
        guard canUseHealthCapability(capability) else { return }
        switch capability {
        case .bodyProfile:
            Task {
                if let profile = await healthKit.updateBodyProfile(current: store.settings.userProfile) {
                    store.settings.userProfile = profile
                    store.scheduleSnapshotSave()
                }
            }
        case .bodyContext, .workoutLogging, .cycleTracking, .activityContext, .mindfulness, .intimateLogging:
            Task {
                if let context = await healthKit.updateHealthContext(for: capability) {
                    store.updateHealthContext(context)
                }
            }
        }
    }

    private func openHealthPermissionSettings(for capability: HealthCapability) {
        healthKit.showRevocationInstructions(for: capability)
        #if canImport(UIKit)
        if let url = URL(string: UIApplication.openSettingsURLString) {
            openURL(url)
        }
        #endif
    }

    private func healthIcon(for capability: HealthCapability) -> String {
        switch capability {
        case .bodyProfile: "person.text.rectangle"
        case .cycleTracking: "calendar.badge.clock"
        case .bodyContext: "waveform.path.ecg"
        case .workoutLogging: "figure.run"
        case .activityContext: "figure.walk"
        case .mindfulness: "figure.mind.and.body"
        case .intimateLogging: "lock.shield"
        }
    }

    /// Shown under the goal cards when the user has pinned nutrition targets or an explicit training
    /// split: a preset only sets the *goal*, so those custom choices quietly win over the goal's plan.
    /// nil when nothing is pinned (the goal's own summaries then describe the plan in effect).
    private var goalOverrideFootnote: String? {
        var pieces: [String] = []
        if store.settings.hasAnyNutritionOverride { pieces.append("custom nutrition targets") }
        if store.settings.workoutProfile.selectedSplitID != nil { pieces.append("chosen training split") }
        guard !pieces.isEmpty else { return nil }
        let list = pieces.count == 2 ? "\(pieces[0]) and \(pieces[1])" : pieces[0]
        return "Your \(list) stay as you set them — clear them to follow this goal's plan."
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

    private var healthSyncedProfileBinding: Binding<UserNutritionProfile> {
        Binding(
            get: { store.settings.userProfile },
            set: { profile in
                store.settings.userProfile = profile
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

    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            goalSection
            bodyAndPreferencesSection
            aiSection
            coachSection
            bodySignalsSection
            remindersSection
            hydrationSection
            personalCareSettings
        }
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
            set: { store.setSelectedGoal($0) }
        ))
        if let note = goalOverrideFootnote {
            Text(note)
                .font(.fernlet(.bodySmall))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()
        }
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Sick mode", isOn: Binding(
                get: { store.isSick(on: store.todayKey) },
                set: { store.setSick($0, on: store.todayKey) }
            ))
            Toggle("Show calories", isOn: settingsBinding(\.showCalories))
        }
        .padding(14)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))
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

    /// The AI switches: manual off, web nutrition lookup, weather-aware prompts, and the voice line
    /// reflecting today's EFFECTIVE status.
    @ViewBuilder
    private var aiSection: some View {
        SectionLabel("AI")
        VStack(alignment: .leading, spacing: 10) {
            // A positive switch: ON means the helper is available. "Manual off mode" was a double
            // negative — a green switch meant the AI was off — while every other switch in this
            // card reads the normal way round.
            Toggle("On-device AI helper", isOn: aiEnabledBinding)
            HStack {
                Text("Today")
                    .font(.fernlet(.label))
                    .foregroundStyle(Color.slate)
                Spacer()
                Text(store.effectiveAIStatus.label)
                    .font(.fernlet(.label))
                    .foregroundStyle(Color.bark)
            }
            Divider().overlay(Color.bark.opacity(0.08))
            Toggle("Web nutrition lookup", isOn: settingsBinding(\.webNutritionLookupEnabled))
                .disabled(store.settings.aiStatus == .off)
            Text("Fernlet can search the web for chain and packaged-food nutrition. Your meal description is sent to a search provider only when this is on.")
                .font(.fernlet(.bodySmall))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()
            Divider().overlay(Color.bark.opacity(0.08))
            Toggle("Weather-aware recovery prompts", isOn: Binding(
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
            ))
            Text("On heavy, gloomy days Fernlet can offer a gentle recovery nudge. Uses your approximate location for weather only, never stored or shared.")
                .font(.fernlet(.bodySmall))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()
            Text(FernletVoice.message(for: aiStatusVoiceLine))
                .font(.fernlet(.bubble))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()
        }
        .padding(14)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))
    }

    /// Reflects the EFFECTIVE status (intent overlaid with today's local budget): off shows the
    /// switched-off copy, a spent budget (`.sleepy`/`.resting`) the resting copy, otherwise the
    /// gentle retry note.
    private var aiStatusVoiceLine: FernletVoice {
        switch store.effectiveAIStatus {
        case .off: return .aiUnavailable
        case .sleepy, .resting: return .aiResting
        case .ready: return .retryAvailable
        }
    }

    /// The manual coach plan exchange, its two honesty disclosures, and what trainer summaries carry.
    @ViewBuilder
    private var coachSection: some View {
        SectionLabel("Coach")
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Manual plan exchange", isOn: settingsBinding(\.coachExchangeEnabled))
            Text("Adds two things to \"Share with a trainer\" on the Move tab: copying your training summary as text so you can paste it to an AI assistant, and pasting a workout plan back in.")
                .font(.fernlet(.bodySmall))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()
            // Said plainly and unprompted. A pasted plan carries no signature, so the review
            // screen is the only thing standing between it and the user's week — and the copy
            // step puts plaintext health data into another app's hands by design.
            Text("Copied text leaves Fernlet the moment you paste it elsewhere, and a pasted plan isn't from a verified coach — Fernlet shows you every day of it before adding anything. This is an early feature; sharing in person with the Fernlet Coach app will replace the copying.")
                .font(.fernlet(.bodySmall))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()
            Divider().overlay(Color.bark.opacity(0.08))
            Text("Also include in trainer summaries")
                .font(.fernlet(.label))
                .foregroundStyle(Color.slate)
            Toggle("Your goal", isOn: settingsBinding(\.trainerExportIncludesGoal))
            Toggle("Hydration", isOn: settingsBinding(\.trainerExportIncludesHydration))
            Toggle("Sleep summaries", isOn: settingsBinding(\.trainerExportIncludesSleep))
            Toggle("Days you were unwell", isOn: settingsBinding(\.trainerExportIncludesSickness))
            Toggle("Wellbeing score", isOn: settingsBinding(\.trainerExportIncludesWellbeing))
            Text("These choices apply when you use Share on the Move tab.")
                .font(.fernlet(.bodySmall))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()
        }
        .padding(14)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))
    }

    /// The body-tension opt-in, its two plain-language disclosures, and the Health-needed note.
    @ViewBuilder
    private var bodySignalsSection: some View {
        SectionLabel("Body signals")
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Notice body tension", isOn: stressAwarenessBinding)
            Text("When this is on, Fernlet gently compares your heart rate variability, resting heart rate, respiration, and sleeping wrist temperature from Apple Health with your own usual range — never anyone else's — and may quietly note when your body seems a bit more tense than usual. Estimated and stored on this device only.")
                .font(.fernlet(.bodySmall))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()
            Text("This is a wellbeing reflection, not medical advice. If you're worried about how you feel, please talk to a health professional.")
                .font(.fernlet(.bodySmall))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()
            if store.settings.stressAwarenessEnabled && !storagePreferencesStore.preferences.healthKitMasterEnabled {
                Text("Body signals needs Apple Health. Turn on Health integration in Privacy & Data to feed it.")
                    .font(.fernlet(.bodySmall))
                    .foregroundStyle(Color.terracotta)
                    .fernletWrappingText()
            }
        }
        .padding(14)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))
    }

    /// The daily check-in reminder. Keeps its own `.task` mirror of the pending notification request
    /// and the reschedule-on-time-change handler.
    @ViewBuilder
    private var remindersSection: some View {
        SectionLabel("Reminders")
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Daily check-in", isOn: dailyCheckInBinding)
            if dailyCheckInEnabled {
                DatePicker("Time", selection: $dailyCheckInTime, displayedComponents: .hourAndMinute)
            }
            Text("One gentle nudge a day — however the day went, a small note of care still counts. Change or turn it off any time.")
                .font(.fernlet(.bodySmall))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()
            if dailyCheckInAuthDenied {
                Text("Notifications are off for Fernlet in iOS Settings — allow them there and this toggle will work.")
                    .font(.fernlet(.bodySmall))
                    .foregroundStyle(Color.terracotta)
                    .fernletWrappingText()
            }
        }
        .padding(14)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))
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

    /// Bottle size and the daily bottle target.
    @ViewBuilder
    private var hydrationSection: some View {
        SectionLabel("Hydration")
        VStack(alignment: .leading, spacing: 10) {
            Stepper("Bottle: \(store.settings.bottleOz) oz", value: settingsBinding(\.bottleOz), in: 4...64)
                .font(.fernlet(.label))
            Divider().overlay(Color.bark.opacity(0.08))
            Stepper("Daily target: \(store.settings.hydrationTarget) bottles", value: settingsBinding(\.hydrationTarget), in: 1...30)
                .font(.fernlet(.label))
        }
        .padding(14)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))
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
            title: "Remove \(task.label)?",
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
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Personal care tasks")
            newCareTaskEditor
            ForEach(PersonalCareTask.groupCases) { group in
                careTaskGroupList(group)
            }
        }
    }

    /// The add-a-task composer: label field (length-capped), group chips, the Add button, and the
    /// at-capacity note.
    private var newCareTaskEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Moisturizer, meds, stretch...", text: $newCareTaskName)
                .sheetTextInput()
                // R3: cap the free-text label where it enters. The persisted settings array is
                // synced, so an unbounded label is unbounded growth in the snapshot.
                .onChange(of: newCareTaskName) { _, newValue in
                    if newValue.count > Self.maxCareTaskLabelLength {
                        newCareTaskName = String(newValue.prefix(Self.maxCareTaskLabelLength))
                    }
                }
            FlowLayout(spacing: 8) {
                // The chip SHOWS `group.label` but STORES `group.token`. Showing and storing the
                // same string is precisely the bug ``CareGroup`` exists to prevent: the stored value
                // is the filter predicate and rides the synced settings blob.
                ForEach(PersonalCareTask.groupCases) { group in
                    Button { newCareTaskGroup = group.token } label: {
                        Text(verbatim: group.label)
                    }
                    .buttonStyle(ChipButtonStyle(selected: newCareTaskGroup == group.token))
                }
            }
            Button {
                addPersonalCareTask()
            } label: {
                Label("Add task", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .font(.fernlet(.label))
            // Full-strength ink on a faded fill for the disabled state: fading the label too made
            // it unreadable, so the user couldn't tell what completing the field would do.
            .foregroundStyle(isAddCareTaskDisabled ? Color.bark : Color.onMoss)
            .padding(.vertical, 11)
            .background(
                Color.mossFill.opacity(isAddCareTaskDisabled ? 0.55 : 1),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .disabled(isAddCareTaskDisabled)
            if store.personalCareTasks.count >= Self.maxCustomCareTasks {
                Text("That's the most personal care tasks Fernlet keeps (\(Self.maxCustomCareTasks)). Remove one to add another.")
                    .font(.fernlet(.bodySmall))
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()
                    .accessibilityIdentifier("settings.care.limitReached")
            }
        }
        .padding(14)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))
    }

    /// One group's saved tasks, each with its remove button. Renders nothing for an empty group.
    @ViewBuilder
    private func careTaskGroupList(_ group: CareGroup) -> some View {
        let tasks = store.personalCareTasks.filter { $0.careGroup == group }
        if !tasks.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: group.label)
                    .font(.fernlet(.labelSmall))
                    .foregroundStyle(Color.slate)
                ForEach(tasks) { task in
                    HStack(spacing: 10) {
                        Label(task.displayLabel, systemImage: task.systemImage)
                            .font(.fernlet(.label))
                            .foregroundStyle(Color.bark)
                        Spacer()
                        Button { confirmRemoveCareTask(task) } label: {
                            Image(systemName: "minus.circle")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(Color.terracottaInk)
                                .frame(width: 32, height: 32)
                        }
                        .buttonStyle(.plain)
                        .fernletIconButton("Remove \(task.label)")
                    }
                    .padding(12)
                    .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
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
        }
    }

    /// The Friends-tab debug switch and what turning it on actually exposes.
    private var proximityDebugSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Friends tab")
            Toggle(
                "Proximity debug tools",
                isOn: Binding(
                    get: { store.settings.showProximityDebugTools },
                    set: { store.setShowProximityDebugTools($0) }
                )
            )
            Text("Shows the connection inspector button and a Force override on the Friends tab that bypasses distance requirements.")
                .font(.fernlet(.bodySmall))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()
        }
    }

    /// The tier-2 memory inspector. Loads post-render via its own `.task`: the repository decodes the
    /// whole database for this read, which is far too slow for a NavigationStack push's first body
    /// pass.
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
        // the whole-database decode never blocks the navigation animation.
        .task {
            guard debugTierTwoMemories == nil else { return }
            debugTierTwoMemories = store.tierTwoMemories
        }
    }

    private func tierTwoMemoryRow(_ record: TierTwoMemoryRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(record.category.uppercased())
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
                Text(signal.signalName)
                    .font(.fernlet(.labelSmall))
                    .foregroundStyle(Color.slate)
                Spacer()
                Text(signal.value.capitalized)
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
        }
    }

    private var connectionInspectorModeDescription: String {
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
    /// reveal named no data and stated no consequences. Both are now the shared dialog over the single
    /// `deleteAllData` funnel.
    private var resetSection: some View {
        // The same terracotta text + trash row App lock's danger zone uses, rather than a third
        // destructive style (system red here, terracotta there, a filled button in Privacy & Data).
        Button(role: .destructive) {
            pendingDestructiveAction = deleteFlow.makeConfirmation(
                preferences: storagePreferencesStore.preferences,
                store: store
            )
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "trash")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.terracottaInk)
                    .frame(width: 28)
                Text("Delete everything")
                    .font(.fernlet(.label))
                    .foregroundStyle(Color.terracottaInk)
                Spacer()
            }
            // `.buttonStyle(.plain)` hit-tests the drawn content only, so without this the row's
            // trailing `Spacer()` — which is where the centre of the row is — swallowed the tap and
            // the confirm dialog never opened.
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(deleteFlow.isDeleting)
        .accessibilityIdentifier("settings.deleteAll")
    }

    /// Raises the shared destructive confirmation for one core memory. Nothing is removed until the
    /// user confirms — the mutation lives only inside `perform`.
    private func confirmDeleteMemory(_ memory: MemoryNote) {
        pendingDestructiveAction = DestructiveConfirmation(
            title: "Delete this memory?",
            message: "\"\(memory.text)\"\n\nFernlet forgets it for good. Your journal entry stays.",
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

    private func memoryRow(_ memory: MemoryNote) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(memory.text)
                    .font(.fernlet(.body))
                    .foregroundStyle(Color.bark)
                    .fernletWrappingText()
                Text(memory.sourceDate.formatted(.dateTime.month(.abbreviated).day().year()))
                    .font(.fernlet(.labelSmall))
                    .foregroundStyle(Color.slate)
            }
            Spacer()
            Button { editingMemory = memory } label: {
                Image(systemName: "pencil")
                    .foregroundStyle(Color.slate)
                    .frame(width: 34, height: 34)
                    .background(Color.bark.opacity(0.05), in: Circle())
            }
            .buttonStyle(.plain)
            .fernletIconButton("Edit memory")
            // A memory is saved user data, so removing it is confirmed like every other delete —
            // it used to vanish on one tap with no undo.
            Button { confirmDeleteMemory(memory) } label: {
                Image(systemName: "xmark")
                    .foregroundStyle(Color.slate)
                    .frame(width: 34, height: 34)
                    .background(Color.bark.opacity(0.05), in: Circle())
            }
            .buttonStyle(.plain)
            .fernletIconButton("Delete memory")
        }
        .padding(14)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))
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
            Text("Core memory")
                .font(.fernlet(.displayMedium))
                .foregroundStyle(Color.bark)

            // Chips, not free text: the list groups memories by category, and a free
            // TextField let one memory land in a category of its own by a typo.
            SheetField("Category") {
                FlowLayout(spacing: 8) {
                    ForEach(categoryChoices, id: \.self) { choice in
                        Button(choice.capitalized) { category = choice }
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

            VStack(alignment: .leading, spacing: 8) {
                Text("Source date")
                    .font(.fernlet(.labelSmall))
                    .foregroundStyle(Color.slate)
                Text(memory.sourceDate.formatted(.dateTime.month(.wide).day().year()))
                    .font(.fernlet(.stat))
                    .foregroundStyle(Color.bark)
            }
            .padding(14)
            .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))

            deleteSection
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
        .background(Color.parchment)
        // The drag handle was the only way out — every sibling entry sheet offers a Cancel, and a
        // dirty draft now asks before it is thrown away.
        .fernletDraftGuard(isDirty: category != memory.category || text != memory.text) { dismiss() }
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
/// lock is configured, so reaching this page requires an unlock). All state lives in the
/// environment's `FernletLockService`; when no lock is configured the page shows only a setup CTA
/// presenting `FernletLockSetupView`. Enabling biometrics requires re-entering the current passcode
/// (via the inline verify sheet); disabling does not. Resetting the lock is confirmed with an
/// explicit warning that the sealed journal, cycle, and intimacy notes become permanently
/// unreadable — the reset destroys the keys, not just the passcode.
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

    @State private var showSetup = false
    @State private var showChangePasscode = false
    @State private var showResetConfirm = false
    /// Presents the nothing-silent alert when the reset destroyed the keys and the rows but could
    /// not rebuild the sealed store file (it used to be swallowed by a `try?`).
    @State private var showResetRebuildFailure = false
    @State private var showBiometricPasscodeVerify = false
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
                .background(Color.parchment)
                .navigationTitle("App lock")
                .sheet(isPresented: $showSetup) {
                    FernletLockSetupView(grantingScope: .appLockSettings)
                        .environment(lockService)
                }
                .sheet(isPresented: $showChangePasscode) {
                    FernletLockChangePasscodeView()
                        .environment(lockService)
                }
                .sheet(isPresented: $showBiometricPasscodeVerify) {
                    biometricVerifySheet
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
            VStack(alignment: .leading, spacing: 20) {
                statusCard

                if lockService.state != .notConfigured {
                    actionsCard
                    biometricCard
                    duressCard
                    dangerCard
                } else {
                    setupCTACard
                    duressCard
                }
            }
            .padding(20)
            .padding(.bottom, 20)
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
                Text("Private journal, cycle, and intimacy notes will become permanently unreadable. HealthKit cycle and intimacy entries remain in Apple Health.")
            }
            .alert("App lock reset", isPresented: $showResetRebuildFailure) {
                Button("OK", role: .cancel) { dismiss() }
            } message: {
                Text("Your app lock and its notes were destroyed, but the sealed store could not be rebuilt. Please relaunch Fernlet.")
            }
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
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 3) {
                    Text(statusLabel)
                        .font(.fernlet(.header))
                        .foregroundStyle(Color.bark)
                    if let kind = lockService.credentialKind {
                        Text(kindLabel(kind))
                            .font(.fernlet(.labelSmall))
                            .foregroundStyle(Color.slate)
                    }
                }
                Spacer()
            }
        }
        .padding(14)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))
    }

    private var actionsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Manage")

            Button {
                showChangePasscode = true
            } label: {
                settingsRow(icon: "key.fill", title: "Change passcode")
            }

            FernletRowDivider()

            // No chevron: this acts here and now, it doesn't navigate anywhere.
            Button {
                lockService.lock(reason: .manual)
            } label: {
                settingsRow(icon: "lock.fill", title: "Lock now", showsChevron: false)
            }

            FernletRowDivider()

            // Moved here from Privacy & Data, where it sat under an "App lock data" header above
            // the Delete everything button and described neither.
            Text("Fernlet protects your data with its own passcode, separate from your device passcode. Removing your device passcode won't affect your Fernlet app lock or erase your protected data.")
                .font(.fernlet(.bodySmall))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))
    }

    private var biometricCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            // `verbatim:` on the merits as well as for the type: "Face ID" and "Touch ID" are
            // Apple product names that Apple itself ships untranslated in most locales.
            SectionLabel(verbatim: biometricName(lockService.biometricType))

            if lockService.biometricType != .none {
                Toggle(isOn: biometricToggleBinding) {
                    settingsRow(
                        icon: biometricSystemImage(lockService.biometricType),
                        title: "Use \(biometricName(lockService.biometricType))"
                    )
                }
                .toggleStyle(SwitchToggleStyle(tint: Color.moss))
                // The toggle re-reads `lockService.biometricEnabled`, so a failed disable would
                // otherwise just snap the switch back with no explanation.
                if let biometricDisableError {
                    Text(biometricDisableError)
                        .font(.fernlet(.bodySmall))
                        .foregroundStyle(Color.terracotta)
                        .fernletWrappingText()
                        .accessibilityIdentifier("applock.biometric.disableError")
                }
            } else {
                Text("No biometric authentication available on this device.")
                    .font(.fernlet(.body))
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()
            }
        }
        // Spans the column like Status and Manage above it; without this the card hugged its text.
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))
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
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Duress & recovery")

            if lockService.state != .notConfigured && !lockService.isDuressSessionActive {
                Button {
                    showDuressSetup = true
                } label: {
                    settingsRow(icon: "lock.shield", title: "Duress code")
                }
                .accessibilityIdentifier("appLock.duressCode")

                FernletRowDivider()
            }

            if lockService.hasRecoveryCustodian && !lockService.isDuressSessionActive {
                Button {
                    showRecoveryReturn = true
                } label: {
                    settingsRow(icon: "arrow.clockwise", title: "Recover this phone")
                }
                .accessibilityIdentifier("appLock.recoverThisPhone")

                FernletRowDivider()
            }

            Button {
                showRecoveryCustodian = true
            } label: {
                settingsRow(icon: "iphone.and.arrow.forward", title: "Be a recovery device")
            }
            .accessibilityIdentifier("appLock.beRecoveryDevice")
        }
        .padding(14)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))
    }

    private var dangerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Danger zone")
            Button(role: .destructive) {
                showResetConfirm = true
            } label: {
                settingsRow(icon: "trash", title: "Reset app lock", destructive: true)
            }
        }
        .padding(14)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))
    }

    private var setupCTACard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("App lock is not set up. Set a passcode to protect your journal, period, and intimacy history.")
                .font(.fernlet(.body))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()

            Button("Set up app lock") { showSetup = true }
                .buttonStyle(.plain)
                .font(.fernlet(.label))
                .foregroundStyle(Color.onMoss)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.mossFill, in: RoundedRectangle(cornerRadius: 14))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: Biometric verify sheet

    private var biometricVerifySheet: some View {
        NavigationStack {
            ZStack {
                Color.parchment.ignoresSafeArea()
                VStack(alignment: .leading, spacing: 20) {
                    Text("Enter your current passcode to \(pendingBiometricEnable ? "enable" : "disable") \(biometricName(lockService.biometricType)).")
                        .font(.fernlet(.body))
                        .foregroundStyle(Color.slate)
                        .fernletWrappingText()

                    if let err = verifyError {
                        Text(err)
                            .font(.fernlet(.body))
                            .foregroundStyle(Color.terracotta)
                    }

                    if lockService.credentialKind == .alphanumeric {
                        SecureField("Current password", text: $verifyCurrentPasscode)
                            .textContentType(.password)
                            .sheetTextInput()

                        Spacer()

                        Button("Confirm") { commitBiometricToggle() }
                            .buttonStyle(.plain)
                            .font(.fernlet(.label))
                            .foregroundStyle(Color.onMoss)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(
                                Color.mossFill.opacity(verifyCurrentPasscode.isEmpty ? 0.55 : 1),
                                in: RoundedRectangle(cornerRadius: 14)
                            )
                            .disabled(verifyCurrentPasscode.isEmpty)
                    } else {
                        // The lock gate's shape: dots in the upper third, keypad anchored above the
                        // safe area where the thumb is. Stacked from the top it left the bottom
                        // half of the sheet empty and the digits up by the nav bar.
                        let total = lockService.credentialKind == .pin4 ? 4 : 6
                        pinDotsRow(current: verifyCurrentPasscode, total: total)
                            .frame(maxWidth: .infinity)

                        Spacer(minLength: 12)

                        FernletNumericPad(value: $verifyCurrentPasscode, maxLength: total)
                            .onChange(of: verifyCurrentPasscode) { _, new in
                                if new.count == total { commitBiometricToggle() }
                            }
                    }
                }
                .padding(24)
            }
            .navigationTitle("Verify passcode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showBiometricPasscodeVerify = false
                        verifyCurrentPasscode = ""
                        verifyError = nil
                    }
                    .foregroundStyle(Color.slate)
                }
            }
        }
        .tint(Color.moss)
    }

    private func commitBiometricToggle() {
        Task { @MainActor in
            do {
                try await lockService.setBiometricEnabled(pendingBiometricEnable, passcode: verifyCurrentPasscode)
                showBiometricPasscodeVerify = false
                verifyCurrentPasscode = ""
                verifyError = nil
            } catch {
                verifyCurrentPasscode = ""
                verifyError = error.localizedDescription
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
                    showBiometricPasscodeVerify = true
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
            }
        }
    }

    private var statusLabel: String {
        switch lockService.state {
        case .notConfigured: return "Not configured"
        case .locked(let d):
            if let d { return "Locked (cooldown until \(d.formatted(.dateTime.hour().minute())))" }
            return lockService.requiresReset ? "Locked (reset required)" : "Locked"
        case .unlocked: return "Unlocked"
        }
    }

    private var statusColor: Color {
        switch lockService.state {
        case .notConfigured: Color.softTaupe
        case .locked: Color.terracotta
        case .unlocked: Color.moss
        }
    }

    private func kindLabel(_ kind: FernletLockCredentialKind) -> String {
        switch kind {
        case .pin4: "4-digit PIN"
        case .pin6: "6-digit PIN"
        case .alphanumeric: "Alphanumeric password"
        }
    }

    private func settingsRow(
        icon: String,
        title: String,
        destructive: Bool = false,
        showsChevron: Bool = true
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(destructive ? Color.terracottaInk : Color.moss)
                .frame(width: 28)
            Text(title)
                .font(.fernlet(.label))
                .foregroundStyle(destructive ? Color.terracottaInk : Color.bark)
            Spacer()
            if !destructive && showsChevron {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.slate.opacity(0.5))
            }
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
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
                Color.parchment.ignoresSafeArea()
                stepContent.padding(24)
            }
            .navigationTitle("Change passcode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Color.slate)
                }
            }
        }
        .tint(Color.moss)
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
                SecureField("Current password", text: $currentPasscode)
                    .textContentType(.password)
                    .sheetTextInput()
                Spacer()
                continueButton { advanceFromVerifyOld() }
            } else {
                let total = oldKind == .pin4 ? 4 : 6
                pinDotsRow(current: currentPasscode, total: total)
                    .frame(maxWidth: .infinity)
                Spacer(minLength: 12)
                FernletNumericPad(value: $currentPasscode, maxLength: total)
                    .onChange(of: currentPasscode) { _, new in
                        if new.count == total { advanceFromVerifyOld() }
                    }
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
                errorMessage = error.localizedDescription
            }
        }
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
                SecureField("New password", text: $newPasscode)
                    .textContentType(.newPassword)
                    .sheetTextInput()
                Spacer()
                continueButton(disabled: newPasscode.count < 8) { step = .confirmNew }
            } else {
                let total = selectedKind == .pin4 ? 4 : 6
                pinDotsRow(current: newPasscode, total: total)
                    .frame(maxWidth: .infinity)
                Spacer(minLength: 12)
                FernletNumericPad(value: $newPasscode, maxLength: total)
                    .onChange(of: newPasscode) { _, new in
                        if new.count == total { step = .confirmNew }
                    }
            }
        }
        .onChange(of: selectedKind) { _, _ in newPasscode = "" }
    }

    private func changeKindCard(_ kind: FernletLockCredentialKind, title: String) -> some View {
        Button { selectedKind = kind } label: {
            HStack(spacing: 14) {
                Image(systemName: kind == selectedKind ? "checkmark.circle.fill" : "circle")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(kind == selectedKind ? Color.moss : Color.slate.opacity(0.4))
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
        .buttonStyle(.plain)
    }

    // Confirm new passcode
    private var confirmNewStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            SectionLabel("Confirm new passcode")
            if let msg = errorMessage { errorBanner(msg) }
            if selectedKind == .alphanumeric {
                SecureField("Confirm new password", text: $confirmPasscode)
                    .textContentType(.newPassword)
                    .sheetTextInput()
                Spacer()
                continueButton(disabled: confirmPasscode.isEmpty) { commitChange() }
            } else {
                let total = selectedKind == .pin4 ? 4 : 6
                pinDotsRow(current: confirmPasscode, total: total)
                    .frame(maxWidth: .infinity)
                Spacer(minLength: 12)
                FernletNumericPad(value: $confirmPasscode, maxLength: total)
                    .onChange(of: confirmPasscode) { _, new in
                        if new.count == total { commitChange() }
                    }
            }
        }
    }

    private func commitChange() {
        guard newPasscode == confirmPasscode else {
            confirmPasscode = ""
            errorMessage = "Passcodes don't match. Try again."
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
                dismiss()
            } catch {
                confirmPasscode = ""
                errorMessage = error.localizedDescription
            }
        }
    }

    private func continueButton(disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button("Continue", action: action)
            .buttonStyle(.plain)
            .font(.fernlet(.label))
            // Disabled fades the fill only: moss-at-40% under white ink measured 1.8:1, so the
            // label the user is working towards was unreadable.
            .foregroundStyle(disabled ? Color.bark : Color.onMoss)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Color.mossFill.opacity(disabled ? 0.55 : 1), in: RoundedRectangle(cornerRadius: 14))
            .disabled(disabled)
    }

    private func errorBanner(_ msg: String) -> some View {
        Text(msg)
            .font(.fernlet(.body))
            .foregroundStyle(Color.terracotta)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.terracotta.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    /// The three sequential screens of the change-passcode flow.
    ///
    /// Strictly forward: `verifyOld` gates entry, `enterNew` collects the replacement, `confirmNew`
    /// re-enters it and commits; a mismatch or service error resets the offending field in place.
    private enum ChangeStep { case verifyOld, enterNew, confirmNew }
}

// MARK: - Shared pin dots row helper (used in SettingsSheet-internal views)

private func pinDotsRow(current: String, total: Int) -> some View {
    HStack(spacing: 16) {
        ForEach(0..<total, id: \.self) { index in
            Circle()
                .fill(index < current.count ? Color.bark : Color.clear)
                .frame(width: 14, height: 14)
                .overlay(Circle().stroke(Color.bark.opacity(0.35), lineWidth: 1.5))
        }
    }
}
