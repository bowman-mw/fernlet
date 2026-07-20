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

public struct FernletLockSetupView: View {
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

    public init() {}

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

    private func finalizeSetup() {
        Task { @MainActor in
            do {
                let credential: FernletLockCredential
                switch selectedKind {
                case .pin4: credential = .pin4(passcode)
                case .pin6: credential = .pin6(passcode)
                case .alphanumeric: credential = .alphanumeric(passcode)
                }
                try await lockService.configure(credential: credential)

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

    private enum SetupStep {
        case kindPicker, entry, confirm, biometric
    }
}

// MARK: - Unlock view

public struct FernletLockView: View {
    @Environment(FernletLockService.self) private var lockService
    var onUnlocked: () -> Void
    var onResetRequested: (() -> Void)?

    @State private var passcode = ""
    @State private var errorMessage: String?
    @State private var isCheckingBiometric = false
    @State private var isUnlocking = false
    @State private var cooldownRemaining: TimeInterval = 0
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    public init(onUnlocked: @escaping () -> Void, onResetRequested: (() -> Void)? = nil) {
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
                    Text("\(4 - attempts) attempt\(4 - attempts == 1 ? "" : "s") remaining before lockout")
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

    private func attemptUnlock() {
        guard !isUnlocking else { return }
        errorMessage = nil
        isUnlocking = true
        Task { @MainActor in
            defer { isUnlocking = false }
            do {
                _ = try await lockService.unlock(passcode: passcode)
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

    private func triggerBiometric() {
        guard !isCheckingBiometric else { return }
        errorMessage = nil
        isCheckingBiometric = true
        Task { @MainActor in
            defer { isCheckingBiometric = false }
            do {
                _ = try await lockService.unlockWithBiometrics()
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

public struct FernletNumericPad: View {
    @Binding var value: String
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

public func biometricName(_ type: LABiometryType) -> String {
    switch type {
    case .faceID: "Face ID"
    case .touchID: "Touch ID"
    case .opticID: "Optic ID"
    default: "Biometrics"
    }
}

public func biometricSystemImage(_ type: LABiometryType) -> String {
    switch type {
    case .faceID: "faceid"
    case .touchID: "touchid"
    default: "person.badge.key"
    }
}
