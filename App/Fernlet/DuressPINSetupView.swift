// DuressPINSetupView.swift
// Fernlet
//
// Phase 7 (duress PIN), step 9: the screen where a duress code is chosen, changed and removed.
//
// It lives under Settings → App lock, which is a `.appLockSettings` surface the user must already
// have unlocked with the REAL passcode — biometrics can never be the first factor after launch
// (PIN-before-biometrics), they are suppressed outright during a duress session, and the duress path
// REFUSES to grant `.appLockSettings` at all (`FernletLockService.handleDuress`). So every call this
// screen makes is real-PIN-gated by construction rather than by a re-prompt of its own, which is
// exactly why `FernletLockService.configureDuress(pin:mode:)` takes no `current:` argument.
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
            return "Your recovery device holds the key from before this app lock. Set it up again before choosing this."
        }
        return "Set up a recovery device below before choosing this."
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
        return "Change your duress response before removing this device."
    }
}

// MARK: - Mode copy

/// The user-facing name, summary and consequence copy for each ``DuressMode``.
///
/// A separate namespace so the destructive wording has one home and can be reviewed as a unit —
/// the plan treats the copy on a destructive path as reviewable surface, not decoration.
///
/// `nonisolated` (the app target defaults to `MainActor`): pure `DuressMode` → `String` functions,
/// which SwiftUI's dialog title/message builders call from nonisolated positions.
nonisolated enum DuressModeCopy {
    /// The short name shown on the response card and in the status line.
    static func title(_ mode: DuressMode) -> String {
        switch mode {
        case .decoy: "Show an empty Fernlet"
        case .silentWipe: "Erase everything, then show an empty Fernlet"
        case .recoveryLock: "Lock it away on your recovery device"
        }
    }

    /// The one-sentence summary shown under the title on the card.
    static func summary(_ mode: DuressMode) -> String {
        switch mode {
        case .decoy:
            "Nothing is deleted. Your real passcode brings everything back."
        case .silentWipe:
            "Your sealed notes become permanently unreadable, immediately."
        case .recoveryLock:
            "This phone loses its way in. Only your recovery device can open it again."
        }
    }

    /// The full consequence paragraph, shown on the selected card and repeated in the confirmation
    /// for the two destructive responses.
    static func detail(_ mode: DuressMode) -> String {
        switch mode {
        case .decoy:
            """
            Entering your duress code opens Fernlet with nothing in it — no journal, no cycle \
            history, no intimacy notes, and no sign that anything is hidden. Your data is untouched \
            and sealed the whole time, and entering your real passcode brings it straight back.
            """
        case .silentWipe:
            """
            Entering your duress code destroys the keys to your sealed journal, cycle and intimacy \
            notes before anything appears on screen. This cannot be undone, and it cannot be \
            recovered from a backup. Fernlet then opens as a brand-new empty app whose passcode is \
            the duress code you just typed, so there is no duress code left until you set a new \
            one. Fernlet also clears the sealed entries, your Apple Health cycle and intimacy \
            entries, and its cloud copies in the background — copies already sent to a friend's \
            phone or sitting in a backup are unreadable, but they exist until that clearing or \
            their own expiry reaches them.
            """
        case .recoveryLock:
            """
            Entering your duress code destroys this phone's passcode, Face ID and keys, but keeps \
            your sealed notes. Nobody holding this phone can open them — including you. They can be \
            opened again only in person, with the recovery device you enrolled below. If that \
            device is lost, erased, or reinstalls Fernlet, your sealed notes are gone for good.
            """
        }
    }

    /// The confirmation-dialog title for a destructive response, or nil for the non-destructive one.
    static func armConfirmationTitle(_ mode: DuressMode) -> String? {
        switch mode {
        case .decoy: nil
        case .silentWipe: "Arm the erase response?"
        case .recoveryLock: "Arm the recovery lock?"
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
                .padding(20)
                .padding(.bottom, 20)
            }
            .scrollContentBackground(.hidden)
            .background(Color.parchment)
            .navigationTitle("Duress code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Trailing, like every other "this screen is finished" control — the leading slot
                // is where the sibling lock sheets put Cancel, and "Done" there read as one.
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .font(.fernlet(.label))
                        .foregroundStyle(Color.moss)
                }
            }
        }
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
                .font(.fernlet(.header))
                .foregroundStyle(Color.bark)
            Text("If someone makes you unlock Fernlet, type your duress code instead of your passcode. Fernlet does what you choose below and looks completely normal doing it — no warning, no message, nothing on screen that says anything happened.")
                .font(.fernlet(.body))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()
            Text("It works even while Fernlet is counting down from too many wrong attempts, and it never counts as a wrong attempt itself.")
                .font(.fernlet(.bodySmall))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()
        }
        // Spans the column like the Status card below it, instead of hugging its longest line.
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))
    }

    private func statusCard(_ availability: DuressSetupAvailability) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Status")
            HStack(spacing: 12) {
                Circle()
                    .fill(availability.hasDuressConfigured ? Color.moss : Color.softTaupe)
                    .frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 3) {
                    Text(availability.hasDuressConfigured ? "Duress code set" : "No duress code")
                        .font(.fernlet(.header))
                        .foregroundStyle(Color.bark)
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
            Text("Your duress code is the same shape as your passcode — \(kindNoun). If you change your passcode to a different type, set your duress code again so you can still type it.")
                .font(.fernlet(.bodySmall))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()
        }
        .padding(14)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))
    }

    private func responseCard(_ availability: DuressSetupAvailability) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("What it does")
            ForEach(DuressMode.allCases, id: \.self) { mode in
                modeCard(mode, availability: availability)
            }
        }
        .padding(14)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))
    }

    private func modeCard(_ mode: DuressMode, availability: DuressSetupAvailability) -> some View {
        let selectable = availability.isSelectable(mode)
        let isSelected = selectedMode == mode && selectable
        return Button {
            guard selectable else { return }
            selectedMode = mode
            errorMessage = nil
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                // Only the OPTION is dimmed when it can't be picked — see the reason line below.
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(isSelected ? Color.moss : Color.slate.opacity(0.4))
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
        .buttonStyle(.plain)
        .disabled(!selectable)
        .accessibilityIdentifier("duress.mode.\(mode.accessibilitySuffix)")
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))
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
        Button("Set up a recovery device") { showRecoveryEnrollment = true }
            .buttonStyle(.plain)
            .font(.fernlet(.label))
            .foregroundStyle(Color.moss)
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.vertical, 10)
            .background(Color.parchment, in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.moss.opacity(0.45), lineWidth: 1)
            )
            .accessibilityIdentifier("duress.recovery.enroll")
    }

    private func commitCard(_ availability: DuressSetupAvailability) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(availability.hasDuressConfigured ? "Change duress code" : "Set duress code") {
                errorMessage = nil
                if DuressModeCopy.armConfirmationTitle(selectedMode) != nil {
                    pendingDestructiveMode = selectedMode
                } else {
                    showEntrySheet = true
                }
            }
            .buttonStyle(.plain)
            .font(.fernlet(.label))
            .foregroundStyle(availability.isSelectable(selectedMode) ? Color.onMoss : Color.bark)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                Color.mossFill.opacity(availability.isSelectable(selectedMode) ? 1 : 0.55),
                in: RoundedRectangle(cornerRadius: 14)
            )
            .disabled(!availability.isSelectable(selectedMode))
            .accessibilityIdentifier("duress.commit")

            Text(availability.hasDuressConfigured
                 ? "Changing the response asks for your duress code again — pick a code you have not used as your passcode."
                 : "Pick a code you have not used as your passcode. Fernlet will not accept the same one for both.")
                .font(.fernlet(.bodySmall))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))
    }

    private var removeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Danger zone")
            Button(role: .destructive) {
                showRemoveConfirm = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "trash")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.terracottaInk)
                        .frame(width: 28)
                    Text("Remove duress code")
                        .font(.fernlet(.label))
                        .foregroundStyle(Color.terracottaInk)
                    Spacer()
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("duress.remove")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))
    }

    private func errorBanner(_ message: String) -> some View {
        Text(message)
            .font(.fernlet(.body))
            .foregroundStyle(Color.terracotta)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.terracotta.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            .fernletWrappingText()
            .accessibilityIdentifier("duress.error")
    }

    // MARK: Helpers

    /// How the configured credential kind reads in a sentence, for the "same shape as your passcode"
    /// note. The duress code is validated against the CONFIGURED kind because the lock renders
    /// exactly one entry surface: a 6-digit duress code on a 4-digit install could never be typed.
    private var kindNoun: String {
        switch lockService.credentialKind {
        case .pin4: "a 4-digit PIN"
        case .pin6: "a 6-digit PIN"
        case .alphanumeric: "a password"
        case nil: "the same kind of code"
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

/// Enter-then-confirm sheet that commits a duress code for one chosen response.
///
/// Mirrors the change-passcode flow's shape (`FernletNumericPad` for PINs, a `SecureField` for the
/// alphanumeric kind, auto-advance when the digit count fills) so the duress code is entered the same
/// way the real one is — a different-looking entry screen would be a tell in a screenshot.
///
/// The entered secret exists only in this view's `@State` and is cleared on every submission, match
/// failure and service error. Committing goes through `FernletLockService.configureDuress(pin:mode:)`,
/// which is what rejects a duress code equal to the real passcode; this view surfaces that rejection
/// verbatim instead of restating it, so the two can never disagree.
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

    @State private var entry = ""
    @State private var confirmation = ""
    @State private var step: Step = .enter
    @State private var errorMessage: String?
    /// True while a `configureDuress` call is in flight — the one-at-a-time guard for Continue.
    @State private var isSubmitting = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.parchment.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Text(step == .enter ? "Choose your duress code" : "Enter it again")
                            .font(.fernlet(.header))
                            .foregroundStyle(Color.bark)
                        Text(DuressModeCopy.detail(mode))
                            .font(.fernlet(.bodySmall))
                            .foregroundStyle(Color.slate)
                            .fernletWrappingText()

                        if let errorMessage {
                            Text(errorMessage)
                                .font(.fernlet(.body))
                                .foregroundStyle(Color.terracotta)
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.terracotta.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                                .fernletWrappingText()
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
            .navigationTitle("Duress code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Color.slate)
                }
            }
        }
        .tint(Color.moss)
    }

    @ViewBuilder private var entryField: some View {
        let kind = lockService.credentialKind ?? .pin6
        if kind == .alphanumeric {
            VStack(alignment: .leading, spacing: 16) {
                SecureField(step == .enter ? "Duress password" : "Confirm duress password",
                            text: step == .enter ? $entry : $confirmation)
                    .textContentType(.newPassword)
                    .sheetTextInput()
                    .accessibilityIdentifier("duress.entry.field")
                Button("Continue") { advance() }
                    .buttonStyle(.plain)
                    .font(.fernlet(.label))
                    .foregroundStyle(isSubmitting ? Color.bark : Color.onMoss)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        Color.mossFill.opacity(isSubmitting ? 0.55 : 1),
                        in: RoundedRectangle(cornerRadius: 14)
                    )
                    .disabled(isSubmitting)
                    .accessibilityIdentifier("duress.entry.continue")
            }
        } else {
            // Dots high, pad low (see `numericPadInset`) — the lock gate's shape, so the duress
            // code is typed exactly where the real passcode is. Being indistinguishable from a
            // normal unlock is the feature.
            duressPinDots(current: step == .enter ? entry : confirmation, total: pinLength)
                .frame(maxWidth: .infinity)
        }
    }

    /// The keypad, pinned to the bottom of the sheet. Empty for the alphanumeric kind, which types
    /// into a `SecureField` with the system keyboard instead.
    @ViewBuilder private var numericPadInset: some View {
        if (lockService.credentialKind ?? .pin6) != .alphanumeric {
            FernletNumericPad(value: step == .enter ? $entry : $confirmation, maxLength: pinLength)
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
                .background(Color.parchment)
                .onChange(of: entry) { _, new in
                    if step == .enter, new.count == pinLength { advance() }
                }
                .onChange(of: confirmation) { _, new in
                    if step == .confirm, new.count == pinLength { advance() }
                }
        }
    }

    /// How many digits the configured credential kind takes.
    private var pinLength: Int {
        (lockService.credentialKind ?? .pin6) == .pin4 ? 4 : 6
    }

    /// Advances from entry to confirmation, or commits.
    private func advance() {
        switch step {
        case .enter:
            errorMessage = nil
            step = .confirm
        case .confirm:
            guard entry == confirmation else {
                confirmation = ""
                errorMessage = "Those codes don't match. Try again."
                return
            }
            commit()
        }
    }

    private func commit() {
        // R3 (bounded task fan-out): one commit in flight at a time. A second Continue before the
        // first `await` returns would call `configureDuress` — and `onFinish`/`dismiss` — twice.
        guard !isSubmitting else { return }
        isSubmitting = true
        let pin = entry
        Task { @MainActor in
            defer { isSubmitting = false }
            do {
                try await lockService.configureDuress(pin: pin, mode: mode)
                entry = ""
                confirmation = ""
                onFinish(.configured)
                dismiss()
            } catch {
                // Back to the first step with both fields cleared: the rejection is almost always
                // "that is your passcode" or a format rule, and both mean the whole code must be
                // re-chosen rather than re-confirmed.
                entry = ""
                confirmation = ""
                step = .enter
                errorMessage = error.localizedDescription
                onFinish(.failed(error.localizedDescription))
            }
        }
    }

    /// The two sequential steps: choose the code, then re-enter it.
    private enum Step { case enter, confirm }
}

/// The filled/empty dot row above the numeric pad, matching the change-passcode flow's.
///
/// A private duplicate of `SettingsSheet`'s file-private `pinDotsRow` rather than a shared helper:
/// the two files render the same 14pt dots and hoisting them into `FernletUI` for six lines would
/// put a lock-specific primitive in the design system.
private func duressPinDots(current: String, total: Int) -> some View {
    HStack(spacing: 16) {
        ForEach(0..<total, id: \.self) { index in
            Circle()
                .fill(index < current.count ? Color.bark : Color.clear)
                .frame(width: 14, height: 14)
                .overlay(Circle().stroke(Color.bark.opacity(0.35), lineWidth: 1.5))
        }
    }
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
