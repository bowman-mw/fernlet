// DuressPINSetupView.swift
// Fernlet
//
// Phase 7 (duress PIN), step 9: the screen where a duress code is chosen, changed and removed.
//
// It lives under Settings → App lock, which is a `.appLockSettings` surface the user must already
// have unlocked with the REAL passcode — biometrics can never be the first factor after launch
// (PIN-before-biometrics), they are suppressed outright during a duress session, and the duress path
// REFUSES to grant `.appLockSettings` at all (`FernletLockService.handleDuress`). That gate alone
// once stood in for a re-prompt, and it was not enough (DPA-76): a page left open is held by whoever
// picks the phone up, and the "must be different from your passcode" refusal answered "is this the
// passcode?" for every guess, uncounted. So the entry sheet now opens on the real passcode, checked
// on the same counted door as an unlock, and `FernletLockService.configureDuress(pin:mode:current:)`
// requires it.
//
// That premise used to be an assumption, and it was false: a decoy session granted whatever scope
// the duress code was typed on, including this one, which put "a duress code is set, and here is the
// armed response" two taps from a coercer — along with the buttons to change it, remove it, enrol a
// recovery device of their choosing, and reset the lock. Two layers now hold it up instead of one:
// the service refuses the scope AND refuses every duress mutator while `isDuressSessionActive`, and
// `DuressSetupAvailability` fails closed on the same flag, so a session that somehow reached this
// screen renders exactly what a phone with no duress code renders.
//
// THE COPY ON THIS SCREEN IS PART OF THE FEATURE. Two of the three responses destroy something, and
// one of those two is irreversible. A user who arms a response they misunderstood has not been given
// a safety feature, they have been given a trap — so each response states what it does to their data
// in plain words, the destructive ones carry a second explicit confirmation, and nothing here
// promises more than `Docs/PrivacyWipeCoverage.md` says the code actually delivers.

import SwiftUI
import FernletFoundation
import FernletLock
import FernletLockUI
import FernletUI

// MARK: - Policy

/// View-free policy for what the duress-code screen may offer, and why an option is withheld.
///
/// Split out of the view so the gating rules — which responses are selectable, whether the recovery
/// device may be un-enrolled — are unit-testable without a `View`, and so the same rules cannot
/// drift between the card that renders a response and the button that commits it.
///
/// A snapshot, deliberately: it is rebuilt from the service on every body evaluation rather than
/// held as state, because the underlying answers are keychain reads that any of the ceremony sheets
/// can change while this screen is on top of them.
struct DuressSetupAvailability: Equatable {
    /// Whether a duress code exists at all.
    let hasDuressConfigured: Bool
    /// The response the existing duress code triggers, or nil when there is none.
    let configuredMode: DuressMode?
    /// Whether the user's own second device is enrolled as a recovery custodian — all three rows,
    /// not just the two public keys (see `FernletLockService.hasRecoveryCustodian`).
    let hasRecoveryCustodian: Bool
    /// Whether that enrolled device's sealed blob holds a SUPERSEDED content key — the state a
    /// recovery-locked phone lands in when its user sets up a new app lock before reaching their
    /// custodian (`FernletLockService.hasSupersededRecoveryBlob`).
    let hasSupersededRecoveryBlob: Bool
    /// Whether a duress session is in force right now.
    ///
    /// When true every other field is reported as an UNCONFIGURED device, which is the point: this
    /// screen is the one place that would otherwise say out loud "a duress code exists and here is
    /// what it does".
    let isDuressSessionActive: Bool

    /// Builds the snapshot from the live service.
    ///
    /// **Fails closed on a duress session.** `FernletLockService.handleDuress` refuses to grant
    /// `.appLockSettings` to a duress PIN, so this screen should be unreachable during a decoy — but
    /// "should be unreachable" is not a property the single most disclosing screen in the app may
    /// rest on. If one ever did reach here it renders exactly what a phone with no duress code
    /// renders, and the service refuses every mutator behind it.
    @MainActor
    init(lockService: FernletLockService) {
        let duressSession = lockService.isDuressSessionActive
        self.init(
            hasDuressConfigured: duressSession ? false : lockService.hasDuressConfigured,
            configuredMode: duressSession ? nil : lockService.configuredDuressMode,
            hasRecoveryCustodian: duressSession ? false : lockService.hasRecoveryCustodian,
            hasSupersededRecoveryBlob: duressSession ? false : lockService.hasSupersededRecoveryBlob,
            isDuressSessionActive: duressSession
        )
    }

    /// Memberwise entry point for tests and previews.
    init(
        hasDuressConfigured: Bool,
        configuredMode: DuressMode?,
        hasRecoveryCustodian: Bool,
        hasSupersededRecoveryBlob: Bool = false,
        isDuressSessionActive: Bool = false
    ) {
        self.hasDuressConfigured = hasDuressConfigured
        self.configuredMode = configuredMode
        self.hasRecoveryCustodian = hasRecoveryCustodian
        self.hasSupersededRecoveryBlob = hasSupersededRecoveryBlob
        self.isDuressSessionActive = isDuressSessionActive
    }

    /// Whether `mode` may be chosen right now.
    ///
    /// Only ``DuressMode/recoveryLock`` is ever withheld, and only for reasons that would make it an
    /// unannounced permanent lock-out rather than a response: no enrolled custodian at all, or an
    /// enrolled custodian holding a SUPERSEDED key — one that opens the corpus from before this app
    /// lock but nothing written under it, so firing the response would destroy the live key and the
    /// ceremony would hand back the wrong one. `FernletLockService.configureDuress` refuses both
    /// pairings — this is the UI half of that refusal, not a substitute for it.
    func isSelectable(_ mode: DuressMode) -> Bool {
        guard !isDuressSessionActive else { return false }
        guard mode == .recoveryLock else { return true }
        return hasRecoveryCustodian && !hasSupersededRecoveryBlob
    }

    /// The one-line explanation shown under a response the user cannot pick yet, or nil when it is
    /// selectable. Never a bare disabled control: a greyed-out option with no reason is the kind of
    /// dead end this screen cannot afford.
    func unavailableReason(for mode: DuressMode) -> String? {
        guard !isSelectable(mode) else { return nil }
        guard !isDuressSessionActive else { return nil }
        if hasSupersededRecoveryBlob {
            return String(localized: "duress.mode.unavailable.supersededCustodian",
                          defaultValue: "Your recovery device holds the key from before this app lock. Set it up again before choosing this.",
                          comment: "Duress code screen: why 'Lock it away on your recovery device' can't be chosen — the recovery device was set up before the current app lock, so it holds an older key.")
        }
        return String(localized: "duress.mode.unavailable.noCustodian",
                      defaultValue: "Set up a recovery device below before choosing this.",
                      comment: "Duress code screen: why 'Lock it away on your recovery device' can't be chosen yet — no recovery device is set up. 'Below' is the recovery-device card on the same screen.")
    }

    /// Whether the enrolled recovery device may be removed.
    ///
    /// False while ``DuressMode/recoveryLock`` is the armed response, because that pairing is a trap
    /// rather than a configuration: the response destroys every local unlock key and the custodian is
    /// the only thing that gives them back. `FernletLockService.removeRecoveryCustodian()` throws in
    /// exactly this state; this is what stops the user reaching a button whose only outcome is an
    /// error.
    var canRemoveRecoveryCustodian: Bool {
        hasRecoveryCustodian && configuredMode != .recoveryLock
    }

    /// Why the remove button is withheld, or nil when it is offered.
    var recoveryRemovalRefusalReason: String? {
        guard hasRecoveryCustodian, !canRemoveRecoveryCustodian else { return nil }
        return String(localized: "duress.custodian.removalRefused",
                      defaultValue: "Change your duress response before removing this device.",
                      comment: "Duress code screen: shown instead of the Remove button for the recovery device while 'Lock it away on your recovery device' is the armed response.")
    }
}

// MARK: - Mode copy

/// The user-facing name, summary and consequence copy for each ``DuressMode``.
///
/// A separate namespace so the destructive wording has one home and can be reviewed as a unit —
/// the plan treats the copy on a destructive path as reviewable surface, not decoration.
///
/// `nonisolated` (the app target defaults to `MainActor`): pure `DuressMode` → `String` functions,
/// which SwiftUI's dialog title/message builders call from nonisolated positions. Every line is a
/// `String(localized:)` key (`duress.mode.*`): they are `String`s because the dialog builders and
/// the tests take resolved text, and a bare literal returned as `String` never reached a catalog.
nonisolated enum DuressModeCopy {
    /// The short name shown on the response card and in the status line.
    static func title(_ mode: DuressMode) -> String {
        switch mode {
        case .decoy:
            String(localized: "duress.mode.decoy.title", defaultValue: "Show an empty Fernlet",
                   comment: "Duress code response: the duress code opens an empty-looking Fernlet and deletes nothing.")
        case .silentWipe:
            String(localized: "duress.mode.silentWipe.title", defaultValue: "Erase everything, then show an empty Fernlet",
                   comment: "Duress code response: the duress code destroys the sealed data's keys, then opens an empty Fernlet.")
        case .recoveryLock:
            String(localized: "duress.mode.recoveryLock.title", defaultValue: "Lock it away on your recovery device",
                   comment: "Duress code response: the duress code locks this phone out; only the user's recovery device (another phone) can give the key back.")
        }
    }

    /// The one-sentence summary shown under the title on the card.
    static func summary(_ mode: DuressMode) -> String {
        switch mode {
        case .decoy:
            String(localized: "duress.mode.decoy.summary",
                   defaultValue: "Nothing is deleted. Your real passcode brings everything back.",
                   comment: "Duress code screen: the one-line summary under 'Show an empty Fernlet'.")
        case .silentWipe:
            String(localized: "duress.mode.silentWipe.summary",
                   defaultValue: "Your sealed notes become permanently unreadable, immediately.",
                   comment: "Duress code screen: the one-line summary under 'Erase everything, then show an empty Fernlet'.")
        case .recoveryLock:
            String(localized: "duress.mode.recoveryLock.summary",
                   defaultValue: "This phone loses its way in. Only your recovery device can open it again.",
                   comment: "Duress code screen: the one-line summary under 'Lock it away on your recovery device'.")
        }
    }

    /// The full consequence paragraph, shown on the selected card and repeated in the confirmation
    /// for the two destructive responses.
    static func detail(_ mode: DuressMode) -> String {
        switch mode {
        case .decoy:
            String(localized: "duress.mode.decoy.detail",
                   defaultValue: """
                       Entering your duress code opens Fernlet with nothing in it — no journal, no cycle \
                       history, no intimacy notes, and no sign that anything is hidden. Your data is untouched \
                       and sealed the whole time, and entering your real passcode brings it straight back.
                       """,
                   comment: "Duress code screen: the full description of the non-destructive response, shown when it is selected.")
        case .silentWipe:
            String(localized: "duress.mode.silentWipe.detail",
                   defaultValue: """
                       Entering your duress code destroys the keys to your sealed journal, cycle and intimacy \
                       notes before anything appears on screen. This cannot be undone, and it cannot be \
                       recovered from a backup. Fernlet then opens as a brand-new empty app whose passcode is \
                       the duress code you just typed, so there is no duress code left until you set a new \
                       one. Fernlet also clears the sealed entries, your Apple Health cycle and intimacy \
                       entries, and its cloud copies in the background — copies already sent to a friend's \
                       phone or sitting in a backup are unreadable, but they exist until that clearing or \
                       their own expiry reaches them.
                       """,
                   comment: "Duress code screen: the full consequence of the erase response, shown when it is selected and again in its confirmation. Every claim is load-bearing; translate it whole, never shorten it.")
        case .recoveryLock:
            String(localized: "duress.mode.recoveryLock.detail",
                   defaultValue: """
                       Entering your duress code destroys this phone's passcode, Face ID and keys, but keeps \
                       your sealed notes. Nobody holding this phone can open them — including you. They can be \
                       opened again only in person, with the recovery device you enrolled below. If that \
                       device is lost, erased, or reinstalls Fernlet, your sealed notes are gone for good.
                       """,
                   comment: "Duress code screen: the full consequence of the recovery-lock response, shown when it is selected and again in its confirmation. Every claim is load-bearing; translate it whole, never shorten it.")
        }
    }

    /// The confirmation-dialog title for a destructive response, or nil for the non-destructive one.
    static func armConfirmationTitle(_ mode: DuressMode) -> String? {
        switch mode {
        case .decoy:
            nil
        case .silentWipe:
            String(localized: "duress.mode.silentWipe.armTitle", defaultValue: "Arm the erase response?",
                   comment: "Title of the confirmation before the erase response is set as the duress code's response.")
        case .recoveryLock:
            String(localized: "duress.mode.recoveryLock.armTitle", defaultValue: "Arm the recovery lock?",
                   comment: "Title of the confirmation before the recovery-lock response is set as the duress code's response.")
        }
    }
}

// MARK: - Setup / manage screen

/// Settings → App lock → **Duress code**: choose one response, set or change the code, enrol or
/// remove the recovery device, or remove the duress code entirely.
///
/// Presented as a sheet from ``AppLockSettingsView``, which is itself behind the `.appLockSettings`
/// gate — so reaching this screen already proves the real passcode (see the file header). Every
/// mutation goes straight to `FernletLockService`; this view holds no key material and no duress
/// secret beyond the transient `@State` of the entry sheet, which clears it on every submission.
///
/// The screen deliberately does NOT tell the user whether the app "looks different" with a duress
/// code set, because it does not: the point of the feature is that a configured device and an
/// unconfigured one are indistinguishable from the outside, which is also why configuring one emits
/// no audit event.
struct DuressPINSetupView: View {
    /// The World's framed look (`b3-duress`): the sheet on paper with Done top right and its title
    /// inside, framed cards, the three responses as framed radio cards.
    @Environment(\.fernletFramedLook) private var look
    @Environment(FernletLockService.self) private var lockService
    @Environment(\.dismiss) private var dismiss

    /// The response the user has currently highlighted. Seeded from the configured response so
    /// re-opening the screen never silently proposes a different one.
    @State private var selectedMode: DuressMode = .decoy
    @State private var showEntrySheet = false
    @State private var showRemoveConfirm = false
    @State private var showRecoveryEnrollment = false
    @State private var showRecoveryRemoveConfirm = false
    @State private var pendingDestructiveMode: DuressMode?
    @State private var errorMessage: String?
    @State private var didSeedSelection = false

    var body: some View {
        content
        .tint(Color.moss)
        .onAppear {
            guard !didSeedSelection else { return }
            didSeedSelection = true
            selectedMode = lockService.configuredDuressMode ?? .decoy
        }
        .sheet(isPresented: $showEntrySheet) {
            DuressPINEntrySheet(mode: selectedMode) { result in
                switch result {
                case .configured: errorMessage = nil
                case .failed(let message): errorMessage = message
                }
            }
            .environment(lockService)
        }
        .sheet(isPresented: $showRecoveryEnrollment) {
            // Opened from the phone being protected, so the ceremony starts on that side instead of
            // asking a question this entry point already answered.
            DuressRecoveryEnrollmentSheet(initialRole: .protectedPhone)
                .environment(lockService)
        }
        // Alerts, not confirmation dialogs: on iOS 26 a `.confirmationDialog` renders as a popover
        // that SUPPRESSES the `.cancel`-role button, which on this screen meant arming an
        // irreversible response with no visible way back.
        .alert(
            pendingDestructiveMode.flatMap(DuressModeCopy.armConfirmationTitle) ?? "",
            isPresented: Binding(
                get: { pendingDestructiveMode != nil },
                set: { if !$0 { pendingDestructiveMode = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) { pendingDestructiveMode = nil }
            Button("I understand — continue", role: .destructive) {
                pendingDestructiveMode = nil
                showEntrySheet = true
            }
        } message: {
            Text(pendingDestructiveMode.map(DuressModeCopy.detail) ?? "")
        }
        .alert(
            "Remove duress code?",
            isPresented: $showRemoveConfirm
        ) {
            Button("Cancel", role: .cancel) { }
            Button("Remove duress code", role: .destructive) { removeDuress() }
        } message: {
            Text("Your duress code stops working. Your passcode and your data are untouched.")
        }
        .alert(
            "Remove recovery device?",
            isPresented: $showRecoveryRemoveConfirm
        ) {
            Button("Cancel", role: .cancel) { }
            Button("Remove recovery device", role: .destructive) { removeRecoveryCustodian() }
        } message: {
            Text("That phone can no longer recover this one. Your data is untouched — but if you arm the recovery lock again you will need to enrol a device first.")
        }
    }

    /// The screen itself: the scrolling stack of cards inside its navigation chrome. Split out of
    /// `body` so the sheets and confirmation dialogs read as one modifier chain (Power-of-10 R4).
    private var content: some View {
        let availability = DuressSetupAvailability(lockService: lockService)
        return NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    introCard
                    statusCard(availability)
                    if let errorMessage { errorBanner(errorMessage) }
                    responseCard(availability)
                    recoveryDeviceCard(availability)
                    commitCard(availability)
                    if availability.hasDuressConfigured { removeCard }
                }
                .padding(.horizontal, 18)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .fernletSheetStyle()
            // Done is the way out, trailing like every other "this screen is finished" control —
            // the leading slot is where the sibling lock sheets put Cancel. The title sits inside
            // the sheet (`b3-duress`).
            .fernletSheetToolbar(title: "Duress code", onDone: { dismiss() })
        }
        .fernletSheet()
    }

    /// Removes the duress code, surfacing the service's own refusal (it declines during a duress
    /// session, so a coercer who worked out that a duress code exists cannot delete it).
    private func removeDuress() {
        do {
            try lockService.removeDuress()
            errorMessage = nil
            selectedMode = .decoy
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Cards

    private var introCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("A second code you can give away")
                .font(look == nil ? .fernlet(.header) : FernletFramedFont.rowTitleBold)
                .foregroundStyle(look?.text ?? Color.bark)
            Text("If someone makes you unlock Fernlet, type your duress code instead of your passcode. Fernlet does what you choose below and looks completely normal doing it — no warning, no message, nothing on screen that says anything happened.")
                .font(look == nil ? .fernlet(.body) : FernletFramedFont.body)
                .foregroundStyle(look?.dim ?? Color.slate)
                .fernletWrappingText()
            Text("It works even while Fernlet is counting down from too many wrong attempts, and it never counts as a wrong attempt itself.")
                .font(look == nil ? .fernlet(.bodySmall) : FernletFramedFont.note)
                .foregroundStyle(look?.dim ?? Color.slate)
                .fernletWrappingText()
        }
        // Spans the column like the Status card below it, instead of hugging its longest line.
        .settingsCard()
    }

    private func statusCard(_ availability: DuressSetupAvailability) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Status")
            HStack(spacing: 12) {
                // The status as a framed square; its words say the state.
                Rectangle()
                    .fill(availability.hasDuressConfigured ? Color.moss : Color.softTaupe)
                    .frame(width: 10, height: 10)
                    .padding(2)
                    .background(look?.ink ?? Color.clear)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(availability.hasDuressConfigured ? "Duress code set" : "No duress code")
                        .font(look == nil ? .fernlet(.header) : FernletFramedFont.rowTitleBold)
                        .foregroundStyle(look?.text ?? Color.bark)
                        .accessibilityIdentifier("duress.status.title")
                    if let mode = availability.configuredMode {
                        Text(DuressModeCopy.title(mode))
                            .font(.fernlet(.labelSmall))
                            .foregroundStyle(Color.slate)
                            .fernletWrappingText()
                    }
                }
                Spacer()
            }
            Text(shapeNote)
                .font(look == nil ? .fernlet(.bodySmall) : FernletFramedFont.note)
                .foregroundStyle(look?.dim ?? Color.slate)
                .fernletWrappingText()
        }
        .settingsCard()
    }

    /// The three responses under their label, each its own framed radio card (`b3-duress`).
    private func responseCard(_ availability: DuressSetupAvailability) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("What it does")
            ForEach(DuressMode.allCases, id: \.self) { mode in
                modeCard(mode, availability: availability)
            }
        }
    }

    private func modeCard(_ mode: DuressMode, availability: DuressSetupAvailability) -> some View {
        let selectable = availability.isSelectable(mode)
        let isSelected = selectedMode == mode && selectable
        return Button {
            guard selectable else { return }
            selectedMode = mode
            errorMessage = nil
        } label: {
            if let look {
                framedModeCard(mode, availability: availability, isSelected: isSelected, look: look)
            } else {
                standardModeCard(mode, availability: availability, isSelected: isSelected)
            }
        }
        .buttonStyle(.plain)
        .disabled(!selectable)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityIdentifier("duress.mode.\(mode.accessibilitySuffix)")
    }

    /// One response as a framed radio card: its name in Fraunces (terracotta for the erase), its
    /// summary, the detail once chosen; dimmed with the reason when it can't be picked yet.
    private func framedModeCard(_ mode: DuressMode, availability: DuressSetupAvailability,
                                isSelected: Bool, look: FernletFramedLook) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 6) {
                Text(DuressModeCopy.title(mode))
                    .font(FernletFramedFont.cardTitle)
                    .foregroundStyle(mode == .silentWipe ? Color.terracottaInk : look.text)
                    .fernletWrappingText()
                Text(DuressModeCopy.summary(mode))
                    .font(FernletFramedFont.body)
                    .foregroundStyle(look.dim)
                    .fernletWrappingText()
                if isSelected {
                    Text(DuressModeCopy.detail(mode))
                        .font(FernletFramedFont.note)
                        .foregroundStyle(look.dim)
                        .fernletWrappingText()
                }
            }
            .opacity(availability.isSelectable(mode) ? 1 : 0.55)
            if let reason = availability.unavailableReason(for: mode) {
                // Outside the dim, deliberately: this is the readable reason the option is withheld.
                Text(reason)
                    .font(FernletFramedFont.note)
                    .foregroundStyle(Color.terracottaInk)
                    .fernletWrappingText()
            }
        }
        .modifier(LockRadioCardChrome(isSelected: isSelected, look: look))
    }

    /// Today's response card: a radio circle, the name and summary on parchment.
    private func standardModeCard(_ mode: DuressMode, availability: DuressSetupAvailability,
                                  isSelected: Bool) -> some View {
        let selectable = availability.isSelectable(mode)
        return VStack(alignment: .leading, spacing: 8) {
            // Only the OPTION is dimmed when it can't be picked — see the reason line below.
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(isSelected ? Color.moss : Color.slate)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(DuressModeCopy.title(mode))
                            .font(.fernlet(.label))
                            .foregroundStyle(mode == .silentWipe ? Color.terracottaInk : Color.bark)
                            .fernletWrappingText()
                        Text(DuressModeCopy.summary(mode))
                            .font(.fernlet(.bodySmall))
                            .foregroundStyle(Color.slate)
                            .fernletWrappingText()
                    }
                    Spacer(minLength: 0)
                }
                if isSelected {
                    Text(DuressModeCopy.detail(mode))
                        .font(.fernlet(.bodySmall))
                        .foregroundStyle(Color.slate)
                        .fernletWrappingText()
                }
            }
            .opacity(selectable ? 1 : 0.55)

            if let reason = availability.unavailableReason(for: mode) {
                // Outside the dim, deliberately: this is the readable reason the option is
                // withheld, and at 55% it was the least legible text on the card.
                Text(reason)
                    .font(.fernlet(.bodySmall))
                    .foregroundStyle(Color.terracottaInk)
                    .fernletWrappingText()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            isSelected ? Color.moss.opacity(0.06) : Color.parchment,
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(
                    isSelected ? Color.moss.opacity(0.4) : Color.bark.opacity(0.08),
                    lineWidth: 1
                )
        )
    }

    private func recoveryDeviceCard(_ availability: DuressSetupAvailability) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Recovery device")
            Text("The recovery lock needs a second phone of your own, enrolled in person. It holds the only copy of the key that can open this phone again — Fernlet never puts that key in the cloud, and there is no way to enrol a device remotely.")
                .font(.fernlet(.body))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()

            if availability.hasRecoveryCustodian {
                recoveryDeviceEnrolledBody(availability)
            } else {
                recoveryDeviceEnrollButton
            }
        }
        .settingsCard()
    }

    /// The enrolled branch of ``recoveryDeviceCard(_:)``: the confirmation row, the superseded-key
    /// warning, and the removal affordance (or the reason removal is refused).
    @ViewBuilder
    private func recoveryDeviceEnrolledBody(_ availability: DuressSetupAvailability) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.moss)
            Text("A recovery device is enrolled.")
                .font(.fernlet(.label))
                .foregroundStyle(Color.bark)
            Spacer()
        }
        .accessibilityIdentifier("duress.recovery.enrolled")

        if availability.hasSupersededRecoveryBlob {
            // The route back to everything from BEFORE this app lock still works — that is
            // why the enrollment was kept — but the key it holds cannot open a word written
            // since. Said out loud here because the recovery lock is refused over it, and a
            // greyed-out option whose reason lives on another card is a dead end.
            Text("This device holds the key from before your current app lock. It can still recover everything you wrote before then, but not what you have written since. Set it up again to cover both.")
                .font(.fernlet(.bodySmall))
                .foregroundStyle(Color.terracottaInk)
                .fernletWrappingText()
                .accessibilityIdentifier("duress.recovery.superseded")

            Button("Set up this device again") { showRecoveryEnrollment = true }
                .buttonStyle(.plain)
                .font(.fernlet(.label))
                .foregroundStyle(Color.moss)
                .accessibilityIdentifier("duress.recovery.reenroll")
        }

        if availability.canRemoveRecoveryCustodian {
            Button(role: .destructive) {
                showRecoveryRemoveConfirm = true
            } label: {
                Text("Remove recovery device")
                    .font(.fernlet(.label))
                    .foregroundStyle(Color.terracottaInk)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("duress.recovery.remove")
        } else if let refusal = availability.recoveryRemovalRefusalReason {
            Text(refusal)
                .font(.fernlet(.bodySmall))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()
        }
    }

    /// The un-enrolled branch of ``recoveryDeviceCard(_:)``.
    ///
    /// A moss OUTLINE, not a second filled button: two full-width filled moss buttons in adjacent
    /// cards left no way to tell which was the screen's real primary. The filled one is "Set duress
    /// code" below.
    private var recoveryDeviceEnrollButton: some View {
        Button { showRecoveryEnrollment = true } label: {
            Text("Set up a recovery device").frame(maxWidth: .infinity)
        }
        .buttonStyle(ActionPillButtonStyle(.secondary))
        .accessibilityIdentifier("duress.recovery.enroll")
    }

    private func commitCard(_ availability: DuressSetupAvailability) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                errorMessage = nil
                if DuressModeCopy.armConfirmationTitle(selectedMode) != nil {
                    pendingDestructiveMode = selectedMode
                } else {
                    showEntrySheet = true
                }
            } label: {
                // Two whole literals, so each is its own catalog key.
                (availability.hasDuressConfigured ? Text("Change duress code") : Text("Set duress code"))
                    .frame(maxWidth: .infinity)
            }
            // The screen's one framed primary (`b3-duress`); faded while the response can't be set.
            .buttonStyle(ActionPillButtonStyle(.primary))
            .disabled(!availability.isSelectable(selectedMode))
            .accessibilityIdentifier("duress.commit")

            Text(availability.hasDuressConfigured
                 ? "Changing the response asks for your duress code again — pick a code you have not used as your passcode."
                 : "Pick a code you have not used as your passcode. Fernlet will not accept the same one for both.")
                .font(.fernlet(.bodySmall))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()
                .padding(.horizontal, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Removing the duress code: the framed danger row (`.sr.danger`), no chevron.
    private var removeCard: some View {
        FernletFramedSection("Danger zone") {
            Button(role: .destructive) {
                showRemoveConfirm = true
            } label: {
                FernletRowLabel("Remove duress code", destructive: true)
            }
            .buttonStyle(FernletRowButtonStyle(showsChevron: false))
            .accessibilityIdentifier("duress.remove")
        }
    }

    /// The flow's error as the framed warning notice.
    private func errorBanner(_ message: String) -> some View {
        FernletNotice(text: Text(verbatim: message), tone: .warn) { EmptyView() }
            .accessibilityIdentifier("duress.error")
    }

    // MARK: Helpers

    /// The "same shape as your passcode" note, naming the configured credential kind. The duress code
    /// is validated against the CONFIGURED kind because the lock renders exactly one entry surface: a
    /// 6-digit duress code on a 4-digit install could never be typed.
    ///
    /// One whole sentence per kind. It used to splice an English noun phrase ("a 4-digit PIN") into
    /// one sentence, which a translator could neither see nor make agree.
    private var shapeNote: LocalizedStringKey {
        switch lockService.credentialKind {
        case .pin4:
            "Your duress code is the same shape as your passcode — a 4-digit PIN. If you change your passcode to a different type, set your duress code again so you can still type it."
        case .pin6:
            "Your duress code is the same shape as your passcode — a 6-digit PIN. If you change your passcode to a different type, set your duress code again so you can still type it."
        case .alphanumeric:
            "Your duress code is the same shape as your passcode — a password. If you change your passcode to a different type, set your duress code again so you can still type it."
        case nil:
            "Your duress code is the same shape as your passcode — the same kind of code. If you change your passcode to a different type, set your duress code again so you can still type it."
        }
    }

    /// Removes the enrolled custodian, surfacing the service's own refusal rather than a copy of it.
    ///
    /// The button is already withheld in the state that throws (``DuressSetupAvailability/
    /// canRemoveRecoveryCustodian``), so this catch is the backstop for the race where the response
    /// was armed from another surface while this screen was open — never the primary explanation.
    private func removeRecoveryCustodian() {
        do {
            try lockService.removeRecoveryCustodian()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Duress code entry

/// Passcode, then enter-then-confirm: the sheet that commits a duress code for one chosen response.
///
/// Mirrors the change-passcode flow's shape (`FernletNumericPad` for PINs, a `SecureField` for the
/// alphanumeric kind, auto-advance when the digit count fills) so the duress code is entered the same
/// way the real one is — a different-looking entry screen would be a tell in a screenshot. Like that
/// flow it opens on the real passcode (DPA-76), checked at once through a counted `.appLockSettings`
/// unlock: an App-lock page left open must not let whoever holds it test passcode guesses for free.
///
/// The entered secrets exist only in this view's `@State` and are cleared on every submission, match
/// failure and service error. Committing goes through
/// `FernletLockService.configureDuress(pin:mode:current:)`, which re-checks the passcode on the same
/// counted door and is what rejects a duress code equal to the real passcode; this view surfaces that
/// rejection verbatim instead of restating it, so the two can never disagree.
private struct DuressPINEntrySheet: View {
    /// How the sheet finished, reported to the parent so the error can be shown on the screen the
    /// user returns to rather than lost with the sheet.
    enum Result {
        /// The duress code was written.
        case configured
        /// The service refused; carries the message to display.
        case failed(String)
    }

    let mode: DuressMode
    let onFinish: (Result) -> Void

    @Environment(FernletLockService.self) private var lockService
    @Environment(\.dismiss) private var dismiss
    /// The World's framed look (`b3-duress-entry`): paper, the title inside, framed pad and dots.
    @Environment(\.fernletFramedLook) private var look

    /// The real passcode, typed on the first step and handed to `configureDuress` at commit.
    @State private var current = ""
    @State private var entry = ""
    @State private var confirmation = ""
    @State private var step: Step = .verify
    @State private var errorMessage: String?
    /// True while the passcode check or the `configureDuress` call is in flight — the one-at-a-time
    /// guard for Continue.
    @State private var isSubmitting = false

    var body: some View {
        NavigationStack {
            ZStack {
                (look?.paper ?? Color.parchment).ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Text(stepTitle)
                            .font(look == nil ? .fernlet(.header) : FernletFramedFont.cardTitle)
                            .foregroundStyle(look?.text ?? Color.bark)
                        stepExplanation
                            .font(look == nil ? .fernlet(.bodySmall) : FernletFramedFont.body)
                            .foregroundStyle(look?.dim ?? Color.slate)
                            .fernletWrappingText()

                        if let errorMessage {
                            FernletNotice(text: Text(verbatim: errorMessage), tone: .warn) { EmptyView() }
                                .accessibilityIdentifier("duress.entry.error")
                        }

                        entryField
                        Spacer(minLength: 0)
                    }
                    .padding(24)
                }
            }
            // The keypad is pinned above the safe area — thumb reach, and the same shape as the
            // lock gate — while the explanation above it scrolls.
            .safeAreaInset(edge: .bottom) {
                numericPadInset
            }
            // Cancel top left and the title inside the sheet (`b3-duress-entry`).
            .fernletSheetToolbar(title: "Duress code", onCancel: { dismiss() })
        }
        .tint(Color.moss)
        .fernletSheet()
    }

    /// The heading for the step in progress.
    private var stepTitle: LocalizedStringKey {
        switch step {
        case .verify: "Enter your passcode"
        case .enter: "Choose your duress code"
        case .confirm: "Enter it again"
        }
    }

    /// Why the step asks what it asks: the passcode step says why it is asked again seconds after
    /// the gate accepted it (an unexplained re-prompt reads as the app not having listened); the
    /// two duress steps repeat what the chosen response does.
    @ViewBuilder private var stepExplanation: some View {
        if step == .verify {
            Text("Your real passcode first, so only you can set or change a duress code.")
        } else {
            Text(DuressModeCopy.detail(mode))
        }
    }

    /// The secret the step in progress is typing into.
    private var activeEntry: Binding<String> {
        switch step {
        case .verify: $current
        case .enter: $entry
        case .confirm: $confirmation
        }
    }

    /// The password field's placeholder for the step in progress (the alphanumeric kind only).
    private var fieldPlaceholder: LocalizedStringKey {
        switch step {
        case .verify: "Current password"
        case .enter: "Duress password"
        case .confirm: "Confirm duress password"
        }
    }

    @ViewBuilder private var entryField: some View {
        let kind = lockService.credentialKind ?? .pin6
        if kind == .alphanumeric {
            VStack(alignment: .leading, spacing: 16) {
                SecureField(fieldPlaceholder, text: activeEntry, prompt: .fieldPrompt(fieldPlaceholder))
                    .textContentType(step == .verify ? .password : .newPassword)
                    .sheetTextInput()
                    .accessibilityIdentifier("duress.entry.field")
                Button { advance() } label: {
                    Text("Continue").frame(maxWidth: .infinity)
                }
                .buttonStyle(ActionPillButtonStyle(.primary))
                .disabled(isSubmitting)
                    .accessibilityIdentifier("duress.entry.continue")
            }
        } else {
            // Dots high, pad low (see `numericPadInset`) — the lock gate's shape, so the duress
            // code is typed exactly where the real passcode is. Being indistinguishable from a
            // normal unlock is the feature.
            duressPinDots(current: activeEntry.wrappedValue, total: pinLength)
                .frame(maxWidth: .infinity)
        }
    }

    /// How large the pinned pad is allowed to grow.
    ///
    /// This is the ONE pad host that cannot use `fernletLockPadPage()`. The pad here is a
    /// `safeAreaInset`, not scrolling content: an inset that grows takes its height off the top of
    /// the page it is inset into, so letting the tiles reach their accessibility-size height would
    /// squeeze the explanation above it — the copy that says what the armed duress response
    /// actually does — down to nothing, and no amount of scrolling would give it back.
    ///
    /// Capping the pad and letting the prose above it keep scaling is the right trade for a fixed
    /// bottom control: the digits still land at roughly 1.5× their base 24pt, well over double the
    /// 14pt they were before this round, and every key stays on screen at every text size.
    private static let padTypeSizeCap: DynamicTypeSize = .accessibility1

    /// The keypad, pinned to the bottom of the sheet. Empty for the alphanumeric kind, which types
    /// into a `SecureField` with the system keyboard instead.
    @ViewBuilder private var numericPadInset: some View {
        if (lockService.credentialKind ?? .pin6) != .alphanumeric {
            // Advances from the tap that fills the active step's entry (`onFilled`), not from three
            // `onChange`s, which a busy main thread can coalesce away and strand a full pad.
            FernletNumericPad(value: activeEntry, maxLength: pinLength) { advance() }
                .dynamicTypeSize(...Self.padTypeSizeCap)
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
                .background(look?.paper ?? Color.parchment)
        }
    }

    /// How many digits the configured credential kind takes.
    private var pinLength: Int {
        (lockService.credentialKind ?? .pin6) == .pin4 ? 4 : 6
    }

    /// Checks the passcode, advances from entry to confirmation, or commits.
    private func advance() {
        switch step {
        case .verify:
            verifyCurrent()
        case .enter:
            errorMessage = nil
            step = .confirm
        case .confirm:
            guard entry == confirmation else {
                confirmation = ""
                fail(String(localized: "duress.entry.mismatch",
                            defaultValue: "Those codes don't match. Try again.",
                            comment: "Duress code entry, confirm step: the second entry did not match the duress code."))
                return
            }
            commit()
        }
    }

    /// The change-passcode flow's `advanceFromVerifyOld` shape (DPA-76): the passcode is checked
    /// through a counted `.appLockSettings` unlock before a duress code can be chosen, so a wrong
    /// one costs an attempt on the ladder — and re-locks the page — instead of being free. A duress
    /// code typed here is answered exactly as at the lock screen.
    private func verifyCurrent() {
        guard !isSubmitting else { return }
        isSubmitting = true
        let passcode = current
        Task { @MainActor in
            defer { isSubmitting = false }
            do {
                _ = try await lockService.unlock(passcode: passcode, for: .appLockSettings)
                errorMessage = nil
                step = .enter
            } catch {
                current = ""
                fail(error.localizedDescription)
                // A pad entry that did not verify only empties its dots; say why out loud.
                FernletAnnouncer.system.announce(.error, resolved: error.localizedDescription)
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

    private func commit() {
        // R3 (bounded task fan-out): one commit in flight at a time. A second Continue before the
        // first `await` returns would call `configureDuress` — and `onFinish`/`dismiss` — twice.
        guard !isSubmitting else { return }
        isSubmitting = true
        let pin = entry
        let passcode = current
        Task { @MainActor in
            defer { isSubmitting = false }
            do {
                try await lockService.configureDuress(pin: pin, mode: mode, current: passcode)
                clearSecrets()
                // A12: the same `done` the change-passcode and lock setup flows play.
                FernletFeedback.system.play(.done)
                onFinish(.configured)
                dismiss()
            } catch {
                // Back to the first step with every field cleared: the rejection is almost always
                // "that is your passcode" or a format rule, which mean the whole code must be
                // re-chosen, and the passcode is not kept in memory past a failed submission.
                clearSecrets()
                step = .verify
                fail(error.localizedDescription)
                onFinish(.failed(error.localizedDescription))
            }
        }
    }

    /// Empties every secret this sheet holds.
    private func clearSecrets() {
        current = ""
        entry = ""
        confirmation = ""
    }

    /// The three sequential steps: the real passcode, then choose the code, then re-enter it.
    private enum Step { case verify, enter, confirm }
}

/// The filled/empty dot row above the numeric pad, matching the change-passcode flow's.
///
/// A private duplicate of `SettingsSheet`'s file-private `pinDotsRow` rather than a shared helper:
/// the two files render the same 14pt dots and hoisting them into `FernletUI` for six lines would
/// put a lock-specific primitive in the design system.
private func duressPinDots(current: String, total: Int) -> some View {
    // The same dots as the passcode sheets, so a duress code is typed exactly as the passcode is.
    SettingsPinDots(entered: current.count, total: total)
}

// MARK: - Accessibility naming

extension DuressMode {
    /// Stable, non-localized suffix for this response's accessibility identifiers.
    ///
    /// Derived from the case rather than the raw byte so a UI test reads as the response it means;
    /// the raw values are an on-device storage format and must stay decoupled from test selectors.
    var accessibilitySuffix: String {
        switch self {
        case .decoy: "decoy"
        case .silentWipe: "wipe"
        case .recoveryLock: "recoveryLock"
        }
    }
}
