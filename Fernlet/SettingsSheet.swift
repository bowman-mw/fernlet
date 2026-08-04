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
/// ``AppLockSettingsView``) return with their own chrome. A non-empty search query swaps the Form
/// for a ``SettingsSearchIndex`` results list.
///
/// Key collaborators: ``FernletStore`` (`@Bindable`, all setting mutations), `FernletLockService`
/// and `StoragePreferencesStore` from the environment, `HealthKitAuthorizationViewModel` for the
/// Health tab, and `NotificationService` for the daily check-in reminder (the pending notification
/// request is that feature's persistence — the local `@State` merely mirrors it per visit).
///
/// Invariants this view enforces:
/// - Nothing destructive happens silently: hiding period/intimacy tracking and "Delete everything"
///   route through ``DestructiveConfirmation`` / ``DeleteAllDataConfirmation``, and a wipe raises
///   `isDeletingEverything` to show ``DeletingEverythingOverlay``, disable the delete/Done buttons,
///   and block interactive dismissal so a second confirm can't interleave.
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
    @AppStorage("fernletDarkModeEnabled") private var isDarkModeEnabled = false
    @AppStorage(FernletThemeDefaults.customLightBackgroundKey) private var customLightBackgroundHex = FernletThemeDefaults.lightBackgroundHex
    @AppStorage(FernletThemeDefaults.customDarkBackgroundKey) private var customDarkBackgroundHex = FernletThemeDefaults.darkBackgroundHex
    /// Non-nil when a wipe came back incomplete — drives the failure alert. A silently half-finished
    /// delete is the exact failure mode this screen is being fixed for, so it gets a surface.
    @State private var deleteAllFailure: FernletStore.DeleteAllOutcome?
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
    /// True while a "delete everything" wipe runs — drives the busy overlay, disables the delete and Done
    /// buttons, and blocks interactive dismissal so a second confirm can't interleave a wipe.
    @State private var isDeletingEverything = false
    /// True after a clean wipe; its alert affirms success, then dismisses the sheet on OK.
    @State private var showDeleteSuccess = false
    /// Settings search query (item 10). Non-empty swaps the Form for a results List; the search bar
    /// lives on the stable `settingsContent` so it persists across that swap.
    @State private var settingsSearch = ""
    // Debug tab only: tier-2 records load post-render (repository decodes the whole DB per read).
    @State private var debugTierTwoMemories: [TierTwoMemoryRecord]?

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
                .safeAreaInset(edge: .bottom) {
                    doneBar
                }
        }
        .background(Color.parchment)
        .overlay {
            if isDeletingEverything {
                DeletingEverythingOverlay()
            }
        }
        // No swipe-to-dismiss mid-wipe: a wipe is multi-second and the sheet must not close (or re-run)
        // out from under it.
        .interactiveDismissDisabled(isDeletingEverything)
        .destructiveConfirmation($pendingDestructiveAction)
        .alert("Couldn't delete everything", isPresented: Binding(
            get: { deleteAllFailure != nil },
            set: { if !$0 { deleteAllFailure = nil } }
        ), presenting: deleteAllFailure) { _ in
            Button("OK", role: .cancel) { deleteAllFailure = nil }
        } message: { outcome in
            Text(DeleteAllDataConfirmation.failureMessage(for: outcome))
        }
        .alert("Everything deleted", isPresented: $showDeleteSuccess) {
            Button("Done") { dismiss() }
        } message: {
            Text("Fernlet removed everything it stored on this device.")
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
                            Text(entry.title)
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
        case .privacyPolicy:
            PrivacyPolicyView()
        case .safetyReporting:
            SafetyReportingView()
        case .appLock:
            AppLockSettingsView()
                .environment(lockService)
                .fernletLockGate(active: lockService.state != .notConfigured)
                .environment(lockService)
        }
    }

    private var settingsForm: some View {
        Form {
                Section {
                } header: {
                    Text("Your data stays local by default. iCloud sync and web nutrition lookup are off unless you turn them on.")
                        .font(.fernlet(.body))
                        .foregroundStyle(Color.slate)
                        .textCase(nil)
                        .fernletWrappingText()
                }
                .listSectionSeparator(.hidden)
                .listSectionSpacing(.compact)

                Section("General") {
                    NavigationLink("Appearance", value: SettingsRoute.appearance)
                    NavigationLink("Goal & nutrition", value: SettingsRoute.goalNutrition)
                    NavigationLink("Layout & shortcuts", value: SettingsRoute.layoutShortcuts)
                }
                .listRowBackground(Color.cream)

                Section("Wellness") {
                    NavigationLink("Health", value: SettingsRoute.health)
                    NavigationLink("Sleep", value: SettingsRoute.sleep)
                    NavigationLink("Move", value: SettingsRoute.move)
                        .accessibilityIdentifier("settings.move")
                }
                .listRowBackground(Color.cream)

                Section {
                    Toggle("Period tracking", isOn: periodTrackingVisibleBinding)
                        .accessibilityIdentifier("settings.period.visible")
                    // Cosmetic sub-options: these still read cycle data, so they only make sense —
                    // and are only offered — while the hard gate above is on.
                    if store.isPeriodTrackingVisible {
                        Toggle("Hide predictions", isOn: hidePredictionsBinding)
                        Toggle("Hide fertile window", isOn: hideFertileWindowBinding)
                        Toggle("Period-aware care", isOn: periodAwareScoringBinding)
                    }
                } header: {
                    Text("Period")
                } footer: {
                    if store.isPeriodTrackingVisible {
                        Text("When on, gentle cycle-phase trends can soften your daily score and surface a cycle chip and outlook on Home. Off by default, and only takes effect after a few cycles are logged.\n\nTurning off Period tracking hides every cycle surface and stops Fernlet reading your cycle data. Your entries are kept, not deleted.")
                    } else {
                        Text("Cycle surfaces are hidden and Fernlet isn't reading your cycle data. Your entries are kept — turn this back on any time to see them again. Entries in Apple Health stay there either way.")
                    }
                }
                .listRowBackground(Color.cream)

                Section {
                    if store.isIntimateLoggingAllowed {
                        Toggle("Intimacy tracking", isOn: intimacyTrackingVisibleBinding)
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
                    Text("Intimacy")
                } footer: {
                    if store.isIntimateLoggingAllowed {
                        Text(store.settings.intimacyTrackingVisible
                             ? "Private intimacy notes, sealed on this device. Turning this off hides the feature and stops Fernlet reading it. Your notes are kept, not deleted."
                             : "Intimacy surfaces are hidden and Fernlet isn't reading them. Your notes are kept — turn this back on any time. Entries in Apple Health stay there either way.")
                    }
                }
                .listRowBackground(Color.cream)

                Section("Advanced") {
                    NavigationLink("Core memory", value: SettingsRoute.coreMemory)
                    NavigationLink("Signals", value: SettingsRoute.signals)
                    NavigationLink("Debug", value: SettingsRoute.debug)
                    NavigationLink("Connection Inspector", value: SettingsRoute.connectionInspector)
                    NavigationLink("Connection History", value: SettingsRoute.connectionHistory)
                }
                .listRowBackground(Color.cream)

                Section {
                    NavigationLink("Privacy & Data", value: SettingsRoute.privacyData)
                    NavigationLink("Privacy Policy", value: SettingsRoute.privacyPolicy)
                    NavigationLink("Safety & reporting", value: SettingsRoute.safetyReporting)
                    NavigationLink("App lock", value: SettingsRoute.appLock)
                    Toggle(
                        "Allow nearby recipe shares",
                        isOn: Binding(
                            get: { store.settings.allowNearbyRecipeShares },
                            set: { store.setAllowNearbyRecipeShares($0) }
                        )
                    )
                    // Phase 3a: payload-layer control — the shop rides the friend session (no
                    // standalone radio), so this governs whether shop catalogs are shared at all.
                    Toggle(
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
                    Toggle(
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
                    // Away delivery (bitchat adoptions Increment 3): the one proximity feature
                    // that touches the network, so it carries its own explicit opt-in — separate
                    // from iCloud Sync (public dead-drop, not the synced store).
                    Toggle(
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
                    // Phase 4a: the standing presence radio — rotating pairwise tags only.
                    Toggle(
                        "Nearby friends presence",
                        isOn: Binding(
                            get: { store.settings.allowNearbyPresence },
                            set: { store.setAllowNearbyPresence($0) }
                        )
                    )
                    // Phase 4: share a fuzzy vibe (thriving/okay/struggling) + your avatar with kept
                    // friends when you meet in person. Never a number, goal, or cycle. Default off.
                    Toggle(
                        "Share your vibe with friends",
                        isOn: Binding(
                            get: { store.settings.allowNearbyFriendState },
                            set: { store.setAllowNearbyFriendState($0) }
                        )
                    )
                } header: {
                    Text("Privacy")
                } footer: {
                    Text("Nearby friends presence lets friends you've kept see when you're close by. Fernlet broadcasts only rotating tags that your friends' devices can recognize — never your name or a stable identifier — and only while the app is open and unlocked. Nearby hearts uses that same presence connection to send a friend a heart in person, so it needs Nearby Friends turned on. If you keep presence on but turn hearts off, friends can still see you're nearby, but any heart sent to you is quietly dropped.")
                }
                .alert("Turn on Nearby Friends?", isPresented: $offerPresenceForHearts) {
                    Button("Turn on") { store.setAllowNearbyPresence(true) }
                    Button("Not now", role: .cancel) {}
                } message: {
                    Text("Hearts are sent in person over Nearby Friends. Turn it on so you can see when friends are close by and send them a heart. Fernlet broadcasts only rotating tags your friends can recognize — never your name.")
                }
                .listRowBackground(Color.cream)

                Section("Danger zone") {
                    resetSection
                }
                .listRowBackground(Color.cream)
            }
            .scrollContentBackground(.hidden)
            .background(Color.parchment)
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
            Toggle("Dark mode", isOn: $isDarkModeEnabled)
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
                Text("Choose what appears on the main page and put the widgets in the order you want.")
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
            VStack(spacing: 4) {
                Button {
                    moveHomeWidget(from: index, by: -1)
                } label: {
                    Image(systemName: "chevron.up")
                        .frame(width: 28, height: 24)
                }
                .disabled(index == 0)

                Button {
                    moveHomeWidget(from: index, by: 1)
                } label: {
                    Image(systemName: "chevron.down")
                        .frame(width: 28, height: 24)
                }
                .disabled(index == store.settings.homeWidgets.count - 1)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.slate)

            Label(widget.title, systemImage: widget.systemImage)
                .font(.fernlet(.label))
                .foregroundStyle(Color.bark)

            Spacer(minLength: 4)

            Button {
                removeHomeWidget(widget)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(Color.slate)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(Color.parchment.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
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
                VStack(spacing: 4) {
                    Button {
                        moveQuickLogItem(from: index, by: -1)
                    } label: {
                        Image(systemName: "chevron.up")
                            .frame(width: 28, height: 24)
                    }
                    .disabled(index == 0)

                    Button {
                        moveQuickLogItem(from: index, by: 1)
                    } label: {
                        Image(systemName: "chevron.down")
                            .frame(width: 28, height: 24)
                    }
                    .disabled(index == 5)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.slate)

                Label("Slot \(index + 1): \(currentItem.title)", systemImage: currentItem.systemImage)
                    .font(.fernlet(.label))
                    .foregroundStyle(Color.bark)

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

                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Status")
                            .font(.fernlet(.labelSmall))
                            .foregroundStyle(Color.slate)
                        Text("Available after Apple Fitness integration lands (M2)")
                            .font(.fernlet(.body))
                            .foregroundStyle(Color.bark)
                            .fernletWrappingText()
                    }
                    Spacer(minLength: 8)
                    Button("Request access") {}
                        .buttonStyle(.plain)
                        .font(.fernlet(.label))
                        .foregroundStyle(Color.slate.opacity(0.55))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.parchment.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
                        .disabled(true)
                }
            }
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
                    SectionLabel(key)
                    ForEach(groups[key] ?? []) { memory in
                        memoryRow(memory)
                    }
                }
            }
        }
        .sheet(item: $editingMemory) { memory in
            MemoryEditorSheet(store: store, memory: memory)
                .presentationDetents([.medium, .large])
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
                    Button("Delete \(matches.count)", role: .destructive) {
                        matches.forEach { store.deleteMemory($0) }
                        memorySearch = ""
                    }
                    .font(.fernlet(.label))
                    Button("Cancel") { memorySearch = "" }
                        .font(.fernlet(.label))
                        .foregroundStyle(Color.slate)
                }
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
            Text("Health access is optional and requested by feature. Apple does not reveal read-denial status, so empty Health results are handled as normal.")
                .font(.fernlet(.body))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()

            if !healthKit.snapshot.isAvailable {
                FernletCard { EmptyState(text: "Health data is not available on this device.") }
            } else {
                ForEach(store.visibleHealthCapabilities) { capability in
                    healthCapabilityRow(capability)
                }
            }

            if !healthKit.statusMessage.isEmpty {
                Text(healthKit.statusMessage)
                    .font(.fernlet(.bodySmall))
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()
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
            .foregroundStyle(.white)
            .padding(.vertical, 11)
            .background(Color.moss, in: RoundedRectangle(cornerRadius: 12))
            .disabled(healthKit.isRequesting)
            .opacity(healthKit.isRequesting ? 0.55 : 1)

            if canShowRevokeAccess(for: capability) {
                Button {
                    openHealthPermissionSettings(for: capability)
                } label: {
                    Label("Revoke access", systemImage: "xmark.shield")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .font(.fernlet(.label))
                .foregroundStyle(.white)
                .padding(.vertical, 11)
                .background(Color.terracotta, in: RoundedRectangle(cornerRadius: 12))
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

    private var healthSyncedProfileBinding: Binding<UserNutritionProfile> {
        Binding(
            get: { store.settings.userProfile },
            set: { profile in
                store.settings.userProfile = profile
                Task { await healthKit.syncBodyProfileMeasurements(profile) }
            }
        )
    }

    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 14) {
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
                Toggle("Show calories", isOn: $store.settings.showCalories)
            }
            .padding(14)
            .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))

            SectionLabel("Body & preferences")
            ProfileEditor(profile: healthSyncedProfileBinding, preferences: $store.settings.nutritionPreferences)

            NutritionTargetsEditor(store: store)

            SectionLabel("AI")
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Current")
                    Spacer()
                    Text(store.effectiveAIStatus.label)
                        .font(.fernlet(.label))
                        .foregroundStyle(Color.bark)
                }
                Toggle("Manual off mode", isOn: aiManualOffBinding)
                Divider().overlay(Color.bark.opacity(0.08))
                Toggle("Web nutrition lookup", isOn: $store.settings.webNutritionLookupEnabled)
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
                            }
                        } else {
                            store.settings.weatherPromptsEnabled = false
                        }
                    }
                ))
                Text("On heavy, gloomy days Fernlet can offer a gentle recovery nudge. Uses your approximate location for weather only, never stored or shared.")
                    .font(.fernlet(.bodySmall))
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()
                Text(FernletVoice.message(for: {
                    // Reflect the EFFECTIVE status (intent overlaid with today's local budget): off shows
                    // the switched-off copy, a spent budget (.sleepy/.resting) the resting copy, otherwise
                    // the gentle retry note.
                    switch store.effectiveAIStatus {
                    case .off: return .aiUnavailable
                    case .sleepy, .resting: return .aiResting
                    case .ready: return .retryAvailable
                    }
                }()))
                    .font(.fernlet(.bubble))
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()
            }
            .padding(14)
            .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))

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
                Task { await scheduleDailyCheckIn(at: newValue) }
            }

            SectionLabel("Hydration")
            VStack(alignment: .leading, spacing: 10) {
                Stepper("Bottle: \(store.settings.bottleOz) oz", value: $store.settings.bottleOz, in: 4...64)
                Divider().overlay(Color.bark.opacity(0.08))
                Stepper("Daily target: \(store.settings.hydrationTarget) bottles", value: $store.settings.hydrationTarget, in: 1...30)
            }
            .padding(14)
            .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))

            personalCareSettings
        }
    }

    private var aiManualOffBinding: Binding<Bool> {
        Binding(
            get: { store.settings.aiStatus == .off },
            set: { store.settings.aiStatus = $0 ? .off : .ready }
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

    private var personalCareSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Personal care tasks")
            VStack(alignment: .leading, spacing: 10) {
                TextField("Moisturizer, meds, stretch...", text: $newCareTaskName)
                    .sheetTextInput()
                FlowLayout(spacing: 8) {
                    ForEach(PersonalCareTask.groups, id: \.self) { group in
                        Button(group) { newCareTaskGroup = group }
                            .buttonStyle(ChipButtonStyle(selected: newCareTaskGroup == group))
                    }
                }
                Button {
                    store.addPersonalCareTask(label: newCareTaskName, group: newCareTaskGroup)
                    newCareTaskName = ""
                } label: {
                    Label("Add task", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .font(.fernlet(.label))
                .foregroundStyle(.white)
                .padding(.vertical, 11)
                .background(Color.moss, in: RoundedRectangle(cornerRadius: 12))
                .disabled(newCareTaskName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(newCareTaskName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.45 : 1)
            }
            .padding(14)
            .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))

            ForEach(PersonalCareTask.groups, id: \.self) { group in
                let tasks = store.personalCareTasks.filter { $0.group == group }
                if !tasks.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(group)
                            .font(.fernlet(.labelSmall))
                            .foregroundStyle(Color.slate)
                        ForEach(tasks) { task in
                            HStack(spacing: 10) {
                                Label(task.label, systemImage: task.systemImage)
                                    .font(.fernlet(.label))
                                    .foregroundStyle(Color.bark)
                                Spacer()
                                Button { store.removePersonalCareTask(task) } label: {
                                    Image(systemName: "minus.circle")
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(Color.terracotta)
                                        .frame(width: 32, height: 32)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(12)
                            .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
            }
        }
    }

    private var debugCard: some View {
        FernletCard {
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel("Debug")
                Text("Storage: local JSON database")
                Text("File: \(store.storageLocation)")
                Text("Today key: \(store.todayKey)")
            }
            .font(.fernlet(.labelSmall))
            .foregroundStyle(Color.slate)
        }
    }

    private var debugTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Prototype only — not production-private. Debug surfaces for local inspection during development.")
                .font(.fernlet(.body))
                .foregroundStyle(Color.terracotta)
                .fernletWrappingText()

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

            debugCard

            VStack(alignment: .leading, spacing: 12) {
                SectionLabel("Tier 2 memory (test-only view)")
                Text("Tier 2 memories are inferred context records. In production these will not be readable. This view exists for prototype inspection only.")
                    .font(.fernlet(.bodySmall))
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()

                // Loaded post-render by the `.task` on this section: the repository decodes the
                // whole database for this read, which is far too slow for a NavigationStack push's
                // first body pass. Until it lands, say so — the previous three-branch form rendered
                // neither the list nor the empty state on the initial push, which reads as a broken
                // page rather than a deliberate on-demand load.
                if debugTierTwoMemories == nil {
                    FernletCard { EmptyState(text: "Loading tier 2 memories…") }
                } else if let tier2 = debugTierTwoMemories, tier2.isEmpty {
                    FernletCard { EmptyState(text: "No tier 2 memories yet. They are extracted from journals when Foundation Models are available.") }
                } else if let tier2 = debugTierTwoMemories {
                    ForEach(tier2) { record in
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
                }
            }
            // The load the comment above describes. Runs once per push, after the first frame, so
            // the whole-database decode never blocks the navigation animation.
            .task {
                guard debugTierTwoMemories == nil else { return }
                debugTierTwoMemories = store.tierTwoMemories
            }

            VStack(alignment: .leading, spacing: 12) {
                SectionLabel("Derived signals (test-only view)")
                let signals = store.derivedSignals
                if signals.isEmpty {
                    FernletCard { EmptyState(text: "No signals computed yet. More logs will make trends useful.") }
                } else {
                    ForEach(signals) { signal in
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
                }
            }
        }
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
        VStack(alignment: .leading, spacing: 10) {
            Button("Delete everything", role: .destructive) {
                pendingDestructiveAction = DeleteAllDataConfirmation.make(
                    canDeleteHealthSamples: storagePreferencesStore.preferences.healthKitMasterEnabled,
                    hasICloudDayCopy: storagePreferencesStore.preferences.hasICloudDayCopy,
                    hasSealedBackup: storagePreferencesStore.preferences.hasSealedBackup,
                    delete: { includeHealth in
                        // Set here (right after the user confirms) so the busy overlay covers the whole
                        // multi-second wipe, disabling the buttons and blocking a second confirm.
                        isDeletingEverything = true
                        return await store.deleteAllData(includingHealthKitSamples: includeHealth)
                    },
                    onFinished: { outcome in
                        isDeletingEverything = false
                        // Affirm success (its alert dismisses the sheet on OK) only on a clean wipe. On
                        // failure the sheet stays put behind the failure alert so the user can read which
                        // store survived and retry — dismissing regardless would hide the failure behind
                        // an app that merely looks empty.
                        if outcome.isComplete {
                            showDeleteSuccess = true
                        } else {
                            deleteAllFailure = outcome
                        }
                    }
                )
            }
            .disabled(isDeletingEverything)
            .accessibilityIdentifier("settings.deleteAll")
        }
        .font(.fernlet(.label))
    }

    private var doneBar: some View {
        HStack {
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(.plain)
                .font(.fernlet(.label))
                .foregroundStyle(.white)
                .padding(.horizontal, 28)
                .padding(.vertical, 16)
                .background(Color.moss, in: RoundedRectangle(cornerRadius: 16))
                .disabled(isDeletingEverything)
        }
        .padding(20)
        .background(Color.parchment)
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
            Button { store.deleteMemory(memory) } label: {
                Image(systemName: "xmark")
                    .foregroundStyle(Color.slate)
                    .frame(width: 34, height: 34)
                    .background(Color.bark.opacity(0.05), in: Circle())
            }
            .buttonStyle(.plain)
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
struct MemoryEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: FernletStore
    var memory: MemoryNote
    @State private var category: String
    @State private var text: String
    @State private var confirmDelete = false

    init(store: FernletStore, memory: MemoryNote) {
        self.store = store
        self.memory = memory
        _category = State(initialValue: memory.category)
        _text = State(initialValue: memory.text)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Core memory")
                        .font(.fernlet(.displayMedium))
                        .foregroundStyle(Color.bark)

                    SheetField("Category") {
                        TextField("note", text: $category)
                            .sheetTextInput()
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

                    if confirmDelete {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Delete this memory?")
                                .font(.fernlet(.header))
                                .foregroundStyle(Color.bark)
                            HStack {
                                Button("Delete", role: .destructive) {
                                    store.deleteMemory(memory)
                                    dismiss()
                                }
                                Button("Cancel") { confirmDelete = false }
                            }
                            .font(.fernlet(.label))
                        }
                    } else {
                        Button("Delete memory", role: .destructive) { confirmDelete = true }
                            .font(.fernlet(.label))
                    }
                }
                .padding(20)
                .padding(.bottom, 10)
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
struct AppLockSettingsView: View {
    @Environment(FernletLockService.self) private var lockService
    @Environment(\.dismiss) private var dismiss

    @State private var showSetup = false
    @State private var showChangePasscode = false
    @State private var showResetConfirm = false
    @State private var showBiometricPasscodeVerify = false
    @State private var verifyCurrentPasscode = ""
    @State private var verifyError: String?
    @State private var pendingBiometricEnable = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                statusCard

                if lockService.state != .notConfigured {
                    actionsCard
                    biometricCard
                    dangerCard
                } else {
                    setupCTACard
                }
            }
            .padding(20)
            .padding(.bottom, 20)
        }
        .scrollContentBackground(.hidden)
        .background(Color.parchment)
        .navigationTitle("App lock")
        .sheet(isPresented: $showSetup) {
            FernletLockSetupView()
                .environment(lockService)
        }
        .sheet(isPresented: $showChangePasscode) {
            FernletLockChangePasscodeView()
                .environment(lockService)
        }
        .sheet(isPresented: $showBiometricPasscodeVerify) {
            biometricVerifySheet
        }
        .confirmationDialog(
            "Reset app lock?",
            isPresented: $showResetConfirm,
            titleVisibility: .visible
        ) {
            Button("Reset app lock", role: .destructive) {
                try? lockService.reset()
                dismiss()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Private journal, cycle, and intimacy notes will become permanently unreadable. HealthKit cycle and intimacy entries remain in Apple Health.")
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

            Button {
                lockService.lock(reason: .manual)
            } label: {
                settingsRow(icon: "lock.fill", title: "Lock now")
            }
        }
        .padding(14)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))
    }

    private var biometricCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(biometricName(lockService.biometricType))

            if lockService.biometricType != .none {
                Toggle(isOn: biometricToggleBinding) {
                    settingsRow(
                        icon: biometricSystemImage(lockService.biometricType),
                        title: "Use \(biometricName(lockService.biometricType))"
                    )
                }
                .toggleStyle(SwitchToggleStyle(tint: Color.moss))
            } else {
                Text("No biometric authentication available on this device.")
                    .font(.fernlet(.body))
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()
            }
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
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.moss, in: RoundedRectangle(cornerRadius: 14))
        }
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
                    } else {
                        let total = lockService.credentialKind == .pin4 ? 4 : 6
                        VStack(spacing: 20) {
                            pinDotsRow(current: verifyCurrentPasscode, total: total)
                            FernletNumericPad(value: $verifyCurrentPasscode, maxLength: total)
                        }
                        .onChange(of: verifyCurrentPasscode) { _, new in
                            if new.count == total { commitBiometricToggle() }
                        }
                    }

                    if lockService.credentialKind == .alphanumeric {
                        Button("Confirm") { commitBiometricToggle() }
                            .buttonStyle(.plain)
                            .font(.fernlet(.label))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.moss, in: RoundedRectangle(cornerRadius: 14))
                            .disabled(verifyCurrentPasscode.isEmpty)
                    }

                    Spacer()
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
                    Task { try? await lockService.setBiometricEnabled(false, passcode: "") }
                }
            }
        )
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

    private func settingsRow(icon: String, title: String, destructive: Bool = false) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(destructive ? Color.terracotta : Color.moss)
                .frame(width: 28)
            Text(title)
                .font(.fernlet(.label))
                .foregroundStyle(destructive ? Color.terracotta : Color.bark)
            Spacer()
            if !destructive {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.slate.opacity(0.5))
            }
        }
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
            Text("Enter your current passcode to continue.")
                .font(.fernlet(.body))
                .foregroundStyle(Color.slate)

            if let msg = errorMessage { errorBanner(msg) }

            let oldKind = lockService.credentialKind ?? .pin6
            if oldKind == .alphanumeric {
                SecureField("Current password", text: $currentPasscode)
                    .textContentType(.password)
                    .sheetTextInput()
            } else {
                let total = oldKind == .pin4 ? 4 : 6
                VStack(spacing: 20) {
                    pinDotsRow(current: currentPasscode, total: total)
                    FernletNumericPad(value: $currentPasscode, maxLength: total)
                }
                .onChange(of: currentPasscode) { _, new in
                    if new.count == total { advanceFromVerifyOld() }
                }
            }
            Spacer()
            if (lockService.credentialKind ?? .pin6) == .alphanumeric {
                continueButton { advanceFromVerifyOld() }
            }
        }
    }

    private func advanceFromVerifyOld() {
        Task { @MainActor in
            do {
                _ = try await lockService.unlock(passcode: currentPasscode)
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
            } else {
                let total = selectedKind == .pin4 ? 4 : 6
                VStack(spacing: 20) {
                    pinDotsRow(current: newPasscode, total: total)
                    FernletNumericPad(value: $newPasscode, maxLength: total)
                }
                .onChange(of: newPasscode) { _, new in
                    if new.count == total { step = .confirmNew }
                }
            }
            Spacer()
            if selectedKind == .alphanumeric {
                continueButton(disabled: newPasscode.count < 8) { step = .confirmNew }
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
            } else {
                let total = selectedKind == .pin4 ? 4 : 6
                VStack(spacing: 20) {
                    pinDotsRow(current: confirmPasscode, total: total)
                    FernletNumericPad(value: $confirmPasscode, maxLength: total)
                }
                .onChange(of: confirmPasscode) { _, new in
                    if new.count == total { commitChange() }
                }
            }
            Spacer()
            if selectedKind == .alphanumeric {
                continueButton(disabled: confirmPasscode.isEmpty) { commitChange() }
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
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(disabled ? Color.moss.opacity(0.4) : Color.moss, in: RoundedRectangle(cornerRadius: 14))
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
