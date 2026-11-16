// RecoveryCodeViews.swift
// Fernlet
//
// The recovery code's screens (G9-2, plan Part 2 "UI"): the Recovery code row in Privacy & data,
// the one-time offer when a backup is first turned on, making a code (explain → passcode/Face ID →
// 12 numbered words → type 3 back → done), "Check my code", and "Use a recovery code" from the
// restore banner. Hidden in a duress session; the words are capture-protected and covered while
// the app is not frontmost (the app-switcher snapshot).

import CloudKitSync
import FernletCrypto
import FernletFoundation
import FernletLock
import FernletUI
import SwiftUI

// MARK: - Presenter

/// What Privacy & data knows about the recovery code, and which recovery-code sheet is up.
///
/// One per ``PrivacyDataSettingsView``; the row, the banner button and the one-time offer all go
/// through it, so there is one ``RecoveryCodeService`` and one status read per screen.
@MainActor
@Observable
final class RecoveryCodePresenter {
    /// The code's state as last read from iCloud.
    enum Status: Equatable {
        /// Not read yet.
        case unknown
        /// No code exists for this iCloud account.
        case notSetUp
        /// The current code was made on this date.
        case madeOn(Date)
        /// iCloud could not be reached (or there is no account).
        case unavailable
    }

    /// Which sheet is up.
    enum Sheet: String, Identifiable {
        /// The row's sheet: make a (new) code, or check one.
        case manage
        /// The restore banner's: type the code to reopen the backups.
        case recover
        /// Its id.
        var id: String { rawValue }
    }

    /// The code's state.
    private(set) var status: Status = .unknown
    /// The sheet up, if any.
    var sheet: Sheet?
    /// Whether the one-time "make a recovery code?" offer is up.
    var isOffering = false
    /// The service every sheet uses.
    let service: RecoveryCodeService

    /// The device-local flag that the one-time offer was made (owner call R5 = A: offered once, never
    /// nagged). Device-local on purpose: a new iPhone that turns a backup on is offered again.
    nonisolated static let offeredDefaultsKey = "fernlet.recoveryCode.offeredOnce"

    /// A presenter over `service`.
    init(service: RecoveryCodeService) {
        self.service = service
    }

    /// Re-reads the code's state from iCloud.
    func refresh() async {
        do {
            switch try await service.status() {
            case .notSetUp: status = .notSetUp
            case .madeOn(let date): status = .madeOn(date)
            }
        } catch {
            status = .unavailable
        }
    }

    /// The one-time offer, after a sealed backup was turned on: shown once per device, and not at all
    /// when a code already exists.
    ///
    /// - Parameter defaults: Where the offered flag lives.
    func offerOnceAfterBackupTurnedOn(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: Self.offeredDefaultsKey) else { return }
        Task {
            await refresh()
            guard status == .notSetUp else { return }
            defaults.set(true, forKey: Self.offeredDefaultsKey)
            isOffering = true
        }
    }

    /// Whether a restore outcome is one a recovery code can fix: the escrow key is not on this phone
    /// (`deferredKeyNotSynced`) or no key here opens the backup (`notRecognized`). The banner offers
    /// "Use a recovery code" for exactly these.
    ///
    /// - Parameter outcome: A payload's or the photo route's last restore outcome.
    nonisolated static func offersRecovery(for outcome: SealedBackupRestoreOutcome) -> Bool {
        switch outcome {
        case .deferredKeyNotSynced, .notRecognized: return true
        case .restored, .nothingToRestore, .skippedStoreNotEmpty, .deferredLocked, .deferredTransient,
             .rolledBack, .needsNewerFernlet: return false
        }
    }

    /// The live presenter: iCloud's records through ``CloudKitDataService`` (an in-memory store under
    /// the Privacy & data UI-test harness), refusing in a duress session.
    ///
    /// - Parameters:
    ///   - duressActive: Whether a duress session is active.
    ///   - anyBackupEnabled: Whether any encrypted backup switch is on.
    static func live(duressActive: @escaping () -> Bool, anyBackupEnabled: @escaping () -> Bool) -> RecoveryCodePresenter {
        RecoveryCodePresenter(service: RecoveryCodeService(
            cloud: makeCloud(), duressActive: duressActive, anyBackupEnabled: anyBackupEnabled
        ))
    }

    private static func makeCloud() -> any RecoveryEscrowStoring {
        #if DEBUG
        if ProcessInfo.processInfo.environment["FERNLET_UI_TEST_PRIVACY_SERVICES"] == "1" {
            return InMemoryRecoveryEscrowStore()
        }
        #endif
        return CloudKitDataService()
    }
}

// MARK: - Row

/// Privacy & data → Backups → **Recovery code**: "Not set up" or "Made on 15 Nov", opening the
/// manage sheet. Never built in a duress session (the caller's gate).
struct RecoveryCodeRow: View {
    /// The screen's presenter.
    let presenter: RecoveryCodePresenter

    var body: some View {
        Button { presenter.sheet = .manage } label: {
            HStack {
                FernletRowLabel("Recovery code", detail: detail)
                    .padding(.vertical, 7)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.slate)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("privacy.recoveryCode.row")
        .task { if presenter.status == .unknown { await presenter.refresh() } }
    }

    /// The row's second line.
    private var detail: LocalizedStringKey {
        switch presenter.status {
        case .unknown: return "Checking…"
        case .notSetUp: return "Not set up. Opens your encrypted backups if iCloud Keychain is lost."
        case .madeOn(let date): return "Made on \(date.formatted(.dateTime.day().month(.abbreviated)))"
        case .unavailable: return "Couldn't check iCloud just now."
        }
    }
}

/// The restore banner's "Use a recovery code" button.
struct RecoveryCodeBannerButton: View {
    /// The screen's presenter.
    let presenter: RecoveryCodePresenter

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Lost iCloud Keychain? Your recovery code can open these backups on this iPhone.")
                .font(.fernlet(.bodySmall))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()
            Button { presenter.sheet = .recover } label: {
                Label("Use a recovery code", systemImage: "key.viewfinder").frame(maxWidth: .infinity)
            }
            .buttonStyle(ActionPillButtonStyle(.secondary))
            .accessibilityIdentifier("privacy.recoveryCode.useCode")
        }
    }
}

// MARK: - Sheets

extension View {
    /// Presents the recovery-code sheets and the one-time offer for `presenter`.
    ///
    /// - Parameters:
    ///   - presenter: The screen's presenter.
    ///   - captureProtection: The app's capture-protection state, handed to the sheet explicitly.
    ///   - onRecovered: Runs after a recovery stored escrow keys (the caller retries the restore).
    func recoveryCodeSheets(
        _ presenter: RecoveryCodePresenter,
        captureProtection: CaptureProtectionState,
        onRecovered: @escaping () -> Void
    ) -> some View {
        modifier(RecoveryCodeSheetsModifier(presenter: presenter, captureProtection: captureProtection, onRecovered: onRecovered))
    }
}

/// ``View/recoveryCodeSheets(_:captureProtection:onRecovered:)``'s body.
private struct RecoveryCodeSheetsModifier: ViewModifier {
    @Bindable var presenter: RecoveryCodePresenter
    let captureProtection: CaptureProtectionState
    let onRecovered: () -> Void

    func body(content: Content) -> some View {
        content
            .sheet(item: $presenter.sheet, onDismiss: { Task { await presenter.refresh() } }) { sheet in
                RecoveryCodeSheet(presenter: presenter, mode: sheet, onRecovered: onRecovered)
                    .environment(captureProtection)
                    .fernletSheetChrome(anchor: "sheet.recoveryCode", detents: [.large])
            }
            .alert("Make a recovery code?", isPresented: $presenter.isOffering) {
                Button("Make one") { presenter.sheet = .manage }
                Button("Not now", role: .cancel) {}
            } message: {
                Text("If this iPhone's iCloud Keychain is ever lost, 12 words you write down can still open your encrypted backups. You can make one later in Privacy & data.")
            }
    }
}

/// The steps of the recovery-code sheet.
private enum RecoveryCodeStep: Equatable {
    /// What a code is, with Make and Check.
    case intro
    /// Typing a code to check it.
    case checking
    /// Typing a code to recover with it.
    case recovering
    /// The 12 words, shown once.
    case showing
    /// Typing 3 of them back.
    case confirming
    /// The code is set up.
    case done
    /// Backups are reopening.
    case recovered
}

/// The recovery-code sheet: every step of making, checking and using a code.
///
/// Holds the code only while the words are on screen and while they are typed back; it is dropped
/// (best-effort) as soon as the person is done, and never written anywhere.
private struct RecoveryCodeSheet: View {
    let presenter: RecoveryCodePresenter
    let mode: RecoveryCodePresenter.Sheet
    let onRecovered: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var step: RecoveryCodeStep = .intro
    @State private var code: RecoveryCode?
    @State private var isWorking = false
    @State private var message: LocalizedStringKey?
    @State private var checkResult: RecoveryCodeCheck?

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: title, onCancel: { close() })
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    stepContent
                    if let message {
                        Text(message)
                            .font(.fernlet(.bodySmall))
                            .foregroundStyle(Color.bark)
                            .fernletWrappingText()
                            .accessibilityIdentifier("recoveryCode.message")
                    }
                }
                .padding(20)
            }
        }
        .fernletSheetStyle()
        .fernletSheet()
        .onAppear { if mode == .recover { step = .recovering } }
        .onDisappear { code = nil }
    }

    private var title: LocalizedStringKey {
        switch step {
        case .intro, .done: return "Recovery code"
        case .checking: return "Check my code"
        case .recovering, .recovered: return "Use a recovery code"
        case .showing: return "Write these down"
        case .confirming: return "Type 3 words back"
        }
    }

    @ViewBuilder private var stepContent: some View {
        switch step {
        case .intro: RecoveryCodeIntro(status: presenter.status, isWorking: isWorking, make: make, check: { go(.checking) })
        case .checking: RecoveryCodeEntry(purpose: .check, isWorking: isWorking, checkResult: checkResult, submit: check)
        case .recovering: RecoveryCodeEntry(purpose: .recover, isWorking: isWorking, checkResult: nil, submit: recover)
        case .showing: wordsStep
        case .confirming: confirmStep
        case .done: RecoveryCodeDone(close: close)
        case .recovered: RecoveryCodeRecovered(close: close)
        }
    }

    @ViewBuilder private var wordsStep: some View {
        if let code {
            RecoveryCodeWords(words: code.words, covered: scenePhase != .active) { go(.confirming) }
                .captureProtected(surface: "recoveryCode")
        }
    }

    @ViewBuilder private var confirmStep: some View {
        if let code {
            RecoveryCodeConfirm(words: code.words, back: { go(.showing) }) {
                self.code = nil
                go(.done)
            }
        }
    }

    private func go(_ next: RecoveryCodeStep) {
        message = nil
        checkResult = nil
        step = next
    }

    private func close() {
        code = nil
        dismiss()
    }

    private func make() {
        guard !isWorking else { return }
        isWorking = true
        message = nil
        Task {
            defer { isWorking = false }
            guard await RecoveryCodeOwnerCheck.passes() else {
                message = "Fernlet needs your passcode or Face ID before it shows a recovery code."
                return
            }
            do {
                code = try await presenter.service.makeNewCode()
                go(.showing)
            } catch {
                message = RecoveryCodeCopy.failure(error)
            }
        }
    }

    private func check(_ typed: RecoveryCode) {
        guard !isWorking else { return }
        isWorking = true
        message = nil
        checkResult = nil
        Task {
            defer { isWorking = false }
            guard await RecoveryCodeOwnerCheck.passes() else {
                message = "Fernlet needs your passcode or Face ID before it checks a recovery code."
                return
            }
            do {
                checkResult = try await presenter.service.check(typed)
            } catch {
                message = RecoveryCodeCopy.failure(error)
            }
        }
    }

    private func recover(_ typed: RecoveryCode) {
        guard !isWorking else { return }
        isWorking = true
        message = nil
        Task {
            defer { isWorking = false }
            do {
                _ = try await presenter.service.recover(with: typed)
                FernletFeedback.system.play(.done)
                go(.recovered)
                onRecovered()
            } catch {
                FernletFeedback.system.play(.failed)
                message = RecoveryCodeCopy.failure(error)
            }
        }
    }
}

// MARK: - Steps

/// The intro: what a code is, what it is not, and Make / Check.
private struct RecoveryCodeIntro: View {
    let status: RecoveryCodePresenter.Status
    let isWorking: Bool
    let make: () -> Void
    let check: () -> Void

    private var hasCode: Bool {
        if case .madeOn = status { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("A recovery code is 12 words that open your encrypted backups if this iPhone's iCloud Keychain is ever lost, for example on a new iPhone without it or after iCloud's encrypted data is reset.")
            Text("Write the words on paper or keep them in a password manager. Fernlet shows them once and keeps no copy.")
            Text("If both the code and iCloud Keychain are lost, no one can open your encrypted backups, not even Fernlet.")
            Text("The code opens backups only. It never unlocks Fernlet's passcode. Fernlet only asks for it here, in Privacy & data, so never type it anywhere else.")
            if hasCode {
                Text("Making a new code stops your old code from working.").foregroundStyle(Color.bark)
            }
            Button(action: make) {
                Text(isWorking ? "Making…" : (hasCode ? "Make a new code" : "Make a recovery code")).frame(maxWidth: .infinity)
            }
            .buttonStyle(ActionPillButtonStyle(.primary))
            .disabled(isWorking)
            .accessibilityIdentifier("recoveryCode.make")
            if hasCode {
                Button(action: check) { Text("Check my code").frame(maxWidth: .infinity) }
                    .buttonStyle(ActionPillButtonStyle(.secondary))
                    .accessibilityIdentifier("recoveryCode.check")
            }
        }
        .font(.fernlet(.body))
        .foregroundStyle(Color.slate)
        .fernletWrappingText()
    }
}

/// The 12 words, numbered, each its own VoiceOver element ("Word 3: apple"). Covered while the app
/// is not frontmost, so the app-switcher snapshot never holds them.
private struct RecoveryCodeWords: View {
    let words: [String]
    let covered: Bool
    let next: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Write these 12 words down in order. You'll type 3 of them back next.")
                .font(.fernlet(.body))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()
            // One word per row, in order: it grows with the text size and VoiceOver reads 1 to 12.
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(words.enumerated()), id: \.offset) { offset, word in
                    HStack(spacing: 8) {
                        Text(verbatim: "\(offset + 1).").foregroundStyle(Color.slate).monospacedDigit()
                        Text(verbatim: word).font(.fernlet(.label)).foregroundStyle(Color.bark)
                    }
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text("Word \(offset + 1): \(word)"))
                }
            }
            .privacySensitive()
            .redacted(reason: covered ? .privacy : [])
            .accessibilityIdentifier("recoveryCode.words")
            Text("Don't take a screenshot: anyone who finds it and gets into your iCloud account could open your backups.")
                .font(.fernlet(.bodySmall))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()
            Button(action: next) { Text("I've written them down").frame(maxWidth: .infinity) }
                .buttonStyle(ActionPillButtonStyle(.primary))
                .accessibilityIdentifier("recoveryCode.wroteItDown")
        }
    }
}

/// Typing 3 words back (owner call R6 = A): three positions chosen at random, each checked against
/// the code (a word's first four letters are enough, as when recovering).
private struct RecoveryCodeConfirm: View {
    let words: [String]
    let back: () -> Void
    let confirmed: () -> Void

    @State private var positions: [Int] = []
    @State private var typed: [String] = ["", "", ""]

    /// Whether every typed word matches its position.
    private var allMatch: Bool {
        positions.count == 3 && positions.indices.allSatisfy { Self.matches(typed[$0], words[positions[$0]]) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("To make sure your copy is right, type these words from it.")
                .font(.fernlet(.body)).foregroundStyle(Color.slate).fernletWrappingText()
            ForEach(Array(positions.enumerated()), id: \.offset) { slot, position in
                VStack(alignment: .leading, spacing: 4) {
                    Text("Word \(position + 1)").font(.fernlet(.label)).foregroundStyle(Color.bark)
                    TextField(text: $typed[slot], prompt: .fieldPrompt("Word \(position + 1)")) { Text("Word \(position + 1)") }
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.asciiCapable)
                        .sheetTextInput()
                        .accessibilityIdentifier("recoveryCode.confirm.\(slot)")
                }
            }
            Button(action: confirmed) { Text("Done").frame(maxWidth: .infinity) }
                .buttonStyle(ActionPillButtonStyle(.primary))
                .disabled(!allMatch)
                .accessibilityIdentifier("recoveryCode.confirm.done")
            Button(action: back) { Text("Show the words again").frame(maxWidth: .infinity) }
                .buttonStyle(ActionPillButtonStyle(.secondary))
        }
        .onAppear { if positions.isEmpty { positions = Self.pickPositions(count: words.count) } }
    }

    /// Three distinct positions in ascending order.
    static func pickPositions(count: Int) -> [Int] {
        Array((0..<count).shuffled().prefix(3)).sorted()
    }

    /// Whether `typed` is `word`, or at least its first four letters.
    static func matches(_ typed: String, _ word: String) -> Bool {
        let folded = typed.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        guard !folded.isEmpty else { return false }
        return folded == word || (folded.count >= RecoveryCode.identifyingPrefixLength && word.hasPrefix(folded))
    }
}

/// Typing a whole code, to check it or to recover with it. The checksum is checked here, before
/// anything is fetched (phone check 3: a wrong word is caught before anything is tried).
private struct RecoveryCodeEntry: View {
    /// What the typed code is for.
    enum Purpose { case check, recover }

    let purpose: Purpose
    let isWorking: Bool
    let checkResult: RecoveryCodeCheck?
    let submit: (RecoveryCode) -> Void

    @State private var typed = ""
    @State private var parseMessage: LocalizedStringKey?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(purpose == .recover
                 ? "Type the 12 words of your recovery code, in order. The first four letters of each word are enough."
                 : "Type your 12 words to check they still open your backups. Nothing is restored or changed.")
                .font(.fernlet(.body)).foregroundStyle(Color.slate).fernletWrappingText()
            TextField(text: $typed, prompt: .fieldPrompt("12 words"), axis: .vertical) { Text("Recovery code") }
                .lineLimit(3...6)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.asciiCapable)
                .privacySensitive()
                .sheetTextInput()
                .accessibilityIdentifier("recoveryCode.entry")
            if let parseMessage {
                Text(parseMessage).font(.fernlet(.bodySmall)).foregroundStyle(Color.bark).fernletWrappingText()
                    .accessibilityIdentifier("recoveryCode.parseError")
            }
            if let checkResult { checkLine(checkResult) }
            Button(action: send) {
                Text(isWorking ? "Checking…" : (purpose == .recover ? "Open my backups" : "Check")).frame(maxWidth: .infinity)
            }
            .buttonStyle(ActionPillButtonStyle(.primary))
            .disabled(isWorking || typed.isEmpty)
            .accessibilityIdentifier("recoveryCode.submit")
        }
        .captureProtected(surface: "recoveryCodeEntry")
        .onDisappear { typed = "" }
    }

    private func checkLine(_ result: RecoveryCodeCheck) -> some View {
        Text(RecoveryCodeCopy.checkLine(result))
            .font(.fernlet(.body)).foregroundStyle(Color.bark).fernletWrappingText()
            .accessibilityIdentifier("recoveryCode.checkResult")
    }

    private func send() {
        do {
            let code = try RecoveryCode(typing: typed)
            parseMessage = nil
            submit(code)
        } catch {
            parseMessage = RecoveryCodeCopy.parseFailure(error)
            FernletFeedback.system.play(.failed)
        }
    }
}

/// The code is set up.
private struct RecoveryCodeDone: View {
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Your recovery code is set up. Keep the paper somewhere safe. If you lose it, make a new code here: the old one then stops working.")
                .font(.fernlet(.body)).foregroundStyle(Color.slate).fernletWrappingText()
            Button(action: close) { Text("Done").frame(maxWidth: .infinity) }
                .buttonStyle(ActionPillButtonStyle(.primary))
                .accessibilityIdentifier("recoveryCode.finished")
        }
    }
}

/// The backups are reopening.
private struct RecoveryCodeRecovered: View {
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Your code worked. Fernlet is restoring your encrypted backups now; the rest arrives the next time you open the Private tab.")
                .font(.fernlet(.body)).foregroundStyle(Color.slate).fernletWrappingText()
            Button(action: close) { Text("Done").frame(maxWidth: .infinity) }
                .buttonStyle(ActionPillButtonStyle(.primary))
                .accessibilityIdentifier("recoveryCode.recoveredDone")
        }
    }
}

// MARK: - Copy and checks

/// The sheet's error and result lines.
private enum RecoveryCodeCopy {
    /// A typed code that did not parse.
    static func parseFailure(_ error: any Error) -> LocalizedStringKey {
        switch error as? RecoveryCodeError {
        case .wrongWordCount(let count)?: return "That's \(count) words. A recovery code has 12."
        case .unknownWord(let position)?: return "Word \(position) isn't one of the recovery code words. Check its spelling."
        case .checksumMismatch?: return "One of the words is wrong or out of order. Check each word against your copy."
        default: return "That code couldn't be read. Check each word against your copy."
        }
    }

    /// A service call that failed.
    static func failure(_ error: any Error) -> LocalizedStringKey {
        switch error as? RecoveryCodeFailure {
        case .noBackupKey?: return "Turn on an encrypted backup first. A recovery code opens encrypted backups, so there's nothing for one to open yet."
        case .noCodeSetUp?: return "No recovery code was made for this iCloud account."
        case .codeDoesNotMatch?: return "This code doesn't open the backups in this iCloud account. It may be an old code that a newer one replaced."
        case .refusedInDuress?: return "Recovery codes aren't available right now."
        case nil: return "Couldn't reach iCloud. Check that you're signed in and online, then try again."
        }
    }

    /// What "Check my code" found.
    static func checkLine(_ result: RecoveryCodeCheck) -> LocalizedStringKey {
        switch result {
        case .matches: return "This code opens your encrypted backups."
        case .doesNotMatch: return "This isn't your current recovery code. If you made a new code, use that one."
        case .noCodeSetUp: return "No recovery code was made for this iCloud account."
        }
    }
}

/// The fresh passcode / Face ID check before a code is shown or checked (plan: a thief with an
/// unlocked phone cannot see a code). A new `LAContext` every time; the Privacy & data UI-test
/// harness skips it exactly as it skips the page's own check.
@MainActor
private enum RecoveryCodeOwnerCheck {
    static func passes() async -> Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["FERNLET_UI_TEST_PRIVACY_AUTH"] == "1" { return true }
        #endif
        let reason = String(localized: "recoveryCode.verify.reason",
                            defaultValue: "Verify to make or check your recovery code.",
                            comment: "Shown by iOS in the Face ID or passcode prompt before Fernlet shows or checks a recovery code.")
        let verifier = LocalAuthenticationDeviceOwnerVerifier(localizedReason: reason)
        switch await verifier.verifyDeviceOwner() {
        case .verified, .passcodeNotSet: return true
        case .failed: return false
        }
    }
}

// MARK: - Test store

#if DEBUG
/// An in-memory ``RecoveryEscrowStoring`` for the Privacy & data UI-test harness and unit tests.
/// DEBUG-only, so a shipping binary cannot be talked into keeping escrow records in memory.
@MainActor
final class InMemoryRecoveryEscrowStore: RecoveryEscrowStoring {
    /// The records, by record name.
    private(set) var recordsByName: [String: RecoveryEscrowRecord] = [:]
    /// When set, every call throws it (a simulated iCloud failure).
    var failure: (any Error)?

    func saveRecoveryEscrowRecords(_ records: [RecoveryEscrowRecord]) async throws {
        if let failure { throw failure }
        for record in records { recordsByName[record.recordName] = record }  // R2: bounded by records.
    }

    func recoveryEscrowRecords() async throws -> [RecoveryEscrowRecord] {
        if let failure { throw failure }
        return Array(recordsByName.values)
    }

    func deleteRecoveryEscrowRecords(keeping: Data?) async throws -> Int {
        if let failure { throw failure }
        let prefix = keeping.map { RecoveryEscrowRecord.recordNamePrefix(recoveryPublicKey: $0) }
        let doomed = recordsByName.keys.filter { name in prefix.map { !name.hasPrefix($0) } ?? true }
        for name in doomed { recordsByName[name] = nil }  // R2: bounded by records.
        return doomed.count
    }
}
#endif
