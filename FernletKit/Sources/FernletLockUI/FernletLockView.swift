// FernletLockView.swift
// Fernlet
//
// FernletLockSetupView  — five-step first-time passcode configuration.
// FernletLockView       — unlock screen shown when the gate is locked.
// FernletNumericPad     — custom 3×4 numeric keypad used for PIN entry.

import SwiftUI
import LocalAuthentication
import Combine
import FernletDomainModel
import FernletFoundation
import FernletLock
import FernletUI

/// Copy shared by the lock setup flow and the lock gate's set-up call to action.
///
/// One constant rather than two hand-written sentences: the two screens are seen back to back (the
/// gate offers the sheet), and they used to name different things — "the period and intimacy
/// sections" against "journal, period, and intimacy history" — with neither mentioning the worry
/// box, which the same key also seals.
enum FernletLockCopy {
    /// What the app lock actually protects. Every surface behind ``FernletLockScope/privateHub``.
    static let protectsSentence = "Protects your journal, cycle, intimacy notes and worry box."
}

// MARK: - Setup view

/// Five-step first-time passcode configuration flow for the Fernlet app lock.
///
/// Walks the user through: lock-kind selection (4-digit PIN, 6-digit PIN, or 8–64 character
/// password), passcode entry, confirmation, an optional biometric-unlock toggle, and a
/// no-recovery disclosure sheet that must be acknowledged before anything is written. Only
/// after the disclosure is accepted does `finalizeSetup()` call
/// `FernletLockService.configure(credential:grantingScope:)` — which derives the Scrypt verifier and wraps
/// the content key in the keychain — and, if requested, `setBiometricEnabled(_:passcode:)`.
///
/// Presented as a sheet from the app's settings and privacy screens, the onboarding lock
/// step, and `FernletLockGateModifier`'s not-configured call-to-action overlay. Reads the
/// environment-injected `FernletLockService` (from the `FernletLock` module) and dismisses
/// itself after a brief success toast. If `configure` throws, the flow returns to the entry
/// step with both passcode fields cleared and the error shown inline. Runs on the main actor
/// (the module's default isolation).
///
/// - Important: The disclosure is not ceremonial, and it covers TWO loss modes, not one. A
///   forgotten passcode makes the sealed journal, cycle, and intimacy notes permanently
///   unreadable — and on Secure-Enclave hardware so does losing the device's enclave key (an
///   erase, an enclave reset, or a restore onto replacement hardware), because the content key is
///   hard-bound to it and a remembered passcode is not enough elsewhere. There is no recovery
///   path except the sealed backup.
public struct FernletLockSetupView: View {
    /// The surface whose unlock the freshly-created passcode grants. The user is authenticated at
    /// the moment they confirm it, so that one screen opens — but only that one, so setting a lock
    /// up from Settings doesn't also hand over the Private Hub.
    let grantingScope: FernletLockScope
    @Environment(FernletLockService.self) private var lockService
    @Environment(\.dismiss) private var dismiss

    @State private var step: SetupStep = .kindPicker
    @State private var selectedKind: FernletLockCredentialKind = .pin6
    @State private var passcode = ""
    @State private var confirmation = ""
    @State private var biometricEnabled = false
    @State private var showDisclosure = false
    @State private var errorMessage: String?
    @State private var showSuccess = false
    /// True when `configure` succeeded but the requested biometric enable did not — the toast then
    /// says so instead of reporting a success the user did not get.
    @State private var biometricSetupFailed = false
    /// One `configure()` in flight at a time (R3). Two taps on "I understand — set up lock" during
    /// the sheet's dismiss animation would otherwise run two concurrent configures that interleave
    /// at the scrypt awaits, and the second mint would replace the content key the first installed
    /// and sealed under.
    @State private var isFinalizing = false

    public init(grantingScope: FernletLockScope) {
        self.grantingScope = grantingScope
    }

    public var body: some View {
        NavigationStack {
            ZStack {
                Color.parchment.ignoresSafeArea()
                // Once the lock IS configured the wizard stops pretending it isn't: the live step
                // (with its tappable Cancel and Continue, which re-opened the disclosure) is
                // replaced by a settled "You're set" state while the toast dwells.
                if showSuccess {
                    completedStep
                        .padding(24)
                } else {
                    stepContent
                        .padding(24)
                }
            }
            .navigationTitle("Set up app lock")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !showSuccess {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                            .foregroundStyle(Color.slate)
                    }
                }
            }
        }
        .tint(Color.moss)
        .overlay {
            if showSuccess {
                successToast
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: showSuccess)
        .sheet(isPresented: $showDisclosure) {
            disclosureSheet
        }
    }

    // MARK: Step routing

    @ViewBuilder private var stepContent: some View {
        switch step {
        case .kindPicker:  kindPickerStep
        case .entry:       entryStep
        case .confirm:     confirmStep
        case .biometric:   biometricStep
        }
    }

    // MARK: Step 1 — kind picker

    private var kindPickerStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            SectionLabel("Choose a lock type")
            // One sentence, shared verbatim with the gate's set-up call to action: naming a
            // narrower set here than the gate did (and omitting the worry box from both) told the
            // user the lock covers less than it actually does.
            Text(FernletLockCopy.protectsSentence)
                .font(.fernlet(.bubble))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()

            VStack(spacing: 12) {
                kindCard(.pin4, title: "4-digit PIN", subtitle: "Fast, lower security")
                // The badge already says RECOMMENDED — the subtitle says something useful instead.
                kindCard(.pin6, title: "6-digit PIN", subtitle: "Good balance of speed and security", recommended: true)
                kindCard(.alphanumeric, title: "Password", subtitle: "8+ characters, highest security")
            }

            Spacer()

            actionButton("Continue") {
                passcode = ""
                confirmation = ""
                step = .entry
            }
        }
    }

    private func kindCard(_ kind: FernletLockCredentialKind, title: String, subtitle: String, recommended: Bool = false) -> some View {
        Button {
            selectedKind = kind
        } label: {
            HStack(spacing: 14) {
                Image(systemName: kind == selectedKind ? "checkmark.circle.fill" : "circle")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(kind == selectedKind ? Color.moss : Color.slate.opacity(0.4))

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(title)
                            .font(.fernlet(.headerMedium))
                            .foregroundStyle(Color.bark)
                        if recommended {
                            Text("RECOMMENDED")
                                .font(.fernlet(.labelSmall))
                                .foregroundStyle(Color.moss)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.moss.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                    Text(subtitle)
                        .font(.fernlet(.bodySmall))
                        .foregroundStyle(Color.slate)
                }
                Spacer()
            }
            .padding(16)
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

    // MARK: Step 2 — passcode entry

    private var entryStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            SectionLabel(selectedKind == .alphanumeric ? "Create password" : "Create PIN")
            Text(selectedKind == .alphanumeric
                 ? "Choose a password (8–64 characters)."
                 : "Enter your \(selectedKind == .pin4 ? "4" : "6")-digit PIN.")
                .font(.fernlet(.bubble))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()

            if let msg = errorMessage {
                errorBanner(msg)
            }

            if selectedKind == .alphanumeric {
                SecureField("Password", text: $passcode)
                    .textContentType(.newPassword)
                    .sheetTextInput()
            } else {
                pinDotsRow(current: passcode, total: selectedKind == .pin4 ? 4 : 6)
                FernletNumericPad(value: $passcode, maxLength: selectedKind == .pin4 ? 4 : 6)
            }

            Spacer()

            if selectedKind == .alphanumeric {
                actionButton("Continue", disabled: passcode.count < 8) {
                    errorMessage = nil
                    step = .confirm
                }
            }
        }
        .onChange(of: passcode) { _, new in
            let limit = selectedKind == .pin4 ? 4 : 6
            if selectedKind != .alphanumeric && new.count == limit {
                errorMessage = nil
                step = .confirm
            }
        }
    }

    // MARK: Step 3 — confirm passcode

    private var confirmStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            SectionLabel(selectedKind == .alphanumeric ? "Confirm password" : "Confirm PIN")
            Text("Re-enter to confirm.")
                .font(.fernlet(.bubble))
                .foregroundStyle(Color.slate)

            if let msg = errorMessage {
                errorBanner(msg)
            }

            if selectedKind == .alphanumeric {
                SecureField("Confirm password", text: $confirmation)
                    .textContentType(.newPassword)
                    .sheetTextInput()
            } else {
                pinDotsRow(current: confirmation, total: selectedKind == .pin4 ? 4 : 6)
                FernletNumericPad(value: $confirmation, maxLength: selectedKind == .pin4 ? 4 : 6)
            }

            Spacer()

            if selectedKind == .alphanumeric {
                actionButton("Continue", disabled: confirmation.isEmpty) {
                    validateAndAdvanceFromConfirm()
                }
            }
        }
        .onChange(of: confirmation) { _, new in
            let limit = selectedKind == .pin4 ? 4 : 6
            if selectedKind != .alphanumeric && new.count == limit {
                validateAndAdvanceFromConfirm()
            }
        }
    }

    /// Advances to the biometric step when the confirmation matches the original entry;
    /// otherwise shows the mismatch error and clears the confirmation field for retry.
    private func validateAndAdvanceFromConfirm() {
        if passcode == confirmation {
            errorMessage = nil
            step = .biometric
        } else {
            errorMessage = "Passcodes don't match. Try again."
            confirmation = ""
        }
    }

    // MARK: Step 4 — biometric toggle

    private var biometricStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            SectionLabel("Biometric unlock (optional)")

            let biometryName = biometricName(lockService.biometricType)
            Text("\(biometryName) lets you unlock quickly without entering your passcode. Your passcode is still required to change lock settings.")
                .font(.fernlet(.bubble))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()

            if lockService.biometricType != .none {
                Toggle(isOn: $biometricEnabled) {
                    Label("Enable \(biometryName)", systemImage: biometricSystemImage(lockService.biometricType))
                        .font(.fernlet(.label))
                        .foregroundStyle(Color.bark)
                }
                .toggleStyle(SwitchToggleStyle(tint: Color.moss))
                .padding(16)
                .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))
            } else {
                FernletCard { EmptyState(text: "No biometric authentication available on this device.") }
            }

            Spacer()

            actionButton("Continue") {
                showDisclosure = true
            }
        }
    }

    // MARK: Success state

    /// The settled state shown between a successful `configure` and the sheet dismissing itself —
    /// no live controls, so a second tap on a still-armed Continue can't re-open the disclosure for
    /// a lock that is already set up.
    private var completedStep: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(Color.moss)
            Text("You're set")
                .font(.fernlet(.header))
                .foregroundStyle(Color.bark)
            Text(FernletLockCopy.protectsSentence)
                .font(.fernlet(.bubble))
                .foregroundStyle(Color.slate)
                .multilineTextAlignment(.center)
                .fernletWrappingText()
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Disclosure sheet

    private var disclosureSheet: some View {
        NavigationStack {
            ZStack {
                Color.parchment.ignoresSafeArea()
                VStack(alignment: .leading, spacing: 20) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 40, weight: .semibold))
                        .foregroundStyle(Color.goldenrod)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)

                    Text("There is no recovery path")
                        .font(.fernlet(.header))
                        .foregroundStyle(Color.bark)

                    Text("If you forget your passcode, private journal, cycle, and intimacy notes will become permanently unreadable. HealthKit cycle and intimacy entries remain in Apple Health.")
                        .font(.fernlet(.body))
                        .foregroundStyle(Color.bark)
                        .fernletWrappingText()

                    // The second loss mode is strictly larger than the first, and it is new with
                    // hard Secure-Enclave binding: the key lives inside THIS device's enclave, so a
                    // remembered passcode does not help on erased or replacement hardware. Shown
                    // only where an enclave exists — SE-less hardware stays legacy forever and its
                    // scrypt-wrapped key really does restore, so the old copy is still true there.
                    if FernletLockService.isSecureEnclaveBindingAvailable {
                        Text("The same is true if this iPhone is erased, has its Secure Enclave reset, or is restored onto replacement hardware. The key lives inside this device's Secure Enclave and never leaves it.")
                            .font(.fernlet(.body))
                            .foregroundStyle(Color.bark)
                            .fernletWrappingText()

                        Text("Turn on Sealed backup for journal, cycle, and intimate logs in Privacy & Data to keep an encrypted copy that survives. Worry Box notes are never backed up and are always lost.")
                            .font(.fernlet(.bubble))
                            .foregroundStyle(Color.slate)
                            .fernletWrappingText()
                    }

                    Text("Only set a passcode if you're confident you'll remember it.")
                        .font(.fernlet(.bubble))
                        .foregroundStyle(Color.slate)
                        .fernletWrappingText()

                    Spacer()

                    actionButton("I understand — set up lock", disabled: isFinalizing) {
                        showDisclosure = false
                        finalizeSetup()
                    }

                    Button("Cancel") { showDisclosure = false }
                        .frame(maxWidth: .infinity)
                        .font(.fernlet(.label))
                        .foregroundStyle(Color.slate)
                        .padding(.bottom, 8)
                }
                .padding(24)
            }
            .navigationTitle("Before you set a passcode")
            .navigationBarTitleDisplayMode(.inline)
        }
        .tint(Color.moss)
    }

    /// How long the success toast dwells before the sheet dismisses itself.
    private static let successToastDwell: Duration = .seconds(1.5)

    /// Commits the configuration after the disclosure is acknowledged: builds the
    /// `FernletLockCredential` for the chosen kind, calls the lock service's
    /// `configure(credential:)`, optionally enables biometrics, then shows the success
    /// toast and dismisses. On a `configure` error the flow rewinds to the entry step
    /// with both fields cleared.
    ///
    /// At most ONE configure runs at a time (``isFinalizing``): concurrent configures would each
    /// mint a content key, and the loser's key is the one anything sealed in between was encrypted
    /// under.
    private func finalizeSetup() {
        guard !isFinalizing else { return }
        isFinalizing = true
        Task { @MainActor in
            defer { isFinalizing = false }
            do {
                let credential: FernletLockCredential
                switch selectedKind {
                case .pin4: credential = .pin4(passcode)
                case .pin6: credential = .pin6(passcode)
                case .alphanumeric: credential = .alphanumeric(passcode)
                }
                try await lockService.configure(credential: credential, grantingScope: grantingScope)

                if biometricEnabled {
                    do {
                        try await lockService.setBiometricEnabled(true, passcode: passcode)
                    } catch {
                        // The lock itself IS configured, so the flow still completes — but the user
                        // asked for Face ID/Touch ID and did not get it, and a toast that says
                        // otherwise is a lie the user would only discover at the next unlock.
                        biometricSetupFailed = true
                        FernletAuditLog.log("lock.setup.biometricEnableFailed")
                    }
                }

                withAnimation { showSuccess = true }
                do {
                    try await Task.sleep(for: Self.successToastDwell)
                } catch {
                    // Cancelled: skip the toast dwell and dismiss immediately.
                }
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                step = .entry
                passcode = ""
                confirmation = ""
            }
        }
    }

    // MARK: Helpers

    private func actionButton(_ title: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.fernlet(.label))
            // Contrast-safe pair: white on plain `moss` measures 4.29:1 in light mode and 2.53:1 in
            // dark. Disabled fades the FILL only, so the label stays readable.
            .foregroundStyle(disabled ? Color.bark : Color.onMoss)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                Color.mossFill.opacity(disabled ? 0.55 : 1),
                in: RoundedRectangle(cornerRadius: 16)
            )
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

    /// The toast copy. The lock is always configured by the time it appears; an opt-in biometric
    /// enable that FAILED is named here rather than hidden behind an unqualified success.
    private var successToastMessage: String {
        guard biometricSetupFailed else { return "App lock is set up." }
        return "App lock is set up. \(biometricName(lockService.biometricType)) couldn't be turned on — you can enable it in Settings → App lock."
    }

    private var successToast: some View {
        VStack {
            Spacer()
            HStack(spacing: 12) {
                Image(systemName: biometricSetupFailed ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(biometricSetupFailed ? Color.goldenrod : Color.moss)
                Text(successToastMessage)
                    .font(.fernlet(.body))
                    .foregroundStyle(Color.bark)
                    .fernletWrappingText()
                Spacer()
            }
            .padding(16)
            .background(Color.cream, in: RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal, 20)
            .padding(.bottom, 48)
        }
    }

    /// The four in-flow screens of the setup wizard, in order.
    ///
    /// Drives ``FernletLockSetupView``'s step routing; the fifth stage (the no-recovery
    /// disclosure) is a sheet layered over the biometric step rather than a case here.
    private enum SetupStep {
        case kindPicker, entry, confirm, biometric
    }
}

// MARK: - Unlock view

/// The unlock screen shown while the Fernlet app lock is engaged.
///
/// Renders the credential prompt matching the configured kind — a PIN-dot row plus
/// ``FernletNumericPad`` for PINs, or a secure password field — and hands the entry to
/// `FernletLockService.unlock(passcode:for:)`, which verifies it and unwraps the content key.
/// It mirrors the service's full failure-state machine:
///
/// - An attempt counter warns how many tries remain before the service's lockout
///   (`FernletLockService.attemptsPerCooldownBatch` failed attempts per cooldown batch).
/// - While a cooldown deadline is active, input is replaced by a countdown card refreshed by
///   a 1-second timer; when the deadline passes, the service state is refreshed so input
///   returns.
/// - When the service reports `requiresReset` (cooldown ladder exhausted), input is replaced
///   by a card explaining that only a destructive reset — invoked through `onResetRequested`,
///   since the confirmation dialog lives in the presenting context — can continue.
///
/// Biometrics are offered only while the service's single policy,
/// `FernletLockService.isBiometricUnlockAvailable`, is true — which requires one passcode
/// success (unlock or initial configure) in the current app process, so a cold-launched
/// locked app shows and auto-prompts no Face ID / Touch ID until the passcode has been
/// entered once. When available, `onAppear` additionally asks the service's
/// `consumeAutoBiometricPromptOpportunity()` before auto-triggering, so the prompt fires
/// once per lock session rather than on every recreation; a manual biometric button remains
/// available. Biometric failures fall back to passcode entry, and the service's own
/// fail-closed guard (`biometricNotAvailable` before the process's first passcode success)
/// lands in the same silent passcode fallback.
///
/// Used as `FernletLockGateModifier`'s overlay and directly by the app's progress-photo
/// timeline. Runs on the main actor (the module's default isolation); the lock service is
/// environment-injected.
public struct FernletLockView: View {
    @Environment(FernletLockService.self) private var lockService
    /// The surface being unlocked. A successful entry here opens THIS screen only — any unlock
    /// another locked screen was holding is revoked by the same call.
    var scope: FernletLockScope
    /// Called after any successful unlock (passcode or biometric); the gate overlay passes
    /// an empty closure because it disappears reactively, while sheet presenters use it
    /// to dismiss.
    var onUnlocked: () -> Void
    /// Invoked when the user taps "Reset app lock" on the reset-required card; the
    /// presenting context owns the destructive confirmation. When nil, no reset button
    /// is offered.
    var onResetRequested: (() -> Void)?

    @State private var passcode = ""
    @State private var errorMessage: String?
    @State private var isCheckingBiometric = false
    @State private var isUnlocking = false
    @State private var cooldownRemaining: TimeInterval = 0
    /// How many times IN A ROW a correct passcode has come back
    /// `FernletLockError.contentKeyUnrecoverable` on this screen. Reset by any other outcome.
    ///
    /// Two, not one, before the destructive card appears: the service classifies a keychain that
    /// merely would not answer as the retryable `.contentKeyTemporarilyUnavailable`, but nothing
    /// is free, and a second identical answer is cheap insurance against advising a user with a
    /// recoverable key to destroy it. On the first occurrence the passcode pad stays live and the
    /// message points at Face ID (which really can repair the wrap) instead.
    @State private var contentKeyUnrecoverableCount = 0
    /// One-second tick that keeps the cooldown countdown text current while a deadline
    /// is active.
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// Creates the unlock screen.
    ///
    /// - Parameters:
    ///   - scope: The surface this unlock grants. No default — an unlock belongs to exactly
    ///     one screen.
    ///   - onUnlocked: Called after a successful passcode or biometric unlock.
    ///   - onResetRequested: Optional handler for the reset-required card's destructive
    ///     reset button; omit it to hide the button.
    public init(scope: FernletLockScope, onUnlocked: @escaping () -> Void, onResetRequested: (() -> Void)? = nil) {
        self.scope = scope
        self.onUnlocked = onUnlocked
        self.onResetRequested = onResetRequested
    }

    public var body: some View {
        ZStack {
            Color.parchment.ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer()

                header

                // Error / cooldown feedback
                if let msg = errorMessage {
                    Text(msg)
                        .font(.fernlet(.body))
                        .foregroundStyle(Color.terracotta)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }

                // Attempt counter
                let attempts = lockService.currentAttemptCount
                if attempts > 0 && !isInputDisabled {
                    let remaining = FernletLockService.attemptsPerCooldownBatch - attempts
                    // Terracotta ink, not goldenrod: goldenrod on parchment measured about 2.2:1,
                    // and this line is the warning that the next mistakes cost a lockout.
                    Text("\(remaining) attempt\(remaining == 1 ? "" : "s") remaining before lockout")
                        .font(.fernlet(.labelSmall))
                        .foregroundStyle(Color.terracottaInk)
                }

                // Input
                if contentKeyUnrecoverableCount >= 2 {
                    // Checked FIRST: this state is not a failed attempt (requiresReset is false and
                    // stays false), so nothing else in this branch would ever surface it — and the
                    // reset it prescribes has to be reachable from the very screen that prescribes it.
                    contentKeyUnrecoverableCard
                } else {
                    // The lockout cards ACCOMPANY the entry surface; they no longer replace it.
                    // `FernletLockService.unlock` runs the duress compare before the `requiresReset`
                    // and cooldown guards precisely because lockout is when coercion is likeliest —
                    // and that property is unreachable if the pad the duress code is typed on has
                    // been swapped out for a countdown. A non-duress entry still refuses exactly as
                    // before (the guards below the compare are untouched) and still costs no attempt,
                    // so nothing here weakens the ladder: the real verifier is never even derived
                    // while a cooldown is in force.
                    if lockService.requiresReset {
                        resetRequiredCard
                    } else if isInputDisabled {
                        cooldownCard
                    }
                    inputSection
                }

                // Biometric button — isBiometricUnlockAvailable is the service's single
                // offer policy (enabled + usable biometry + one passcode success this
                // process); never restate its conjunction here.
                if !lockService.requiresReset && !isInputDisabled && lockService.isBiometricUnlockAvailable {
                    biometricButton
                }

                Spacer()
            }
            .padding(.horizontal, 32)
        }
        .onAppear {
            refreshCooldown()
            autoPromptBiometricIfEligible()
        }
        .onReceive(timer) { _ in refreshCooldown() }
        .animation(.easeInOut(duration: 0.2), value: errorMessage)
        .animation(.easeInOut(duration: 0.2), value: isInputDisabled)
    }

    /// How long the auto-prompt waits for the overlay to settle before presenting Face ID.
    private static let autoBiometricPromptDelay: Duration = .milliseconds(80)

    /// Presents the once-per-lock-session automatic biometric prompt, after a short settle delay.
    ///
    /// `isBiometricUnlockAvailable` includes `passcodeUnlockedThisProcess`, so a cold-launched
    /// locked app never auto-prompts Face ID before the process's first passcode success (the
    /// service guard is the fail-closed backstop).
    private func autoPromptBiometricIfEligible() {
        Task { @MainActor in
            do {
                try await Task.sleep(for: Self.autoBiometricPromptDelay)
            } catch {
                // Cancelled: neither spend the session's single auto-prompt opportunity nor raise
                // Face ID from a task that was asked to stop.
                return
            }
            guard lockService.isBiometricUnlockAvailable,
                  !lockService.requiresReset,
                  !isInputDisabled,
                  lockService.consumeAutoBiometricPromptOpportunity() else { return }
            triggerBiometric()
        }
    }

    // MARK: Sub-views

    /// The lock glyph, title and "enter your <credential>" line at the top of the unlock screen.
    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "lock.fill")
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(Color.moss)
                .frame(width: 72, height: 72)
                .background(Color.moss.opacity(0.10), in: Circle())

            Text("Fernlet Lock")
                .font(.fernlet(.header))
                .foregroundStyle(Color.bark)

            Text("Enter your \(credentialLabel) to continue.")
                .font(.fernlet(.bubble))
                .foregroundStyle(Color.slate)
        }
    }

    private var inputSection: some View {
        Group {
            if lockService.credentialKind == .alphanumeric {
                alphanumericInput
            } else {
                pinInput
            }
        }
    }

    private var pinInput: some View {
        let total = lockService.credentialKind == .pin4 ? 4 : 6
        return VStack(spacing: 24) {
            if isUnlocking {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(Color.moss)
                    .scaleEffect(1.2)
                    .frame(height: 28)
            } else {
                pinDotsRow(current: passcode, total: total)
            }
            FernletNumericPad(value: $passcode, maxLength: total)
                .opacity(isUnlocking ? 0.35 : 1)
                .allowsHitTesting(!isUnlocking)
        }
        .onChange(of: passcode) { _, new in
            if new.count == total { attemptUnlock() }
        }
        .animation(.easeInOut(duration: 0.15), value: isUnlocking)
    }

    private var alphanumericInput: some View {
        VStack(spacing: 16) {
            SecureField("Password", text: $passcode)
                .textContentType(.password)
                .sheetTextInput()
                .submitLabel(.go)
                .onSubmit { attemptUnlock() }
                .disabled(isUnlocking)

            ZStack {
                actionButton("Unlock") { attemptUnlock() }
                    .opacity(isUnlocking ? 0 : 1)
                if isUnlocking {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(Color.moss)
                }
            }
            .animation(.easeInOut(duration: 0.15), value: isUnlocking)
        }
    }

    private var cooldownCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.badge.exclamationmark")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(Color.goldenrod)

            Text("Too many failed attempts")
                .font(.fernlet(.header))
                .foregroundStyle(Color.bark)

            Text(cooldownDisplayText)
                .font(.fernlet(.body))
                .foregroundStyle(Color.slate)
                .multilineTextAlignment(.center)
        }
        .padding(20)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 18))
    }

    private var cooldownDisplayText: String {
        if cooldownRemaining > 3600 {
            return "Try again in \(Int(cooldownRemaining / 3600))h \(Int(cooldownRemaining.truncatingRemainder(dividingBy: 3600) / 60))m"
        } else if cooldownRemaining > 60 {
            return "Try again in \(Int(cooldownRemaining / 60))m \(Int(cooldownRemaining.truncatingRemainder(dividingBy: 60)))s"
        } else {
            return "Try again in \(Int(cooldownRemaining))s"
        }
    }

    private var resetRequiredCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(Color.terracotta)

            Text("Too many failed attempts")
                .font(.fernlet(.header))
                .foregroundStyle(Color.bark)

            Text("You must reset app lock to continue. Private journal, cycle, and intimacy notes will become permanently unreadable.")
                .font(.fernlet(.body))
                .foregroundStyle(Color.slate)
                .multilineTextAlignment(.center)
                .fernletWrappingText()

            if let onReset = onResetRequested {
                Button("Reset app lock", role: .destructive, action: onReset)
                    .font(.fernlet(.label))
                    .padding(.top, 4)
            }
        }
        .padding(20)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 18))
    }

    /// The terminal hard-binding card: the passcode was right and this device's Secure-Enclave key
    /// is gone, so the sealed notes are already unreadable.
    ///
    /// Its job is to make the remedy the error names actually reachable. `requiresReset` is false
    /// here (a correct passcode is not a failed attempt, and the service deliberately never
    /// records one), so `resetRequiredCard` — the app's only other route to `onResetRequested` —
    /// can never appear in this state; without this card the overlay would re-invite the passcode
    /// forever, and the Settings reset button sits behind an `.appLockSettings` gate. The copy is
    /// honest about what reset does and does NOT do: it clears the lock so the app is usable
    /// again, it does not recover anything. When a biometric copy of the key survives, that repair
    /// leads and the destructive button is explicitly framed as destroying it.
    private var contentKeyUnrecoverableCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.trianglebadge.exclamationmark.fill")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(Color.terracotta)

            Text("Sealed data can't be opened on this device")
                .font(.fernlet(.header))
                .foregroundStyle(Color.bark)
                .multilineTextAlignment(.center)
                .fernletWrappingText()

            Text("Your passcode was correct. This device's Secure Enclave key — the only thing that can open your sealed journal, cycle, and intimacy notes — is gone. Resetting app lock does not bring those notes back; it clears the lock so you can use Fernlet again.")
                .font(.fernlet(.body))
                .foregroundStyle(Color.slate)
                .multilineTextAlignment(.center)
                .fernletWrappingText()

            if canRepairWithBiometrics {
                Text("\(biometricName(lockService.biometricType)) can still open your notes on this device and repair its key. Try that first — resetting destroys that surviving copy.")
                    .font(.fernlet(.bubble))
                    .foregroundStyle(Color.bark)
                    .multilineTextAlignment(.center)
                    .fernletWrappingText()

                Button("Unlock with \(biometricName(lockService.biometricType))") { triggerBiometric() }
                    .font(.fernlet(.label))
                    .foregroundStyle(Color.moss)
                    .buttonStyle(.plain)
                    .disabled(isCheckingBiometric)
                    .padding(.top, 4)
            }

            if let onReset = onResetRequested {
                Button("Reset app lock", role: .destructive, action: onReset)
                    .font(.fernlet(.label))
                    .padding(.top, 4)
            }
        }
        .padding(20)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 18))
    }

    /// True while a `.biometryCurrentSet` copy of the content key survives AND biometrics may be
    /// offered — the state where the honest first move is a repair, not a destructive reset.
    private var canRepairWithBiometrics: Bool {
        lockService.isBiometricUnlockAvailable && lockService.hasBiometricRecoveryCopy
    }

    private var biometricButton: some View {
        Button {
            triggerBiometric()
        } label: {
            Label(
                biometricName(lockService.biometricType),
                systemImage: biometricSystemImage(lockService.biometricType)
            )
            .font(.fernlet(.label))
            .foregroundStyle(Color.moss)
        }
        .buttonStyle(.plain)
        .disabled(isCheckingBiometric)
    }

    // MARK: Actions

    /// Submits the entered passcode to `FernletLockService.unlock(passcode:for:)`, clearing the
    /// field on every outcome. A `cooldownActive` error silently switches to the countdown
    /// card; other errors surface inline. Re-entrant calls are ignored while a check is
    /// in flight.
    private func attemptUnlock() {
        guard !isUnlocking else { return }
        errorMessage = nil
        isUnlocking = true
        Task { @MainActor in
            defer { isUnlocking = false }
            do {
                _ = try await lockService.unlock(passcode: passcode, for: scope)
                passcode = ""
                contentKeyUnrecoverableCount = 0
                onUnlocked()
            } catch FernletLockError.cooldownActive {
                passcode = ""
                contentKeyUnrecoverableCount = 0
                refreshCooldown()
                errorMessage = nil
            } catch FernletLockError.resetRequired {
                passcode = ""
                contentKeyUnrecoverableCount = 0
                errorMessage = "Reset required."
            } catch FernletLockError.contentKeyUnrecoverable {
                // The passcode was RIGHT; this device's Secure Enclave key is gone, so the sealed
                // data is unopenable. Say so instead of inviting another attempt (nothing-silent).
                // The FIRST occurrence keeps the pad live and points at the biometric repair; the
                // second raises the card that actually offers the reset (see the count's doc).
                passcode = ""
                contentKeyUnrecoverableCount += 1
                errorMessage = canRepairWithBiometrics
                    ? "Your passcode was correct, but this device's key for sealed data is gone. Try \(biometricName(lockService.biometricType)) — it can still open and repair it."
                    : "Your passcode was correct, but sealed data can no longer be opened on this device. Enter it once more to confirm."
            } catch FernletLockError.contentKeyTemporarilyUnavailable(let status) {
                // NOT the terminal state: the keychain would not answer, which says nothing about
                // whether the key survives. Never advance the count, never mention reset.
                passcode = ""
                contentKeyUnrecoverableCount = 0
                errorMessage = FernletLockError.contentKeyTemporarilyUnavailable(status: status).errorDescription
            } catch {
                passcode = ""
                contentKeyUnrecoverableCount = 0
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Runs `FernletLockService.unlockWithBiometrics(for:)`. Unavailable biometrics fall back
    /// silently to passcode entry; recognition failures and reset-required states surface
    /// as inline messages. Re-entrant calls are ignored while a check is in flight.
    private func triggerBiometric() {
        guard !isCheckingBiometric else { return }
        errorMessage = nil
        isCheckingBiometric = true
        Task { @MainActor in
            defer { isCheckingBiometric = false }
            do {
                _ = try await lockService.unlockWithBiometrics(for: scope)
                // The bypass copy opened the corpus (and re-established the enclave wrap on the
                // way through), so the terminal state is over.
                contentKeyUnrecoverableCount = 0
                onUnlocked()
            } catch FernletLockError.biometricNotAvailable {
                // Quietly fall back to passcode entry.
            } catch FernletLockError.biometricFailed {
                errorMessage = "Face ID didn't recognize you. Try your passcode."
            } catch FernletLockError.resetRequired {
                errorMessage = "Too many attempts. Reset is required."
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Recomputes the remaining cooldown from the service's locked-state deadline; once the
    /// deadline passes it calls `lock(reason: .manual)` purely to make the service re-read
    /// (and clear) the expired deadline so input is re-enabled.
    private func refreshCooldown() {
        if case .locked(let deadline) = lockService.state, let d = deadline {
            cooldownRemaining = max(0, d.timeIntervalSinceNow)
            if cooldownRemaining == 0 {
                // Deadline passed — refresh state
                lockService.lock(reason: .manual)   // triggers re-read of deadline
            }
        } else {
            cooldownRemaining = 0
        }
    }

    // MARK: Helpers

    /// True while a future cooldown deadline is in force: the countdown card is shown ABOVE the
    /// entry surface (never instead of it — the duress code must stay typeable during a lockout),
    /// the attempts-remaining line is suppressed, and the biometric button is hidden, since
    /// biometrics may never step around a cooldown.
    private var isInputDisabled: Bool {
        if case .locked(let deadline) = lockService.state, let d = deadline, d > .now {
            return true
        }
        return false
    }

    private var credentialLabel: String {
        switch lockService.credentialKind {
        case .pin4: "4-digit PIN"
        case .pin6: "6-digit PIN"
        case .alphanumeric: "password"
        case nil: "passcode"
        }
    }

    private func actionButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.fernlet(.label))
            .foregroundStyle(Color.onMoss)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(Color.mossFill, in: RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - PIN dots row

/// Row of `total` circles with the first `current.count` filled — the masked progress
/// indicator shown above ``FernletNumericPad`` in both the setup and unlock flows.
///
/// Spoken as one element carrying a live count ("2 of 6 digits entered"). Without it the row is a
/// handful of decorative circles, and a VoiceOver user typing a PIN has no way to tell how many
/// digits have landed — the one piece of feedback the masked field exists to give.
private func pinDotsRow(current: String, total: Int) -> some View {
    HStack(spacing: 16) {
        ForEach(0..<total, id: \.self) { index in
            Circle()
                .fill(index < current.count ? Color.bark : Color.clear)
                .frame(width: 14, height: 14)
                .overlay(Circle().stroke(Color.bark.opacity(0.35), lineWidth: 1.5))
        }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(current.count) of \(total) digits entered")
}

// MARK: - Numeric pad

/// Custom 3×4 numeric keypad (digits 0–9 plus backspace) used for PIN entry.
///
/// A binding-driven input surface: taps append digits to `value` up to `maxLength` and the
/// backspace key removes the last one; callers react to the binding (both lock flows
/// auto-advance when the PIN reaches its full length). Used by ``FernletLockSetupView`` and
/// ``FernletLockView`` here, and by the app's passcode-change flows in `SettingsSheet`, in
/// place of the system keyboard so PIN entry stays visually consistent with the lock screens.
public struct FernletNumericPad: View {
    /// The PIN accumulated so far; owned by the caller, mutated one digit at a time.
    @Binding var value: String
    /// Maximum digit count (4 or 6 in practice); key presses beyond it are ignored.
    var maxLength: Int

    private let rows: [[String]] = [
        ["1", "2", "3"],
        ["4", "5", "6"],
        ["7", "8", "9"],
        ["", "0", "⌫"]
    ]

    public init(value: Binding<String>, maxLength: Int) {
        self._value = value
        self.maxLength = maxLength
    }

    public var body: some View {
        VStack(spacing: 12) {
            ForEach(rows, id: \.self) { row in
                HStack(spacing: 16) {
                    ForEach(row, id: \.self) { key in
                        padKey(key)
                    }
                }
            }
        }
    }

    private func padKey(_ key: String) -> some View {
        Button {
            handleKey(key)
        } label: {
            Group {
                if key == "⌫" {
                    Image(systemName: "delete.left")
                        .font(.title2.weight(.medium))
                } else if key.isEmpty {
                    Color.clear
                } else {
                    Text(key)
                        .font(.fernlet(.stat))
                }
            }
            .foregroundStyle(Color.bark)
            .frame(width: 76, height: 56)
            .background(key.isEmpty ? Color.clear : Color.cream, in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(key.isEmpty ? Color.clear : Color.bark.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(key.isEmpty)
    }

    private func handleKey(_ key: String) {
        if key == "⌫" {
            if !value.isEmpty { value.removeLast() }
        } else if !key.isEmpty, value.count < maxLength {
            value.append(key)
        }
    }
}

// MARK: - Biometric helpers (shared by Setup + Unlock)

/// User-facing name for a biometry type ("Face ID", "Touch ID", "Optic ID", or the generic
/// "Biometrics"), shared by the setup and unlock screens and the app's lock settings.
public func biometricName(_ type: LABiometryType) -> String {
    switch type {
    case .faceID: "Face ID"
    case .touchID: "Touch ID"
    case .opticID: "Optic ID"
    default: "Biometrics"
    }
}

/// SF Symbol name matching a biometry type, paired with ``biometricName(_:)`` wherever a
/// biometric label is rendered. Types without a dedicated symbol (including Optic ID) fall
/// back to "person.badge.key".
public func biometricSystemImage(_ type: LABiometryType) -> String {
    switch type {
    case .faceID: "faceid"
    case .touchID: "touchid"
    default: "person.badge.key"
    }
}
