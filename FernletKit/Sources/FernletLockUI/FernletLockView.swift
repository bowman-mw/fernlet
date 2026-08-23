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

/// Copy shared by the lock setup flow and the lock gate's set-up call to action — and, since the
/// module started localizing, where the rest of the lock's long-form copy is resolved.
///
/// One constant rather than two hand-written sentences: the two screens are seen back to back (the
/// gate offers the sheet), and they used to name different things — "the period and intimacy
/// sections" against "journal, period, and intimacy history" — with neither mentioning the worry
/// box, which the same key also seals.
///
/// Why the rest of the copy moved in here rather than staying at the call sites. FernletLockUI is a
/// PACKAGE module, so every line has to name its bundle: a bare `Text("…")` literal is harvested
/// into *this* module's `Localizable.xcstrings` but looked up in `Bundle.main`, which never consults
/// a package bundle — it compiles clean, looks translated to a translator, and renders English
/// forever. `String(localized:bundle:.module)` is the fix and it costs three or four lines per
/// string; the disclosure sheet, the reset dialog and the unrecoverable-key card each carry four to
/// six paragraphs, so inlining pushed those `body` properties past the 60-line ceiling (Power of 10
/// R4). Short labels that title a single view stay inline, where the reader can still see them.
enum FernletLockCopy {
    /// What the app lock actually protects. Every surface behind ``FernletLockScope/privateHub``.
    static var protectsSentence: String {
        String(localized: "lock.protectsSentence",
               defaultValue: "Protects your journal, cycle, intimacy notes and worry box.",
               bundle: .module,
               comment: "Sub-heading on the app-lock setup screen, on the gate's set-up prompt, and on the 'You're set' screen. Names all four kinds of writing the one passcode seals; listing fewer would tell the user the lock covers less than it does.")
    }

    /// Placeholder in the password field — the same field on the setup screen and on the unlock
    /// screen, so it lives out here rather than under ``FernletLockCopy/Setup``.
    static var passwordFieldPlaceholder: String {
        String(localized: "lock.field.password", defaultValue: "Password", bundle: .module,
               comment: "Placeholder inside the secure text field where the app-lock password is typed, both when creating it and when unlocking.")
    }

    // MARK: Shared verbs

    /// The buttons that several lock screens share.
    ///
    /// One key each rather than one per screen: "Cancel" dismisses the setup sheet, the no-recovery
    /// disclosure and the reset dialog, and "Reset app lock" is the destructive button on three
    /// different cards. Per-screen keys would let the same button drift into three wordings inside
    /// one flow, in a language nobody here can proofread.
    enum Action {
        /// Leaves the current step without writing anything.
        static var cancel: String {
            String(localized: "lock.action.cancel", defaultValue: "Cancel", bundle: .module,
                   comment: "Button. Leaves app-lock setup, the no-recovery disclosure, or the reset confirmation without changing anything.")
        }

        /// Acknowledges an alert that reports something already done.
        static var ok: String {
            String(localized: "lock.action.ok", defaultValue: "OK", bundle: .module,
                   comment: "Button acknowledging an app-lock alert. It only dismisses — whatever the alert describes has already happened and cannot be declined.")
        }

        /// Advances one step of the setup wizard. `continue` is a keyword, hence the suffix.
        static var continueButton: String {
            String(localized: "lock.action.continue", defaultValue: "Continue", bundle: .module,
                   comment: "Button advancing to the next step of app-lock setup.")
        }

        /// Submits a typed password on the unlock screen.
        static var unlock: String {
            String(localized: "lock.action.unlock", defaultValue: "Unlock", bundle: .module,
                   comment: "Button submitting the typed password on the app-lock unlock screen.")
        }

        /// DESTRUCTIVE. Shown on the reset confirmation, the lockout card and the lost-key card.
        static var resetAppLock: String {
            String(localized: "lock.action.resetAppLock", defaultValue: "Reset app lock", bundle: .module,
                   comment: "Destructive button. Deletes the passcode AND permanently destroys the sealed journal, cycle and intimacy notes — it never recovers them. Do not translate as 'reset password', 'restore' or anything that suggests the notes come back.")
        }
    }

    // MARK: Numeric pad

    /// The PIN pad's spoken copy. Nothing here is ever drawn — ``FernletNumericPad`` renders a glyph
    /// and these are the words VoiceOver, Braille and Voice Control get instead.
    ///
    /// Shared by all three pad hosts (setup, unlock, and the app's passcode-change screens), which is
    /// why it sits at the top level of the vault rather than under ``FernletLockCopy/Unlock``.
    enum Pad {
        /// Name of the delete key, which draws as an SF Symbol and so has no text of its own.
        /// Voice Control users speak this word to press it.
        static var backspace: String {
            String(localized: "lock.pad.backspace", defaultValue: "Delete", bundle: .module,
                   comment: "Spoken name of the backspace key on the PIN pad; it draws as a left-pointing delete glyph with no text. Use the word your platform's own keypad uses for removing the last typed digit.")
        }
    }

    // MARK: Setup wizard

    /// The five-step passcode-setup wizard's own copy.
    ///
    /// Steps 1–4 are ordinary form copy; the consequences live in ``FernletLockCopy/Disclosure``,
    /// the sheet the last step opens before anything is written.
    enum Setup {
        /// Title of the sheet, and the heading of its first step.
        static var navTitle: String {
            String(localized: "lock.setup.navTitle", defaultValue: "Set up app lock", bundle: .module,
                   comment: "Title of the sheet that creates the app-lock passcode.")
        }

        /// Lock-type card: four digits.
        static var pin4Title: String {
            String(localized: "lock.setup.kind.pin4.title", defaultValue: "4-digit PIN", bundle: .module,
                   comment: "Title of the lock-type card for a four-digit numeric passcode.")
        }

        /// Lock-type card: four digits, the honest trade-off.
        static var pin4Subtitle: String {
            String(localized: "lock.setup.kind.pin4.subtitle", defaultValue: "Fast, lower security", bundle: .module,
                   comment: "Subtitle under the '4-digit PIN' card. Keep the warning half — this option really is the weakest of the three.")
        }

        /// Lock-type card: six digits, the recommended default.
        static var pin6Title: String {
            String(localized: "lock.setup.kind.pin6.title", defaultValue: "6-digit PIN", bundle: .module,
                   comment: "Title of the lock-type card for a six-digit numeric passcode.")
        }

        /// Lock-type card: six digits, why it is the default.
        static var pin6Subtitle: String {
            String(localized: "lock.setup.kind.pin6.subtitle", defaultValue: "Good balance of speed and security", bundle: .module,
                   comment: "Subtitle under the '6-digit PIN' card, which is the recommended option.")
        }

        /// Lock-type card: an alphanumeric password.
        static var passwordTitle: String {
            String(localized: "lock.setup.kind.password.title", defaultValue: "Password", bundle: .module,
                   comment: "Title of the lock-type card for an alphanumeric passcode. Standalone card title, not a text-field label.")
        }

        /// Lock-type card: the length rule and the trade-off.
        static var passwordSubtitle: String {
            String(localized: "lock.setup.kind.password.subtitle", defaultValue: "8+ characters, highest security", bundle: .module,
                   comment: "Subtitle under the 'Password' card. '8+' is an enforced minimum length, not a suggestion.")
        }

        /// The badge on the recommended card. Rendered uppercase by the label style.
        static var recommendedBadge: String {
            String(localized: "lock.setup.kind.recommendedBadge", defaultValue: "RECOMMENDED", bundle: .module,
                   comment: "Small badge on the recommended lock-type card. Uppercase in English; use whatever a badge normally looks like in the target language.")
        }

        /// Placeholder in the confirm-password field.
        static var confirmPasswordFieldPlaceholder: String {
            String(localized: "lock.field.confirmPassword", defaultValue: "Confirm password", bundle: .module,
                   comment: "Placeholder inside the secure text field where the app-lock password is typed a second time.")
        }

        /// The password step's length rule.
        static var passwordRule: String {
            String(localized: "lock.setup.entry.passwordRule",
                   defaultValue: "Choose a password (8–64 characters).",
                   bundle: .module,
                   comment: "Instruction on the password-creation step. Both bounds are enforced by the app.")
        }

        /// The PIN step's instruction. `digits` is 4 or 6, matching the card the user picked.
        static func pinRule(digits: Int) -> String {
            String(localized: "lock.setup.entry.pinRule",
                   defaultValue: "Enter your \(digits)-digit PIN.",
                   bundle: .module,
                   comment: "Instruction on the PIN-creation step. The number is 4 or 6, whichever lock type the user chose.")
        }

        /// The confirm step's instruction.
        static var confirmHint: String {
            String(localized: "lock.setup.confirmHint", defaultValue: "Re-enter to confirm.", bundle: .module,
                   comment: "Instruction on the step that asks for the new passcode a second time.")
        }

        /// Shown when the confirmation does not match the first entry.
        static var passcodeMismatch: String {
            String(localized: "lock.setup.error.passcodeMismatch",
                   defaultValue: "Passcodes don't match. Try again.",
                   bundle: .module,
                   comment: "Inline error when the confirmation passcode differs from the first entry. Nothing was saved; the user simply retypes.")
        }

        /// What opting into biometrics does — and what it deliberately does not cover.
        ///
        /// - Parameter biometry: "Face ID", "Touch ID", "Optic ID" or the generic fallback.
        static func biometricExplainer(_ biometry: String) -> String {
            String(localized: "lock.setup.biometric.explainer",
                   defaultValue: "\(biometry) lets you unlock quickly without entering your passcode. Your passcode is still required to change lock settings.",
                   bundle: .module,
                   comment: "Explains the optional biometric unlock during setup. The placeholder is an Apple product name (Face ID / Touch ID / Optic ID) and is not translated. The second sentence is a real limit, not reassurance — keep it.")
        }

        /// The biometric opt-in toggle.
        ///
        /// - Parameter biometry: "Face ID", "Touch ID", "Optic ID" or the generic fallback.
        static func enableBiometric(_ biometry: String) -> String {
            String(localized: "lock.setup.biometric.enableToggle",
                   defaultValue: "Enable \(biometry)",
                   bundle: .module,
                   comment: "Label of the switch that turns on biometric unlock. The placeholder is an Apple product name (Face ID / Touch ID / Optic ID) and is not translated.")
        }

        /// Heading of the settled state shown after the lock is configured.
        static var doneTitle: String {
            String(localized: "lock.setup.done.title", defaultValue: "You're set", bundle: .module,
                   comment: "Heading shown once the app lock has been created, while the sheet dismisses itself.")
        }

        /// The plain success toast.
        static var toastConfigured: String {
            String(localized: "lock.setup.toast.configured", defaultValue: "App lock is set up.", bundle: .module,
                   comment: "Toast confirming the app lock was created.")
        }

        /// The qualified toast: the lock exists, the biometric opt-in the user asked for did not take.
        ///
        /// - Parameter biometry: "Face ID", "Touch ID", "Optic ID" or the generic fallback.
        static func toastBiometricFailed(_ biometry: String) -> String {
            String(localized: "lock.setup.toast.biometricFailed",
                   defaultValue: "App lock is set up. \(biometry) couldn't be turned on — you can enable it in Settings → App lock.",
                   bundle: .module,
                   comment: "Toast when the lock was created but the biometric opt-in failed. Both halves matter: the lock IS on, the biometric unlock is NOT. 'Settings → App lock' is a path through the app's own settings; translate both names the same way they are translated on those screens.")
        }
    }

    // MARK: No-recovery disclosure

    /// The disclosure sheet shown immediately before a passcode is written.
    ///
    /// Every line here is a warning, and each one is literally true: there is no support path, no
    /// backdoor, and no reset that recovers anything. A translation that softens "will become
    /// permanently unreadable" into "you may lose access", or that hints at contacting support, is
    /// the difference between a user who accepted this trade and one who lost years of private
    /// writing believing it was recoverable. Translate the finality, not just the words.
    enum Disclosure {
        /// Title of the disclosure sheet.
        static var navTitle: String {
            String(localized: "lock.disclosure.navTitle", defaultValue: "Before you set a passcode", bundle: .module,
                   comment: "Title of the sheet that discloses the consequences of setting an app-lock passcode.")
        }

        /// The headline. The strongest sentence in the app.
        static var title: String {
            String(localized: "lock.disclosure.title", defaultValue: "There is no recovery path", bundle: .module,
                   comment: "Headline of the no-recovery disclosure. Literally true: no support channel, no backup code, no way back. Do not soften it into 'recovery may be difficult'.")
        }

        /// Loss mode one: a forgotten passcode.
        static var forgottenPasscode: String {
            String(localized: "lock.disclosure.forgottenPasscode",
                   defaultValue: "If you forget your passcode, private journal, cycle, and intimacy notes will become permanently unreadable. HealthKit cycle and intimacy entries remain in Apple Health.",
                   bundle: .module,
                   comment: "First loss mode in the no-recovery disclosure. 'Permanently unreadable' means the data is destroyed for practical purposes — no support path exists. The second sentence is the one piece of good news and must stay accurate: the clinical samples in Apple Health are untouched, only Fernlet's own notes are lost.")
        }

        /// Loss mode two, on Secure-Enclave hardware: losing the device's key, passcode or not.
        static var enclaveLoss: String {
            String(localized: "lock.disclosure.enclaveLoss",
                   defaultValue: "The same is true if this iPhone is erased, has its Secure Enclave reset, or is restored onto replacement hardware. The key lives inside this device's Secure Enclave and never leaves it.",
                   bundle: .module,
                   comment: "Second loss mode, strictly larger than the first: remembering the passcode does not help on erased or replacement hardware. 'Secure Enclave' is Apple hardware terminology — use whatever Apple's own localization uses.")
        }

        /// The one thing that survives loss mode two, and the one thing that never does.
        static var sealedBackup: String {
            String(localized: "lock.disclosure.sealedBackup",
                   defaultValue: "Turn on Sealed backup for journal, cycle, and intimate logs in Privacy & Data to keep an encrypted copy that survives. Worry Box notes are never backed up and are always lost.",
                   bundle: .module,
                   comment: "The only mitigation offered, plus its exception. 'Sealed backup' and 'Privacy & Data' are names of a setting and a settings screen in this app — translate them the same way they are translated there. The last sentence is an absolute: Worry Box notes have no backup at all.")
        }

        /// The ask.
        static var onlyIfConfident: String {
            String(localized: "lock.disclosure.onlyIfConfident",
                   defaultValue: "Only set a passcode if you're confident you'll remember it.",
                   bundle: .module,
                   comment: "Closing line of the no-recovery disclosure, asking the user to opt out if unsure.")
        }

        /// The acknowledgement that actually creates the lock.
        static var confirmButton: String {
            String(localized: "lock.disclosure.confirmButton",
                   defaultValue: "I understand — set up lock",
                   bundle: .module,
                   comment: "Button that acknowledges the no-recovery disclosure and creates the lock. The first half is the user asserting they read the warnings, so keep it in the first person.")
        }
    }
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
                Group {
                    if showSuccess {
                        completedStep
                    } else {
                        stepContent
                    }
                }
                .padding(24)
                // The entry and confirm steps host the shared pad, and passcode CREATION is
                // mandatory and un-skippable — there is no route past it if the bottom row of keys
                // is off-screen at an accessibility text size.
                .fernletLockPadPage()
            }
            .navigationTitle(FernletLockCopy.Setup.navTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !showSuccess {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(FernletLockCopy.Action.cancel) { dismiss() }
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
            // Package module: a bare `LocalizedStringKey` literal here would be harvested into
            // FernletLockUI's bundle but looked up in `Bundle.main`, which never consults it — so
            // it would read as English forever with a clean build. Resolve against `.module` and
            // hand the finished string to `verbatim:`.
            SectionLabel(verbatim: String(localized: "lock.chooseType", defaultValue: "Choose a lock type",
                                          bundle: .module,
                                          comment: "Header above the PIN/password lock-type picker"))
            // One sentence, shared verbatim with the gate's set-up call to action: naming a
            // narrower set here than the gate did (and omitting the worry box from both) told the
            // user the lock covers less than it actually does.
            Text(FernletLockCopy.protectsSentence)
                .font(.fernlet(.bubble))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()

            VStack(spacing: 12) {
                kindCard(.pin4, title: FernletLockCopy.Setup.pin4Title,
                         subtitle: FernletLockCopy.Setup.pin4Subtitle)
                // The badge already says RECOMMENDED — the subtitle says something useful instead.
                kindCard(.pin6, title: FernletLockCopy.Setup.pin6Title,
                         subtitle: FernletLockCopy.Setup.pin6Subtitle, recommended: true)
                kindCard(.alphanumeric, title: FernletLockCopy.Setup.passwordTitle,
                         subtitle: FernletLockCopy.Setup.passwordSubtitle)
            }

            Spacer()

            actionButton(FernletLockCopy.Action.continueButton) {
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
                            Text(FernletLockCopy.Setup.recommendedBadge)
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
            SectionLabel(verbatim: selectedKind == .alphanumeric
                ? String(localized: "lock.createPassword", defaultValue: "Create password",
                         bundle: .module, comment: "Header when creating an alphanumeric app lock")
                : String(localized: "lock.createPIN", defaultValue: "Create PIN",
                         bundle: .module, comment: "Header when creating a numeric app lock"))
            Text(selectedKind == .alphanumeric
                 ? FernletLockCopy.Setup.passwordRule
                 : FernletLockCopy.Setup.pinRule(digits: selectedKind == .pin4 ? 4 : 6))
                .font(.fernlet(.bubble))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()

            if let msg = errorMessage {
                errorBanner(msg)
            }

            if selectedKind == .alphanumeric {
                SecureField(FernletLockCopy.passwordFieldPlaceholder, text: $passcode)
                    .textContentType(.newPassword)
                    .sheetTextInput()
            } else {
                pinDotsRow(current: passcode, total: selectedKind == .pin4 ? 4 : 6)
                FernletNumericPad(value: $passcode, maxLength: selectedKind == .pin4 ? 4 : 6)
            }

            Spacer()

            if selectedKind == .alphanumeric {
                actionButton(FernletLockCopy.Action.continueButton, disabled: passcode.count < 8) {
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
            SectionLabel(verbatim: selectedKind == .alphanumeric
                ? String(localized: "lock.confirmPassword", defaultValue: "Confirm password",
                         bundle: .module, comment: "Header when re-entering an alphanumeric app lock")
                : String(localized: "lock.confirmPIN", defaultValue: "Confirm PIN",
                         bundle: .module, comment: "Header when re-entering a numeric app lock"))
            Text(FernletLockCopy.Setup.confirmHint)
                .font(.fernlet(.bubble))
                .foregroundStyle(Color.slate)

            if let msg = errorMessage {
                errorBanner(msg)
            }

            if selectedKind == .alphanumeric {
                SecureField(FernletLockCopy.Setup.confirmPasswordFieldPlaceholder, text: $confirmation)
                    .textContentType(.newPassword)
                    .sheetTextInput()
            } else {
                pinDotsRow(current: confirmation, total: selectedKind == .pin4 ? 4 : 6)
                FernletNumericPad(value: $confirmation, maxLength: selectedKind == .pin4 ? 4 : 6)
            }

            Spacer()

            if selectedKind == .alphanumeric {
                actionButton(FernletLockCopy.Action.continueButton, disabled: confirmation.isEmpty) {
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
            errorMessage = FernletLockCopy.Setup.passcodeMismatch
            confirmation = ""
        }
    }

    // MARK: Step 4 — biometric toggle

    private var biometricStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            SectionLabel(verbatim: String(localized: "lock.biometricHeader",
                                          defaultValue: "Biometric unlock (optional)",
                                          bundle: .module,
                                          comment: "Header above the Face ID / Touch ID opt-in"))

            let biometryName = biometricName(lockService.biometricType)
            Text(FernletLockCopy.Setup.biometricExplainer(biometryName))
                .font(.fernlet(.bubble))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()

            if lockService.biometricType != .none {
                Toggle(isOn: $biometricEnabled) {
                    Label(FernletLockCopy.Setup.enableBiometric(biometryName),
                          systemImage: biometricSystemImage(lockService.biometricType))
                        .font(.fernlet(.label))
                        .foregroundStyle(Color.bark)
                }
                .toggleStyle(SwitchToggleStyle(tint: Color.moss))
                .padding(16)
                .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))
            } else {
                FernletCard {
                    EmptyState(verbatim: String(localized: "lock.noBiometrics",
                                                defaultValue: "No biometric authentication available on this device.",
                                                bundle: .module,
                                                comment: "Shown when the device has no Face ID or Touch ID"))
                }
            }

            Spacer()

            actionButton(FernletLockCopy.Action.continueButton) {
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
            Text(FernletLockCopy.Setup.doneTitle)
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

                    Text(FernletLockCopy.Disclosure.title)
                        .font(.fernlet(.header))
                        .foregroundStyle(Color.bark)

                    Text(FernletLockCopy.Disclosure.forgottenPasscode)
                        .font(.fernlet(.body))
                        .foregroundStyle(Color.bark)
                        .fernletWrappingText()

                    // The second loss mode is strictly larger than the first, and it is new with
                    // hard Secure-Enclave binding: the key lives inside THIS device's enclave, so a
                    // remembered passcode does not help on erased or replacement hardware. Shown
                    // only where an enclave exists — SE-less hardware stays legacy forever and its
                    // scrypt-wrapped key really does restore, so the old copy is still true there.
                    if FernletLockService.isSecureEnclaveBindingAvailable {
                        Text(FernletLockCopy.Disclosure.enclaveLoss)
                            .font(.fernlet(.body))
                            .foregroundStyle(Color.bark)
                            .fernletWrappingText()

                        Text(FernletLockCopy.Disclosure.sealedBackup)
                            .font(.fernlet(.bubble))
                            .foregroundStyle(Color.slate)
                            .fernletWrappingText()
                    }

                    Text(FernletLockCopy.Disclosure.onlyIfConfident)
                        .font(.fernlet(.bubble))
                        .foregroundStyle(Color.slate)
                        .fernletWrappingText()

                    Spacer()

                    actionButton(FernletLockCopy.Disclosure.confirmButton, disabled: isFinalizing) {
                        showDisclosure = false
                        finalizeSetup()
                    }

                    Button(FernletLockCopy.Action.cancel) { showDisclosure = false }
                        .frame(maxWidth: .infinity)
                        .font(.fernlet(.label))
                        .foregroundStyle(Color.slate)
                        .padding(.bottom, 8)
                }
                .padding(24)
            }
            .navigationTitle(FernletLockCopy.Disclosure.navTitle)
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
        guard biometricSetupFailed else { return FernletLockCopy.Setup.toastConfigured }
        return FernletLockCopy.Setup.toastBiometricFailed(biometricName(lockService.biometricType))
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

// MARK: - Unlock copy

extension FernletLockCopy {
    /// The unlock screen's copy — the prompt, the lockout ladder, and the two terminal cards.
    ///
    /// Three things a translator must not soften here. The attempts line is a countdown to a real
    /// lockout, not a hint. The lockout cards describe a ladder that ends in a reset that destroys
    /// the sealed notes. And the lost-key card is reached only when the passcode was CORRECT — the
    /// user did nothing wrong, the device's key is gone, and the notes are already unreadable; copy
    /// that reads like a retry prompt would send them round the loop forever.
    ///
    /// Kept in the vault rather than inline because these lines are long, several are shared by two
    /// cards, and the `body` properties that render them are already near the 60-line ceiling.
    enum Unlock {
        /// The lock screen's own title. "Fernlet" is the product name and stays as it is.
        static var title: String {
            String(localized: "lock.unlock.title", defaultValue: "Fernlet Lock", bundle: .module,
                   comment: "Title on the app-lock unlock screen. 'Fernlet' is the app's name and is not translated.")
        }

        /// The prompt under the title.
        ///
        /// - Parameter credential: One of the ``credentialPIN4``/``credentialPIN6``/
        ///   ``credentialPassword``/``credentialPasscode`` labels, already localized.
        static func prompt(credential: String) -> String {
            String(localized: "lock.unlock.prompt",
                   defaultValue: "Enter your \(credential) to continue.",
                   bundle: .module,
                   comment: "Prompt on the unlock screen. The placeholder is the lock-type name in mid-sentence form ('4-digit PIN', '6-digit PIN', 'password', 'passcode') — the four lock.credential.* strings, which should be cased and inflected to fit this sentence.")
        }

        /// How many tries are left before the cooldown ladder starts.
        ///
        /// Two whole sentences chosen by a count check, because the English this replaced built the
        /// plural by splicing an "s" onto "attempt" — a construction that cannot survive translation
        /// into any language with more than two plural forms, or with a plural that changes the
        /// noun's stem. The eventual fix is one key with a proper plural variation in the string
        /// catalog (`.stringsdict`-style), authored through Xcode rather than by hand; until then
        /// two keys are at least translatable, and a translator can leave the "other" form covering
        /// every non-singular case.
        static func attemptsRemaining(_ remaining: Int) -> String {
            guard remaining != 1 else {
                return String(localized: "lock.unlock.attemptsRemaining.one",
                              defaultValue: "1 attempt remaining before lockout",
                              bundle: .module,
                              comment: "Warning above the passcode pad when exactly one try is left before the app lock stops accepting entries for a while. Singular form; see lock.unlock.attemptsRemaining.other for the rest.")
            }
            return String(localized: "lock.unlock.attemptsRemaining.other",
                          defaultValue: "\(remaining) attempts remaining before lockout",
                          bundle: .module,
                          comment: "Warning above the passcode pad counting the tries left before the app lock stops accepting entries for a while. Used for every count except 1 (see lock.unlock.attemptsRemaining.one).")
        }

        /// Mid-sentence name of a four-digit lock, for ``prompt(credential:)``.
        static var credentialPIN4: String {
            String(localized: "lock.credential.pin4", defaultValue: "4-digit PIN", bundle: .module,
                   comment: "Name of the four-digit lock type, used inside 'Enter your %@ to continue.' — inflect it for that sentence.")
        }

        /// Mid-sentence name of a six-digit lock, for ``prompt(credential:)``.
        static var credentialPIN6: String {
            String(localized: "lock.credential.pin6", defaultValue: "6-digit PIN", bundle: .module,
                   comment: "Name of the six-digit lock type, used inside 'Enter your %@ to continue.' — inflect it for that sentence.")
        }

        /// Mid-sentence name of an alphanumeric lock, for ``prompt(credential:)``.
        static var credentialPassword: String {
            String(localized: "lock.credential.password", defaultValue: "password", bundle: .module,
                   comment: "Name of the alphanumeric lock type, used inside 'Enter your %@ to continue.' — lower-case mid-sentence in English.")
        }

        /// Mid-sentence fallback when the configured lock kind is not yet known.
        static var credentialPasscode: String {
            String(localized: "lock.credential.passcode", defaultValue: "passcode", bundle: .module,
                   comment: "Generic fallback name for the lock, used inside 'Enter your %@ to continue.' when the configured kind is not known yet.")
        }

        /// Heading of both lockout cards — the timed cooldown and the terminal reset-required state.
        static var lockoutTitle: String {
            String(localized: "lock.lockout.title", defaultValue: "Too many failed attempts", bundle: .module,
                   comment: "Heading on both app-lock lockout cards: the timed cooldown and the final state where only a reset can continue.")
        }

        /// Countdown over an hour.
        static func cooldownHoursMinutes(hours: Int, minutes: Int) -> String {
            String(localized: "lock.cooldown.retry.hoursMinutes",
                   defaultValue: "Try again in \(hours)h \(minutes)m",
                   bundle: .module,
                   comment: "Live countdown on the lockout card. First number is hours, second is minutes; 'h' and 'm' are abbreviations that should be localized to the usual short units.")
        }

        /// Countdown over a minute.
        static func cooldownMinutesSeconds(minutes: Int, seconds: Int) -> String {
            String(localized: "lock.cooldown.retry.minutesSeconds",
                   defaultValue: "Try again in \(minutes)m \(seconds)s",
                   bundle: .module,
                   comment: "Live countdown on the lockout card. First number is minutes, second is seconds; 'm' and 's' are abbreviations that should be localized to the usual short units.")
        }

        /// Countdown under a minute.
        static func cooldownSeconds(_ seconds: Int) -> String {
            String(localized: "lock.cooldown.retry.seconds",
                   defaultValue: "Try again in \(seconds)s",
                   bundle: .module,
                   comment: "Live countdown on the lockout card, under a minute. 's' is an abbreviation for seconds and should be localized to the usual short unit.")
        }

        /// The end of the cooldown ladder: nothing but a destructive reset continues from here.
        static var resetRequiredBody: String {
            String(localized: "lock.reset.required.body",
                   defaultValue: "You must reset app lock to continue. Private journal, cycle, and intimacy notes will become permanently unreadable.",
                   bundle: .module,
                   comment: "Body of the final lockout card. The reset is the only way forward AND it destroys the sealed notes for good — both halves have to survive translation.")
        }

        /// Heading of the lost-key card. The passcode was right; the device's key is gone.
        static var enclaveLostTitle: String {
            String(localized: "lock.enclaveLost.title",
                   defaultValue: "Sealed data can't be opened on this device",
                   bundle: .module,
                   comment: "Heading shown when the correct passcode was entered but this device's Secure Enclave key is gone. 'On this device' is the precise part: the data is not corrupt, it is unopenable here.")
        }

        /// Body of the lost-key card, including what a reset does and does not do.
        static var enclaveLostBody: String {
            String(localized: "lock.enclaveLost.body",
                   defaultValue: "Your passcode was correct. This device's Secure Enclave key — the only thing that can open your sealed journal, cycle, and intimacy notes — is gone. Resetting app lock does not bring those notes back; it clears the lock so you can use Fernlet again.",
                   bundle: .module,
                   comment: "Body of the lost-key card. Three things must survive: the user typed the right passcode, the notes are already unreadable, and resetting recovers nothing — it only makes the app usable again.")
        }

        /// The repair that beats a reset, when a biometric copy of the key survives.
        ///
        /// - Parameter biometry: "Face ID", "Touch ID", "Optic ID" or the generic fallback.
        static func enclaveLostBiometricRepair(_ biometry: String) -> String {
            String(localized: "lock.enclaveLost.biometricRepair",
                   defaultValue: "\(biometry) can still open your notes on this device and repair its key. Try that first — resetting destroys that surviving copy.",
                   bundle: .module,
                   comment: "Shown on the lost-key card when a biometric copy of the key survives. This is the ONE path that recovers the notes, so the 'try that first' has to read as urgent: the reset button underneath destroys it. The placeholder is an Apple product name and is not translated.")
        }

        /// The biometric repair button on the lost-key card.
        ///
        /// - Parameter biometry: "Face ID", "Touch ID", "Optic ID" or the generic fallback.
        static func unlockWithBiometric(_ biometry: String) -> String {
            String(localized: "lock.enclaveLost.unlockWithBiometric",
                   defaultValue: "Unlock with \(biometry)",
                   bundle: .module,
                   comment: "Button offering biometric unlock on the lost-key card. The placeholder is an Apple product name (Face ID / Touch ID / Optic ID) and is not translated.")
        }

        /// Inline error when the ladder is exhausted.
        static var errorResetRequired: String {
            String(localized: "lock.unlock.error.resetRequired", defaultValue: "Reset required.", bundle: .module,
                   comment: "Short inline error under the passcode field: no further attempts are accepted, only a reset continues.")
        }

        /// Inline error after a correct passcode when a biometric repair is still possible.
        ///
        /// - Parameter biometry: "Face ID", "Touch ID", "Optic ID" or the generic fallback.
        static func errorKeyGoneTryBiometric(_ biometry: String) -> String {
            String(localized: "lock.unlock.error.keyGoneTryBiometric",
                   defaultValue: "Your passcode was correct, but this device's key for sealed data is gone. Try \(biometry) — it can still open and repair it.",
                   bundle: .module,
                   comment: "Inline error after a CORRECT passcode when this device's key is gone but biometrics can still repair it. Do not phrase it as a wrong passcode. The placeholder is an Apple product name and is not translated.")
        }

        /// Inline error after a correct passcode with no repair available; the second one raises the card.
        static var errorKeyGone: String {
            String(localized: "lock.unlock.error.keyGone",
                   defaultValue: "Your passcode was correct, but sealed data can no longer be opened on this device. Enter it once more to confirm.",
                   bundle: .module,
                   comment: "Inline error after a CORRECT passcode when this device's key is gone. The re-entry is a deliberate double check before the app offers the destructive reset — do not phrase it as a wrong passcode.")
        }

        /// Inline error when biometry ran and did not recognise the user.
        ///
        /// - Parameter biometry: "Face ID", "Touch ID", "Optic ID" or the generic fallback.
        static func errorBiometricUnrecognized(_ biometry: String) -> String {
            String(localized: "lock.unlock.error.biometricUnrecognized",
                   defaultValue: "\(biometry) didn't recognize you. Try your passcode.",
                   bundle: .module,
                   comment: "Inline error when the biometric check ran and failed to match. The placeholder is an Apple product name and is not translated.")
        }

        /// Inline error when biometry is refused because the ladder is exhausted.
        static var errorTooManyAttempts: String {
            String(localized: "lock.unlock.error.tooManyAttempts",
                   defaultValue: "Too many attempts. Reset is required.",
                   bundle: .module,
                   comment: "Inline error when a biometric unlock is refused because too many passcode attempts failed and only a reset continues.")
        }

        /// A lockout, spoken as one sentence.
        ///
        /// Two whole sentences joined, as a FORMAT rather than by splicing them together in Swift
        /// with a space: the pieces are independently translated, and a language that needs them
        /// reordered, differently punctuated, or written right-to-left cannot express that from the
        /// call site.
        ///
        /// - Parameters:
        ///   - title: The lockout heading, already localized.
        ///   - countdown: The live "try again in …" line, already localized.
        static func announceLockout(title: String, countdown: String) -> String {
            String(localized: "lock.unlock.announce.lockout",
                   defaultValue: "\(title) \(countdown)",
                   bundle: .module,
                   comment: "Spoken aloud when the app lock refuses an entry because a cooldown is running; the screen shows a card instead of an error line. First placeholder is the lockout heading, second is the live countdown. Both are complete phrases — order, join and punctuate them however the two read naturally together.")
        }

        /// A failed attempt and the countdown to lockout, spoken as one sentence. Same
        /// format-not-splice reasoning as ``announceLockout(title:countdown:)``.
        ///
        /// - Parameters:
        ///   - failure: The failure sentence, already localized.
        ///   - attempts: The attempts-remaining warning, already localized.
        static func announceFailureWithAttempts(failure: String, attempts: String) -> String {
            String(localized: "lock.unlock.announce.failureWithAttempts",
                   defaultValue: "\(failure) \(attempts)",
                   bundle: .module,
                   comment: "Spoken aloud after a failed app-lock attempt. First placeholder is what went wrong, second is the warning counting the tries left before lockout. Both are complete sentences — order, join and punctuate them however the two read naturally together.")
        }

        /// What the bare spinner that replaces the PIN dots is doing.
        ///
        /// The spinner covers the whole unlock round trip — key derivation plus the content-key
        /// unwrap — which is deliberately slow. Unlabeled it is an unnamed, valueless element, so a
        /// blind user cannot tell a working check from a screen that has stopped responding.
        static var checkingPasscode: String {
            String(localized: "lock.unlock.checking", defaultValue: "Checking your passcode", bundle: .module,
                   comment: "Spoken while the app lock verifies a submitted passcode; the screen shows only a spinner. Present tense — the check is still running.")
        }

        /// VoiceOver's reading of the PIN-dot row: the only feedback a masked field can give.
        static func pinProgress(entered: Int, total: Int) -> String {
            String(localized: "lock.pinDots.accessibilityLabel",
                   defaultValue: "\(entered) of \(total) digits entered",
                   bundle: .module,
                   comment: "Spoken by VoiceOver for the row of PIN dots. First number is how many digits have been typed, second is how many the PIN has. This is the only feedback a masked PIN field gives, so keep both numbers.")
        }
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
    /// Puts VoiceOver's cursor on the inline error the moment one appears.
    ///
    /// The failure states of this screen used to be visible-only: the cursor stayed wherever the
    /// pad had left it, so a wrong PIN, an exhausted ladder and a lost content key all read as
    /// "nothing happened". Focus moves only TOWARD an error and never away from one, so it can never
    /// yank the cursor off a key the user is in the middle of pressing.
    @AccessibilityFocusState private var isErrorFocused: Bool
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

            // ~272pt of keypad before the header, the error line, the attempts warning and either
            // lockout card, on a screen the user cannot skip, in an app that declares landscape on
            // iPhone and locks orientation nowhere. See ``fernletLockPadPage()`` — every host of
            // the shared pad uses it.
            unlockStack
                .padding(.horizontal, 32)
                .fernletLockPadPage()
        }
        .onAppear {
            refreshCooldown()
            autoPromptBiometricIfEligible()
        }
        // Toward an error only, never away from one: an arriving failure takes the cursor, and
        // clearing the message at the start of the next attempt leaves it where the user put it.
        .onChange(of: errorMessage) { _, message in
            guard message != nil else { return }
            isErrorFocused = true
        }
        .onReceive(timer) { _ in refreshCooldown() }
        // The trigger is `String?`, and it is set to nil at the START of every attempt — feeding it
        // to `.sensoryFeedback(.error, trigger:)` directly would buzz on the way INTO each try. Only
        // an arriving message is a failure.
        .sensoryFeedback(trigger: errorMessage) { _, message in message == nil ? nil : .error }
        .animation(.easeInOut(duration: 0.2), value: errorMessage)
        .animation(.easeInOut(duration: 0.2), value: isInputDisabled)
    }

    /// The unlock screen's whole column — header, failure feedback, the entry surface (with either
    /// lockout card above it) and the biometric offer.
    ///
    /// Extracted from ``body`` when the `ScrollView` went in: the body was already close to the
    /// 60-code-line ceiling (Power of 10 R4), and wrapping in a scroll container plus a geometry
    /// reader would have pushed it over.
    @ViewBuilder private var unlockStack: some View {
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
                    .accessibilityFocused($isErrorFocused)
            }

            // Attempt counter
            let attempts = lockService.currentAttemptCount
            if attempts > 0 && !isInputDisabled {
                let remaining = FernletLockService.attemptsPerCooldownBatch - attempts
                // Terracotta ink, not goldenrod: goldenrod on parchment measured about 2.2:1,
                // and this line is the warning that the next mistakes cost a lockout.
                Text(FernletLockCopy.Unlock.attemptsRemaining(remaining))
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

            Text(FernletLockCopy.Unlock.title)
                .font(.fernlet(.header))
                .foregroundStyle(Color.bark)

            Text(FernletLockCopy.Unlock.prompt(credential: credentialLabel))
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
                    .accessibilityLabel(FernletLockCopy.Unlock.checkingPasscode)
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
            SecureField(FernletLockCopy.passwordFieldPlaceholder, text: $passcode)
                .textContentType(.password)
                .sheetTextInput()
                .submitLabel(.go)
                .onSubmit { attemptUnlock() }
                .disabled(isUnlocking)

            ZStack {
                actionButton(FernletLockCopy.Action.unlock) { attemptUnlock() }
                    .opacity(isUnlocking ? 0 : 1)
                if isUnlocking {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(Color.moss)
                        .accessibilityLabel(FernletLockCopy.Unlock.checkingPasscode)
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

            Text(FernletLockCopy.Unlock.lockoutTitle)
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
        // The thresholds stay strictly-greater, exactly as they were: at 60s on the nose the
        // countdown still reads in seconds rather than flipping to "1m 0s" for one tick.
        if cooldownRemaining > 3600 {
            return FernletLockCopy.Unlock.cooldownHoursMinutes(
                hours: Int(cooldownRemaining / 3600),
                minutes: Int(cooldownRemaining.truncatingRemainder(dividingBy: 3600) / 60))
        } else if cooldownRemaining > 60 {
            return FernletLockCopy.Unlock.cooldownMinutesSeconds(
                minutes: Int(cooldownRemaining / 60),
                seconds: Int(cooldownRemaining.truncatingRemainder(dividingBy: 60)))
        } else {
            return FernletLockCopy.Unlock.cooldownSeconds(Int(cooldownRemaining))
        }
    }

    private var resetRequiredCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(Color.terracotta)

            Text(FernletLockCopy.Unlock.lockoutTitle)
                .font(.fernlet(.header))
                .foregroundStyle(Color.bark)

            Text(FernletLockCopy.Unlock.resetRequiredBody)
                .font(.fernlet(.body))
                .foregroundStyle(Color.slate)
                .multilineTextAlignment(.center)
                .fernletWrappingText()

            if let onReset = onResetRequested {
                Button(FernletLockCopy.Action.resetAppLock, role: .destructive, action: onReset)
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

            Text(FernletLockCopy.Unlock.enclaveLostTitle)
                .font(.fernlet(.header))
                .foregroundStyle(Color.bark)
                .multilineTextAlignment(.center)
                .fernletWrappingText()

            Text(FernletLockCopy.Unlock.enclaveLostBody)
                .font(.fernlet(.body))
                .foregroundStyle(Color.slate)
                .multilineTextAlignment(.center)
                .fernletWrappingText()

            if canRepairWithBiometrics {
                let biometry = biometricName(lockService.biometricType)
                Text(FernletLockCopy.Unlock.enclaveLostBiometricRepair(biometry))
                    .font(.fernlet(.bubble))
                    .foregroundStyle(Color.bark)
                    .multilineTextAlignment(.center)
                    .fernletWrappingText()

                Button(FernletLockCopy.Unlock.unlockWithBiometric(biometry)) { triggerBiometric() }
                    .font(.fernlet(.label))
                    .foregroundStyle(Color.moss)
                    .buttonStyle(.plain)
                    .disabled(isCheckingBiometric)
                    .padding(.top, 4)
            }

            if let onReset = onResetRequested {
                Button(FernletLockCopy.Action.resetAppLock, role: .destructive, action: onReset)
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
                // The only arm with no inline error text — the countdown card carries the state
                // instead, and it is a card that silently appeared. Say the countdown out loud.
                announceUnlockFailure(FernletLockCopy.Unlock.announceLockout(
                    title: FernletLockCopy.Unlock.lockoutTitle,
                    countdown: cooldownDisplayText))
            } catch FernletLockError.resetRequired {
                passcode = ""
                contentKeyUnrecoverableCount = 0
                errorMessage = FernletLockCopy.Unlock.errorResetRequired
                announceUnlockFailure(FernletLockCopy.Unlock.errorResetRequired)
            } catch FernletLockError.contentKeyUnrecoverable {
                // The passcode was RIGHT; this device's Secure Enclave key is gone, so the sealed
                // data is unopenable. Say so instead of inviting another attempt (nothing-silent).
                // The FIRST occurrence keeps the pad live and points at the biometric repair; the
                // second raises the card that actually offers the reset (see the count's doc).
                passcode = ""
                contentKeyUnrecoverableCount += 1
                let keyGone = canRepairWithBiometrics
                    ? FernletLockCopy.Unlock.errorKeyGoneTryBiometric(biometricName(lockService.biometricType))
                    : FernletLockCopy.Unlock.errorKeyGone
                errorMessage = keyGone
                announceUnlockFailure(keyGone)
            } catch FernletLockError.contentKeyTemporarilyUnavailable(let status) {
                // NOT the terminal state: the keychain would not answer, which says nothing about
                // whether the key survives. Never advance the count, never mention reset.
                passcode = ""
                contentKeyUnrecoverableCount = 0
                let unavailable = FernletLockError.contentKeyTemporarilyUnavailable(status: status).errorDescription
                errorMessage = unavailable
                if let unavailable { announceUnlockFailure(unavailable) }
            } catch {
                passcode = ""
                contentKeyUnrecoverableCount = 0
                errorMessage = error.localizedDescription
                announceUnlockFailure(error.localizedDescription)
            }
        }
    }

    /// Speaks a FAILED unlock attempt, appending the attempts-remaining warning when one is on
    /// screen.
    ///
    /// **Security — this must never be reachable from a success.** `FernletLockService.unlock`
    /// answers a duress code and a real passcode identically, on purpose; an announcement keyed off
    /// *which* credential matched would be a duress oracle audible from across the room. So this is
    /// called only from ``attemptUnlock()``'s catch arms, where nothing knows or can know which
    /// secret was tried — every path through it has already failed.
    ///
    /// Where a failure ALSO sets `errorMessage`, two channels carry it: this announcement and the
    /// `@AccessibilityFocusState` move onto the error text, which speaks the same words. A focus
    /// change can swallow a pending announcement and vice versa, so pairing them means the failure
    /// is spoken exactly once in practice and never zero times. The `cooldownActive` arm is the
    /// exception and the reason this exists: it clears `errorMessage` and shows a card instead, so
    /// there is no error text to focus and this announcement is the ONLY channel.
    ///
    /// - Parameter message: An ALREADY-LOCALIZED sentence from ``FernletLockCopy`` or an error's
    ///   `localizedDescription`. `AccessibilityNotification.Announcement` takes a plain `String`, so
    ///   a literal here would be spoken in English forever — this module is an SPM package and its
    ///   catalog is only consulted through `bundle: .module`.
    private func announceUnlockFailure(_ message: String) {
        let attempts = lockService.currentAttemptCount
        let remaining = FernletLockService.attemptsPerCooldownBatch - attempts
        let spoken = (attempts > 0 && !isInputDisabled && remaining > 0)
            ? FernletLockCopy.Unlock.announceFailureWithAttempts(
                failure: message,
                attempts: FernletLockCopy.Unlock.attemptsRemaining(remaining))
            : message
        AccessibilityNotification.Announcement(spoken).post()
    }

    /// Whether a biometric error is the user declining biometrics rather than biometrics failing.
    ///
    /// The gate auto-presents Face ID once per lock session, so someone who prefers to type their
    /// passcode dismisses that sheet on EVERY entry to the Private tab. Announcing those as failures
    /// would greet them with an error each time — the opposite of the nothing-silent intent. Real
    /// failures (a face that did not match, a lockout, a keychain refusal) still speak.
    private static func isUserDismissal(_ error: any Error) -> Bool {
        guard let code = (error as? LAError)?.code else { return false }
        switch code {
        case .userCancel, .userFallback, .appCancel, .systemCancel: return true
        default: return false
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
                // Named from the service's reported biometry rather than hard-coded "Face ID": the
                // English literal this replaced told Touch ID and Optic ID users that a sensor they
                // do not have failed to recognise them, and it would have baked that same wrong
                // product name into every translation.
                let unrecognized = FernletLockCopy.Unlock.errorBiometricUnrecognized(
                    biometricName(lockService.biometricType))
                errorMessage = unrecognized
                announceUnlockFailure(unrecognized)
            } catch FernletLockError.resetRequired {
                errorMessage = FernletLockCopy.Unlock.errorTooManyAttempts
                announceUnlockFailure(FernletLockCopy.Unlock.errorTooManyAttempts)
            } catch {
                // Rendered text unchanged (pre-existing behaviour); only the SPEECH is filtered, so
                // a dismissed Face ID sheet stops sounding like something went wrong.
                errorMessage = error.localizedDescription
                if !Self.isUserDismissal(error) { announceUnlockFailure(error.localizedDescription) }
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

    /// The lock kind's name as it reads INSIDE ``FernletLockCopy/Unlock/prompt(credential:)`` —
    /// mid-sentence, which is why these are separate keys from the setup screen's card titles even
    /// where the English happens to match.
    private var credentialLabel: String {
        switch lockService.credentialKind {
        case .pin4: FernletLockCopy.Unlock.credentialPIN4
        case .pin6: FernletLockCopy.Unlock.credentialPIN6
        case .alphanumeric: FernletLockCopy.Unlock.credentialPassword
        case nil: FernletLockCopy.Unlock.credentialPasscode
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
    .accessibilityLabel(FernletLockCopy.Unlock.pinProgress(entered: current.count, total: total))
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

    /// The delete key's own token. Internal vocabulary, never spoken and never persisted — the glyph
    /// is what `padKey` draws for it and ``FernletLockCopy/Pad/backspace`` is what VoiceOver says.
    private static let backspaceKey = "⌫"
    /// The bottom-left hole in the 3×4 grid. Named so the empty-string check reads as "the gap",
    /// and so nothing mistakes it for a key that lost its label.
    private static let gapKey = ""

    /// The 3×4 grid, row by row. The last row is ``gapKey``, zero, ``backspaceKey`` — spelled out
    /// rather than referencing the constants because a stored property's initializer runs before
    /// there is a `Self` to reach them through.
    private let rows: [[String]] = [
        ["1", "2", "3"],
        ["4", "5", "6"],
        ["7", "8", "9"],
        ["", "0", "⌫"]
    ]

    /// The key face's minimum box. A MINIMUM rather than a fixed frame: at the accessibility Dynamic
    /// Type sizes a 24pt digit no longer fits inside 76×56, and a hard frame clipped it.
    private static let keyMinWidth: CGFloat = 76
    private static let keyMinHeight: CGFloat = 56

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

    /// One key, or — for the grid's bottom-left hole — a layout-only stand-in.
    ///
    /// The hole used to be a real `Button` with an empty label, disabled. VoiceOver and Switch
    /// Control still enumerate a disabled button, so the pad exposed a nameless "dimmed button" the
    /// user had to swipe past on the way to 0, and Voice Control had nothing to call it. It is now a
    /// hidden mirror of a key face: `hidden()` keeps its layout so the 0 and the delete key stay
    /// under the 8 and the 9 at every Dynamic Type size, and takes it out of the tree entirely.
    @ViewBuilder private func padKey(_ key: String) -> some View {
        if key == Self.gapKey {
            keyFace("0")
                .hidden()
                .accessibilityHidden(true)
        } else {
            Button {
                handleKey(key)
            } label: {
                keyFace(key)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(key == Self.backspaceKey
                                ? Text(verbatim: FernletLockCopy.Pad.backspace)
                                : Text(verbatim: key))
        }
    }

    /// The drawn face of one key: its glyph on a cream tile.
    ///
    /// The digits were `.fernlet(.stat)` — 14pt, less than half the size iOS's own passcode keypad
    /// uses — inside a hard 76×56 frame. They now scale with Dynamic Type from 24pt, and the frame
    /// is a floor rather than a ceiling so a grown digit pushes the tile out instead of clipping.
    private func keyFace(_ key: String) -> some View {
        Group {
            if key == Self.backspaceKey {
                Image(systemName: "delete.left")
                    .font(.title2.weight(.medium))
            } else {
                Text(verbatim: key)
                    .font(.custom(FernletFontName.dmSansMedium, size: 24, relativeTo: .title2))
            }
        }
        .foregroundStyle(Color.bark)
        .frame(minWidth: Self.keyMinWidth, minHeight: Self.keyMinHeight)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.bark.opacity(0.08), lineWidth: 1)
        )
    }

    private func handleKey(_ key: String) {
        if key == Self.backspaceKey {
            if !value.isEmpty { value.removeLast() }
        } else if key != Self.gapKey, value.count < maxLength {
            value.append(key)
        }
    }
}

// MARK: - Pad page hosting

public extension View {
    /// Hosts a screen that contains a ``FernletNumericPad`` so its keys stay reachable at every
    /// Dynamic Type size and in every orientation.
    ///
    /// The pad's key tiles are a MINIMUM (76×56) around a `relativeTo: .title2` digit, so the whole
    /// 3×4 grid grows with the user's text size — from ~260pt at the default size to well over 300pt
    /// at the accessibility sizes. Every host of the pad is also a screen the user cannot skip
    /// (unlock, passcode creation, passcode change, biometric re-verification), the app declares
    /// landscape on iPhone, and none of these screens locks orientation. Unscrolled, the bottom rows
    /// of the pad simply fall off the screen with no way to reach them.
    ///
    /// The geometry-derived `minHeight` is what keeps this from being a visual change: while the
    /// content fits, the host's own `Spacer`s still centre it exactly as before and
    /// `.basedOnSize` suppresses the rubber-band, so a default-size portrait screen looks
    /// untouched; only content that genuinely overflows starts scrolling.
    ///
    /// - Important: apply this to the screen's CONTENT (inside its background layer), not to the
    ///   background — a `Color.ignoresSafeArea()` inside a `ScrollView` would scroll away.
    ///   ``DuressPINSetupView`` is the one pad host that cannot use this, because its pad is a
    ///   `safeAreaInset`; it caps the pad's Dynamic Type instead.
    func fernletLockPadPage() -> some View {
        GeometryReader { proxy in
            ScrollView {
                self
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}

// MARK: - Biometric helpers (shared by Setup + Unlock)

/// User-facing name for a biometry type ("Face ID", "Touch ID", "Optic ID", or the generic
/// "Biometrics"), shared by the setup and unlock screens and the app's lock settings.
///
/// The three Apple product names are deliberately NOT localized: Apple ships them untranslated in
/// almost every locale, and a translated "Face ID" would name a feature no iPhone's own UI calls
/// that. Only the generic fallback — which is our own word, used when the device reports a biometry
/// we have no product name for — goes through the catalog.
public func biometricName(_ type: LABiometryType) -> String {
    switch type {
    case .faceID: "Face ID"
    case .touchID: "Touch ID"
    case .opticID: "Optic ID"
    default: String(localized: "lock.biometrics.generic", defaultValue: "Biometrics", bundle: .module,
                    comment: "Generic name for the device's biometric unlock, used only when it is neither Face ID, Touch ID nor Optic ID. It is substituted into sentences like 'Enable %@' and '%@ didn't recognize you.'")
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
