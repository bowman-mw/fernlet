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
/// - Important: The disclosure is not ceremonial — a forgotten passcode makes the sealed
///   journal, cycle, and intimacy notes permanently unreadable; there is no recovery path.
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

    public init(grantingScope: FernletLockScope) {
        self.grantingScope = grantingScope
    }

    public var body: some View {
        NavigationStack {
            ZStack {
                Color.parchment.ignoresSafeArea()
                stepContent
                    .padding(24)
            }
            .navigationTitle("Set up app lock")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Color.slate)
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
            Text("Your lock type protects the period and intimacy sections.")
                .font(.fernlet(.bubble))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()

            VStack(spacing: 12) {
                kindCard(.pin4, title: "4-digit PIN", subtitle: "Fast, lower security")
                kindCard(.pin6, title: "6-digit PIN", subtitle: "Recommended", recommended: true)
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

                    Text("If you forget your passcode:")
                        .font(.fernlet(.header))
                        .foregroundStyle(Color.bark)

                    Text("Private journal, cycle, and intimacy notes will become permanently unreadable. HealthKit cycle and intimacy entries remain in Apple Health.")
                        .font(.fernlet(.body))
                        .foregroundStyle(Color.bark)
                        .fernletWrappingText()

                    Text("There is no recovery path. Only set a passcode if you're confident you'll remember it.")
                        .font(.fernlet(.bubble))
                        .foregroundStyle(Color.slate)
                        .fernletWrappingText()

                    Spacer()

                    actionButton("I understand — set up lock") {
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
            .navigationTitle("If you forget your passcode")
            .navigationBarTitleDisplayMode(.inline)
        }
        .tint(Color.moss)
    }

    /// Commits the configuration after the disclosure is acknowledged: builds the
    /// `FernletLockCredential` for the chosen kind, calls the lock service's
    /// `configure(credential:)`, optionally enables biometrics, then shows the success
    /// toast and dismisses. On a `configure` error the flow rewinds to the entry step
    /// with both fields cleared.
    private func finalizeSetup() {
        Task { @MainActor in
            do {
                let credential: FernletLockCredential
                switch selectedKind {
                case .pin4: credential = .pin4(passcode)
                case .pin6: credential = .pin6(passcode)
                case .alphanumeric: credential = .alphanumeric(passcode)
                }
                try await lockService.configure(credential: credential, grantingScope: grantingScope)

                if biometricEnabled {
                    try? await lockService.setBiometricEnabled(true, passcode: passcode)
                }

                withAnimation { showSuccess = true }
                try? await Task.sleep(for: .seconds(1.5))
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
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                disabled ? Color.moss.opacity(0.4) : Color.moss,
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

    private var successToast: some View {
        VStack {
            Spacer()
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.moss)
                Text("App lock is set up.")
                    .font(.fernlet(.body))
                    .foregroundStyle(Color.bark)
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
/// If biometric unlock is enabled, `onAppear` asks the service's
/// `consumeAutoBiometricPromptOpportunity()` before auto-triggering Face ID / Touch ID, so
/// the prompt fires once per lock session rather than on every recreation; a manual
/// biometric button remains available. Biometric failures fall back to passcode entry.
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

                // Header
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
                    Text("\(remaining) attempt\(remaining == 1 ? "" : "s") remaining before lockout")
                        .font(.fernlet(.labelSmall))
                        .foregroundStyle(Color.goldenrod)
                }

                // Input
                if lockService.requiresReset {
                    resetRequiredCard
                } else if isInputDisabled {
                    cooldownCard
                } else {
                    inputSection
                }

                // Biometric button
                if !lockService.requiresReset && !isInputDisabled && lockService.biometricEnabled && lockService.biometricType != .none {
                    biometricButton
                }

                Spacer()
            }
            .padding(.horizontal, 32)
        }
        .onAppear {
            refreshCooldown()
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(80))
                guard lockService.biometricEnabled,
                      !lockService.requiresReset,
                      !isInputDisabled,
                      lockService.consumeAutoBiometricPromptOpportunity() else { return }
                triggerBiometric()
            }
        }
        .onReceive(timer) { _ in refreshCooldown() }
        .animation(.easeInOut(duration: 0.2), value: errorMessage)
        .animation(.easeInOut(duration: 0.2), value: isInputDisabled)
    }

    // MARK: Sub-views

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
                onUnlocked()
            } catch FernletLockError.cooldownActive {
                passcode = ""
                refreshCooldown()
                errorMessage = nil
            } catch FernletLockError.resetRequired {
                passcode = ""
                errorMessage = "Reset required."
            } catch {
                passcode = ""
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

    /// True while a future cooldown deadline is in force, replacing the input section with
    /// the countdown card and hiding the biometric button.
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
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(Color.moss, in: RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - PIN dots row

/// Row of `total` circles with the first `current.count` filled — the masked progress
/// indicator shown above ``FernletNumericPad`` in both the setup and unlock flows.
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
