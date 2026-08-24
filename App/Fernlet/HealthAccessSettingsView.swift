import SwiftUI
import FernletDomainModel
import FernletFoundation
import FernletUI
import HealthKitGateway

/// Settings › Health — THE Health surface (2026-08-21 redesign, artboard 5d — SETT-27, SETT-26).
///
/// One surface, one vocabulary: a master "Share with Health" switch that states what turning it
/// off does, then one card per capability with plain-language name, **state** (Shared / Not
/// shared) and **action** (Give access / Stop sharing) on the same card — so the two pages that
/// used to disagree about whether a kind is shared (this tab's authorization cards vs Privacy &
/// Data's preference toggles) can no longer disagree: Privacy & Data now holds a single
/// "Health access → N of M" row into this page.
///
/// **Capability mapping** (display grouping over SEVEN frozen preference keys — rawValues are the
/// persisted `StoragePreferences.healthKitCapabilityEnabled` keys and never change):
/// - "Body measurements" = `bodyProfile`
/// - "Workouts & activity" = ONE card driving BOTH `workoutLogging` AND `activityContext`
/// - "Body signals" = `bodyContext` as its own card (sleep, heart and temperature signals — the
///   design canvas omitted it; there is no separate sleep permission, sleep hours arrive here)
/// - "Mindfulness" keeps its card
/// - "Cycle tracking" and "Intimate logging" stay TWO separate cards (the collapse into one card
///   was a reserved user decision, so the fail-safe implementation keeps them apart), using the
///   new state+action vocabulary; the intimate card's copy states the real boundary — sealed
///   notes never leave the device, samples belong to Apple Health under its protections.
///
/// **Gates preserved**: the card list is built from `FernletStore.visibleHealthCapabilities`
/// (cycle/intimate cards withheld while hidden) AND every action re-checks
/// ``canUseHealthCapability(_:)`` at the point of use — the actions read HealthKit and write
/// straight into the day's health context, which is precisely the hole the visibility gate closes.
///
/// "Give access" turns the capability's preference on (audited) and runs the authorization prompt
/// + first pull; "Stop sharing" turns the preference off (audited) — Fernlet stops reading, and
/// the samples stay in Apple Health (full revocation lives in the Health app, one tap away via
/// "Open Health Privacy Settings"). Disabling the master switch warns first and then purges the
/// locally cached Health-derived values, exactly as the Privacy & Data master used to.
///
/// Dynamic Type (5d·AX3): the master switch loses its sub-line, and each capability card drops
/// its description — keeping the three things that matter: name, state, action.
struct HealthAccessSettingsView: View {
    /// Nil only for previews and the UI-test harness (mirrors ``PrivacyDataSettingsView``): the
    /// card list then falls back to every capability and pulls write nothing.
    var store: FernletStore?
    @Environment(StoragePreferencesStore.self) private var storagePreferencesStore
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var healthKit = HealthKitAuthorizationViewModel()
    /// The master-disable warning (it purges cached clinical values) — WS-5.
    @State private var pendingDestructiveAction: DestructiveConfirmation?
    /// A failed master enable/disable, rendered under the master card rather than swallowed.
    @State private var healthError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ScreenHeader(
                    title: "Health",
                    subtitle: "Fernlet asks for Health access only when a feature needs it.",
                    identifier: "screen.settings.health"
                )
                if healthKit.availabilityState == .deviceUnavailable {
                    FernletCard {
                        EmptyState(text: "Health data is not available on this device.", systemImage: "heart.slash")
                    }
                } else {
                    masterCard
                    ForEach(Self.visibleCards(for: visibleCapabilities)) { card in
                        capabilityCard(card)
                    }
                    openHealthSettingsButton
                    if !healthKit.statusMessage.isEmpty {
                        Text(healthKit.statusMessage)
                            .font(.fernlet(.bodySmall))
                            .foregroundStyle(Color.slate)
                            .fernletWrappingText()
                    }
                }
            }
            .padding(20)
            .padding(.bottom, 20)
        }
        .scrollContentBackground(.hidden)
        .background(Color.parchment)
        .navigationTitle("Health")
        .navigationBarTitleDisplayMode(.inline)
        .destructiveConfirmation($pendingDestructiveAction)
        .onAppear { healthKit.refresh() }
    }

    // MARK: - The display grouping

    /// One card of the Health surface. The rawValue is a frozen accessibility/test token
    /// (`health.card.state.<token>`), never persisted — persistence stays on the SEVEN
    /// `HealthCapability` rawValues each card drives.
    enum HealthAccessCard: String, CaseIterable, Identifiable {
        case bodyMeasurements
        case workoutsActivity
        case bodySignals
        case mindfulness
        case cycleTracking
        case intimateLogging

        var id: String { rawValue }

        /// The preference keys this card drives — the fail-safe mapping documented on the type.
        var capabilities: [HealthCapability] {
            switch self {
            case .bodyMeasurements: [.bodyProfile]
            case .workoutsActivity: [.workoutLogging, .activityContext]
            case .bodySignals: [.bodyContext]
            case .mindfulness: [.mindfulness]
            case .cycleTracking: [.cycleTracking]
            case .intimateLogging: [.intimateLogging]
            }
        }

        var title: LocalizedStringKey {
            switch self {
            case .bodyMeasurements: "Body measurements"
            case .workoutsActivity: "Workouts & activity"
            case .bodySignals: "Body signals"
            case .mindfulness: "Mindfulness"
            case .cycleTracking: "Cycle tracking"
            case .intimateLogging: "Intimate logging"
            }
        }

        var summary: LocalizedStringKey {
            switch self {
            case .bodyMeasurements: "Weight and height, for macro targets."
            case .workoutsActivity: "Reads Apple Watch workouts and daily activity, writes yours back."
            case .bodySignals: "Sleep, heart and temperature signals, for recovery context."
            case .mindfulness: "Breathe and ground sessions, written back to Health."
            case .cycleTracking: "Reads and writes cycle observations, like flow and temperature."
            case .intimateLogging: "Sealed notes never leave this device. Samples live in Apple Health, under its protections."
            }
        }

        var systemImage: String {
            switch self {
            case .bodyMeasurements: "person.text.rectangle"
            case .workoutsActivity: "figure.run"
            case .bodySignals: "waveform.path.ecg"
            case .mindfulness: "figure.mind.and.body"
            case .cycleTracking: "calendar.badge.clock"
            case .intimateLogging: "lock.shield"
            }
        }
    }

    /// The cards whose capabilities are currently offered — a card renders when ANY of its
    /// capabilities is visible (in practice only the cycle/intimate cards are ever withheld).
    static func visibleCards(for visible: [HealthCapability]) -> [HealthAccessCard] {
        HealthAccessCard.allCases.filter { card in
            card.capabilities.contains(where: visible.contains)
        }
    }

    /// The "N of M kinds shared" numbers the hub row and Privacy & Data's Health-access row
    /// render: M = cards offered, N = cards whose every preference key is on (0 with the master
    /// off).
    static func sharedKindCounts(
        preferences: StoragePreferences,
        visible: [HealthCapability]
    ) -> (shared: Int, total: Int) {
        let cards = visibleCards(for: visible)
        guard preferences.healthKitMasterEnabled else { return (0, cards.count) }
        let shared = cards.filter { card in
            card.capabilities.allSatisfy { preferences.healthKitCapabilityEnabled[$0.rawValue] == true }
        }.count
        return (shared, cards.count)
    }

    // MARK: - Master switch

    /// The master switch's sub-line, held in one place because it is now rendered twice: drawn
    /// under the toggle at default sizes, and re-attached to the toggle as accessibility custom
    /// content at every size (T2-2 — see ``masterCard``).
    private var masterSubline: LocalizedStringKey {
        "Turning this off stops every kind below"
    }

    private var masterCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: masterBinding) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Share with Health")
                        .font(.fernlet(.label))
                        .foregroundStyle(Color.bark)
                    // 5d·AX3: the master switch keeps its card and loses its sub-line.
                    if !dynamicTypeSize.isAccessibilitySize {
                        Text(masterSubline)
                            .font(.fernlet(.bodySmall))
                            .foregroundStyle(Color.slate)
                            .fernletWrappingText()
                    }
                }
            }
            .toggleStyle(SwitchToggleStyle(tint: Color.moss))
            .accessibilityIdentifier("privacy.health.master")
            // T2-2: the sub-line above is DELETED from the layout at accessibility sizes, and a
            // view that is never drawn never enters the accessibility tree either — so a user
            // running Larger Text and VoiceOver together lost the one sentence that says what the
            // master switch does to the kinds below it. Re-attached on the More Content rotor at
            // every size; the toggle's own on/off value is untouched.
            .accessibilityCustomContent("Details", masterSubline)
            if let healthError {
                Text(healthError)
                    .font(.fernlet(.bodySmall))
                    .foregroundStyle(Color.terracotta)
                    .fernletWrappingText()
                    .accessibilityIdentifier("health.master.error")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))
    }

    /// Enabling is constructive — commit directly. Disabling fail-closed PURGES the cached
    /// HealthKit-derived clinical values from this device (the data itself stays in Apple
    /// Health), so it warns before committing (WS-5) — the flow relocated verbatim from
    /// Privacy & Data.
    private var masterBinding: Binding<Bool> {
        Binding(
            get: { storagePreferencesStore.preferences.healthKitMasterEnabled },
            set: { newValue in
                if newValue {
                    Task { await setMasterEnabled(true) }
                } else {
                    pendingDestructiveAction = DestructiveConfirmation(
                        title: "Turn off Health integration?",
                        message: """
                            Turning this off removes the activity, cycle, and other Health data \
                            Fernlet has cached on this device. Your data stays in Apple Health. Turn off?
                            """,
                        confirmLabel: "Turn off",
                        auditEvent: "privacy.healthKit.masterDisableConfirmed"
                    ) {
                        await setMasterEnabled(false)
                    }
                }
            }
        )
    }

    private func setMasterEnabled(_ enabled: Bool) async {
        healthError = nil
        FernletAuditLog.log(enabled ? "privacy.healthKit.masterEnabled" : "privacy.healthKit.masterDisabled")
        do {
            let service = makeHealthKitService()
            if enabled {
                try await service.enableIntegration()
                storagePreferencesStore.update { $0.healthKitMasterEnabled = true }
            } else {
                try await service.disableIntegration()
                storagePreferencesStore.update { preferences in
                    preferences.healthKitMasterEnabled = false
                    preferences.healthKitCapabilityEnabled = StoragePreferences.defaultHealthKitCapabilityEnabled
                }
            }
            healthKit.refresh()
        } catch {
            healthError = error.localizedDescription
        }
    }

    /// The real integration outside UI tests; the preference-flipping mock under the mocked
    /// privacy-services environment (same seam ``PrivacyDataSettingsView`` uses).
    private func makeHealthKitService() -> any PrivacyHealthKitServicing {
        #if DEBUG
        if ProcessInfo.processInfo.environment["FERNLET_UI_TEST_PRIVACY_SERVICES"] == "1" {
            return MockPrivacyHealthKitService(preferencesStore: storagePreferencesStore)
        }
        #endif
        return HealthKitService(preferencesStore: storagePreferencesStore)
    }

    // MARK: - Capability cards

    /// A card's derived state, from its preference keys folded with the master switch.
    private enum CardState {
        case shared
        case partlyShared
        case notShared
    }

    /// The visibility-gated capability list — the display half of the gate; every action
    /// re-checks at the point of use.
    private var visibleCapabilities: [HealthCapability] {
        store?.visibleHealthCapabilities ?? HealthCapability.allCases
    }

    private var masterEnabled: Bool {
        storagePreferencesStore.preferences.healthKitMasterEnabled
    }

    private func state(of card: HealthAccessCard) -> CardState {
        guard masterEnabled else { return .notShared }
        let preferences = storagePreferencesStore.preferences
        let enabled = card.capabilities.filter { preferences.healthKitCapabilityEnabled[$0.rawValue] == true }.count
        if enabled == card.capabilities.count { return .shared }
        return enabled == 0 ? .notShared : .partlyShared
    }

    private func stateLabel(for state: CardState) -> LocalizedStringKey {
        switch state {
        case .shared: "Shared"
        case .partlyShared: "Partly shared"
        case .notShared: "Not shared"
        }
    }

    private func stateColor(for state: CardState) -> Color {
        switch state {
        case .shared: Color.moss
        case .partlyShared: Color.goldenrod
        case .notShared: Color.softTaupe
        }
    }

    /// One capability card: plain-language name, what Fernlet does with it, state, and the action
    /// for that state — all on the same card, so state and action can never disagree.
    private func capabilityCard(_ card: HealthAccessCard) -> some View {
        let cardState = state(of: card)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: card.systemImage)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(Color.moss)
                    .frame(width: 34, height: 34)
                    .background(Color.moss.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text(card.title)
                        .font(.fernlet(.header))
                        .foregroundStyle(Color.bark)
                        // T2-2: the summary below is dropped from the LAYOUT at accessibility
                        // sizes, which also drops it out of the accessibility tree. Re-attached
                        // to the card's name — the one element that is always present — so
                        // "what Fernlet does with this kind" stays reachable on the More Content
                        // rotor. On the title rather than the card, because the card is not a
                        // single accessibility element (it contains the action buttons).
                        .accessibilityCustomContent("Details", card.summary)
                    // 5d·AX3: the description is what gives way; name, state and action stay.
                    if !dynamicTypeSize.isAccessibilitySize {
                        Text(card.summary)
                            .font(.fernlet(.bodySmall))
                            .foregroundStyle(Color.slate)
                            .fernletWrappingText()
                    }
                }
                Spacer(minLength: 8)
            }
            HStack(spacing: 8) {
                Circle()
                    .fill(stateColor(for: cardState))
                    .frame(width: 8, height: 8)
                Text(stateLabel(for: cardState))
                    .font(.fernlet(.labelSmall))
                    .foregroundStyle(Color.slate)
                    .accessibilityIdentifier("health.card.state.\(card.rawValue)")
            }
            cardActions(card, state: cardState)
        }
        .padding(14)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))
    }

    /// The action row for one card state: Give access when anything is off, Update data + Stop
    /// sharing once shared. Stop sharing is a small inline destructive word — terracotta ink,
    /// never a filled pill (the destructive token's rule for inline words).
    @ViewBuilder
    private func cardActions(_ card: HealthAccessCard, state cardState: CardState) -> some View {
        if cardState == .shared {
            HStack(spacing: 16) {
                Button {
                    updateData(for: card)
                } label: {
                    Label("Update data", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .font(.fernlet(.label))
                .foregroundStyle(Color.moss)
                .disabled(healthKit.isRequesting)
                .opacity(healthKit.isRequesting ? 0.55 : 1)
                .frame(minHeight: 44)
                .accessibilityIdentifier("health.card.update.\(card.rawValue)")
                Spacer(minLength: 0)
                Button("Stop sharing") {
                    stopSharing(card)
                }
                .buttonStyle(.plain)
                .font(.fernlet(.label))
                .foregroundStyle(Color.terracottaInk)
                .frame(minHeight: 44)
                .accessibilityIdentifier("health.card.stop.\(card.rawValue)")
            }
        } else {
            Button {
                giveAccess(to: card)
            } label: {
                Label("Give access", systemImage: "heart.text.square")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .font(.fernlet(.label))
            .foregroundStyle(Color.onMoss)
            .padding(.vertical, 11)
            .background(Color.mossFill, in: RoundedRectangle(cornerRadius: 12))
            .disabled(!masterEnabled || healthKit.isRequesting)
            .opacity(!masterEnabled || healthKit.isRequesting ? 0.55 : 1)
            .accessibilityIdentifier("health.card.give.\(card.rawValue)")
        }
    }

    /// Full revocation lives in the Health app; this is the one-tap route there.
    private var openHealthSettingsButton: some View {
        Button {
            Task { await makeHealthKitService().openHealthPrivacySettings() }
        } label: {
            Label("Open Health Privacy Settings", systemImage: "arrow.up.forward.app")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .font(.fernlet(.label))
        .foregroundStyle(Color.onMoss)
        .padding(.vertical, 11)
        .background(Color.mossFill, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("privacy.health.openSettings")
    }

    // MARK: - Actions

    /// Turns the card's preference keys on (audited), then runs the authorization prompt and
    /// first pull for each. Bounded: a card drives at most two capabilities.
    private func giveAccess(to card: HealthAccessCard) {
        guard card.capabilities.allSatisfy(canUseHealthCapability) else { return }
        for capability in card.capabilities
        where storagePreferencesStore.preferences.healthKitCapabilityEnabled[capability.rawValue] != true {
            FernletAuditLog.log(
                "privacy.healthKit.capabilityEnabled",
                context: ["capability": capability.rawValue, "source": "healthAccessCard"]
            )
            storagePreferencesStore.update { preferences in
                preferences.healthKitCapabilityEnabled[capability.rawValue] = true
            }
        }
        Task { await requestAndPull(card) }
    }

    /// Turns the card's preference keys off (audited). Fernlet stops reading; the samples stay in
    /// Apple Health under its protections.
    private func stopSharing(_ card: HealthAccessCard) {
        for capability in card.capabilities {
            FernletAuditLog.log(
                "privacy.healthKit.capabilityDisabled",
                context: ["capability": capability.rawValue, "source": "healthAccessCard"]
            )
            storagePreferencesStore.update { preferences in
                preferences.healthKitCapabilityEnabled[capability.rawValue] = false
            }
        }
    }

    /// The per-capability prompt + first pull — the body-profile import for measurements, the
    /// context refresh for everything else.
    private func requestAndPull(_ card: HealthAccessCard) async {
        for capability in card.capabilities {
            if capability == .bodyProfile {
                if let store,
                   let profile = await healthKit.importBodyProfile(current: store.settings.userProfile) {
                    store.settings.userProfile = profile
                    store.scheduleSnapshotSave()
                }
            } else {
                await healthKit.request(capability)
                if let store, let context = await healthKit.updateHealthContext(for: capability) {
                    store.updateHealthContext(context)
                }
            }
        }
    }

    /// Manual refresh for an already-shared card.
    private func updateData(for card: HealthAccessCard) {
        guard card.capabilities.allSatisfy(canUseHealthCapability) else { return }
        Task {
            for capability in card.capabilities {
                if capability == .bodyProfile {
                    if let store,
                       let profile = await healthKit.updateBodyProfile(current: store.settings.userProfile) {
                        store.settings.userProfile = profile
                        store.scheduleSnapshotSave()
                    }
                } else if let store, let context = await healthKit.updateHealthContext(for: capability) {
                    store.updateHealthContext(context)
                }
            }
        }
    }

    /// Defense in depth against the reads these actions perform. `visibleHealthCapabilities`
    /// already withholds the row, so this should be unreachable from the UI — but the actions read
    /// HealthKit and write straight back into the day's health context, which is precisely the
    /// hole the visibility gate exists to close. Re-check at the point of use, not just the point
    /// of display. Age first: "you're under 16" must not be reported as "you turned this off".
    private func canUseHealthCapability(_ capability: HealthCapability) -> Bool {
        guard let store else { return false }
        guard capability != .intimateLogging || store.isIntimateLoggingAllowed else {
            healthKit.showIntimateLoggingAgeWallMessage()
            return false
        }
        switch capability {
        case .cycleTracking: return store.isPeriodTrackingVisible
        case .intimateLogging: return store.isIntimacyTrackingVisible
        default: return true
        }
    }
}
