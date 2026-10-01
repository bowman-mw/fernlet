// FernletTapGate.swift
// Fernlet
//
// The no-passcode Private tab's gate (period-data design 2026-09-30, §10.1–§10.2): an unlock screen
// with ONE button, "Unlock", and the "Some entries can't be opened here" card that replaces that
// button when a new key would be minted over entries no key on this iPhone can open.
//
// Friction, not security. The button proves nothing about who is holding the phone; what it buys
// is that private entries are never shown by accident and are decrypted only while the page is
// deliberately open. None of the copy below says "locked", "protected" or "secured" about it.

import SwiftUI
import FernletDomainModel
import FernletFoundation
import FernletLock
import FernletUI

// MARK: - The seam the app implements

/// What one tap on the no-passcode Private gate (or on its "Remove them and open Private" button)
/// led to, as the app's open coordinator reports it back to the gate.
///
/// The coordinator lives in the app target (it reads the sealed stores and the backup bookkeeping),
/// so this module names only its answers and gains no app dependency.
public enum FernletTapOpenOutcome: Equatable, Sendable {
    /// The Private tab is open (`.openedWithoutPasscode(.privateHub)`); the gate's overlay goes away.
    case opened
    /// A fresh key would have been minted over entries no key on this iPhone can open. Nothing was
    /// minted and nothing was deleted: the gate shows these counts and asks.
    case unopenableEntries(FernletUnopenableEntryCounts)
    /// Something could not be read this instant (a keychain row, a sealed row, the recovery
    /// material), or a key may still be reachable. Nothing was written; the button stays.
    case tryAgain
    /// This iPhone's key for the Private tab exists but can never be opened again (its Secure-Enclave
    /// key is gone). Only a reset continues.
    case unrecoverable
}

/// The entries the "Some entries can't be opened here" card names, counted by kind — keylessly, and
/// only once the app has proven no copy of the key that sealed them survives on this iPhone.
///
/// A kind the user has HIDDEN (period or intimacy tracking) is never named: the app counts its rows
/// into ``otherEntries`` instead, because the card is shown to whoever holds the phone. The counts
/// here are what the card shows, and what a Remove tap carries back.
public struct FernletUnopenableEntryCounts: Equatable, Sendable {
    /// Cycle entries (sealed cycle notes and records), while period tracking is visible.
    public var cycleEntries: Int
    /// Intimacy entries, while intimacy tracking is visible.
    public var intimacyEntries: Int
    /// Journal entries that open under neither the lost key nor this iPhone's journal device key.
    public var journalEntries: Int
    /// Worry Box entries that open under neither the lost key nor this iPhone's worry device key.
    public var worryEntries: Int
    /// Entries of a kind that is hidden on this iPhone, named only as "other private entries".
    public var otherEntries: Int
    /// Whether the entries held for Private (the pending buffer) were sealed under a key that is
    /// gone. The buffer is one sealed file, so it has no count to show, and its line names no kind.
    public var hasUnopenableHeldEntries: Bool
    /// Whether a Sealed backup will be restored once the entries are removed (the app knows its
    /// backup switches; this module does not).
    public var sealedBackupRestoresAfterRemoval: Bool

    /// Creates a set of counts.
    public init(
        cycleEntries: Int = 0,
        intimacyEntries: Int = 0,
        journalEntries: Int = 0,
        worryEntries: Int = 0,
        otherEntries: Int = 0,
        hasUnopenableHeldEntries: Bool = false,
        sealedBackupRestoresAfterRemoval: Bool = false
    ) {
        self.cycleEntries = cycleEntries
        self.intimacyEntries = intimacyEntries
        self.journalEntries = journalEntries
        self.worryEntries = worryEntries
        self.otherEntries = otherEntries
        self.hasUnopenableHeldEntries = hasUnopenableHeldEntries
        self.sealedBackupRestoresAfterRemoval = sealedBackupRestoresAfterRemoval
    }

    /// True when there is nothing to name — no row of any kind and no unopenable held entries.
    public var isEmpty: Bool {
        cycleEntries == 0 && intimacyEntries == 0 && journalEntries == 0 && worryEntries == 0
            && otherEntries == 0 && !hasUnopenableHeldEntries
    }
}

/// What the "entries this iPhone can't open" check says about a passcode setup that would mint a
/// FRESH key (no no-passcode key to adopt, sealed entries present — the setup's
/// `FernletLockError.priorSealedDataPending`).
public enum FernletPriorEntriesReview: Equatable, Sendable {
    /// Every entry here is still openable (under a device key) or there are none: the setup may mint
    /// with the prior data acknowledged. Any backup bookkeeping that spoke for a lost key is cleared.
    case nothingUnopenable
    /// Some entries can never be opened here. The setup stops and sends the user to the Private tab,
    /// whose card names them and asks before anything is removed.
    case unopenableEntries(FernletUnopenableEntryCounts)
    /// The check could not be decided this instant (or a key may still be reachable). Nothing written.
    case tryAgain
}

/// The app's side of the no-passcode Private gate: opens the tab with a deliberate tap, running the
/// "entries this iPhone can't open" check first whenever a fresh key would have to be minted
/// (period-data design 2026-09-30, §4.9) — and runs the same check for a passcode setup that would
/// mint one (§4.4 step 2). The production conformer is the app's `PrivateHubOpenCoordinator`.
///
/// Main-actor isolated (this module's default), like the lock service it drives; `Sendable` so an
/// existential can ride the SwiftUI environment (``SwiftUICore/EnvironmentValues/fernletPrivateHubOpener``)
/// — a main-actor class conformer is Sendable by construction.
public protocol FernletPrivateHubOpening: AnyObject, Sendable {
    /// Whether the tap screen's line may name cycle entries — false while period tracking is hidden,
    /// so the screen shown to whoever holds the phone never names a hidden feature.
    var tapGateNamesCycleEntries: Bool { get }
    /// The Unlock button: open the Private tab, or say why it could not be opened yet.
    func openPrivateHub() async -> FernletTapOpenOutcome
    /// The card's "Remove them and open Private": delete exactly the entries the card named, then
    /// open. Never deletes anything the user was not shown: the conformer re-counts first and, when
    /// the fresh counts differ from `counts`, deletes nothing and answers with the new counts.
    ///
    /// - Parameter counts: What the card showed when the user tapped Remove.
    func removeUnopenableEntriesAndOpen(named counts: FernletUnopenableEntryCounts) async -> FernletTapOpenOutcome
    /// For a passcode setup refused with `priorSealedDataPending`: whether the fresh key it would mint
    /// strands anything. Deletes nothing and mints nothing.
    func reviewPriorEntriesBeforeFreshKey() async -> FernletPriorEntriesReview
}

extension EnvironmentValues {
    /// The app's open coordinator, for the passcode setup sheet wherever it is presented from
    /// (Settings, Privacy & Data, onboarding, the progress-photo nudge): a setup that would mint a
    /// fresh key over sealed entries asks it first (period-data design 2026-09-30, §4.4 step 2).
    /// Nil — a preview, a test host, anything the app did not wire — makes that setup send the user
    /// to the Private tab instead, where the gate runs the same check.
    @Entry public var fernletPrivateHubOpener: (any FernletPrivateHubOpening)? = nil
}

// MARK: - Copy

extension GateCopy {
    /// The no-passcode unlock screen's copy (§10.1). Honest by rule: the tap is friction, and nothing
    /// here may call the page locked, protected or secured.
    enum Tap {
        /// The screen's heading: the tab's own name.
        static var title: String {
            String(localized: "lock.tapGate.title", defaultValue: "Private", bundle: .module,
                   comment: "Heading of the screen shown over the Private tab when no app passcode is set. 'Private' is the tab's name; translate it the way the tab is translated.")
        }

        /// What is behind the button. Cycle entries are named only while period tracking is visible:
        /// this screen is shown to whoever holds the phone, and a hidden feature is never named.
        ///
        /// - Parameter namingCycle: Whether period tracking is visible.
        static func body(namingCycle: Bool) -> String {
            namingCycle
                ? String(localized: "lock.tapGate.body", defaultValue: "Your journal, cycle and worry entries are here.", bundle: .module,
                         comment: "Line under the heading on the Private tab's no-passcode unlock screen, naming what the tab holds.")
                : String(localized: "lock.tapGate.body.noCycle", defaultValue: "Your journal and worry entries are here.", bundle: .module,
                         comment: "Line under the heading on the Private tab's no-passcode unlock screen when cycle tracking is hidden, naming what the tab holds. Must not mention cycle or intimacy.")
        }

        /// The honest line (owner question Q6): what the button is and is not.
        static var honesty: String {
            String(localized: "lock.tapGate.honesty",
                   defaultValue: "No passcode is set, so anyone using your unlocked iPhone can open this page. Your entries stay encrypted on this iPhone. You can add a passcode in Settings.",
                   bundle: .module,
                   comment: "Small print on the Private tab's no-passcode unlock screen. It must stay literally true: the Unlock button needs no passcode, so it does not stop someone holding the unlocked phone. Never translate it into anything that sounds like the page is locked or protected.")
        }

        /// The one button.
        static var unlock: String {
            String(localized: "lock.tapGate.unlock", defaultValue: "Unlock", bundle: .module,
                   comment: "The only button on the Private tab's no-passcode unlock screen. One tap opens the tab; no passcode is asked for.")
        }

        /// The button's VoiceOver hint.
        static var unlockHint: String {
            String(localized: "lock.tapGate.unlock.hint", defaultValue: "Opens your private entries. No passcode is needed.", bundle: .module,
                   comment: "VoiceOver hint for the Unlock button on the Private tab's no-passcode unlock screen.")
        }

        /// A read that could not answer this instant. Never names a reset: a retry can succeed.
        static var tryAgain: String {
            String(localized: "lock.tapGate.tryAgain", defaultValue: "Fernlet can't open this right now. Try again in a moment.", bundle: .module,
                   comment: "Shown under the Unlock button on the Private tab when opening failed for a reason that can pass (the iPhone's keychain did not answer). Must never mention resetting or losing entries.")
        }

        /// The body of the card shown when this iPhone's key for Private can never be opened again.
        ///
        /// Its last sentence promises the Sealed backup restore, true since design unit 5: after the
        /// reset every ambient restore waits for the device owner (`SealedBackupRestoreHold`), and
        /// Privacy & Data's owner-checked "Restore" releases it (review C-U2-R4, design §4.7).
        static var unrecoverableBody: String {
            String(localized: "lock.tapGate.unrecoverable.body",
                   defaultValue: "This iPhone's key for your private entries is gone, so they can't be opened here. Resetting clears Private so you can use it again. It doesn't bring those entries back, but if Sealed backup is on, you can restore it afterwards from Privacy & Data.",
                   bundle: .module,
                   comment: "Card on the Private tab (no app passcode) when the key for private entries was lost, for example after this iPhone was erased and restored from a backup. The entries are already unreadable and resetting does not recover them; say both plainly. The encrypted Sealed backup in iCloud, if the user turned it on, can be restored from Privacy & Data after the reset.")
        }
    }

    /// The "Some entries can't be opened here" card (§10.2).
    enum Unopenable {
        /// The card's heading.
        static var title: String {
            String(localized: "lock.unopenable.title", defaultValue: "Some entries can't be opened here", bundle: .module,
                   comment: "Heading of the card shown on the Private tab when this iPhone holds entries sealed under a key that no longer exists anywhere.")
        }

        /// Why, in plain words.
        static var body: String {
            String(localized: "lock.unopenable.body",
                   defaultValue: "This iPhone has entries that were encrypted on another iPhone, or before this iPhone was erased. The key that opened them never leaves the iPhone it was made on, so no one can open them now.",
                   bundle: .module,
                   comment: "Body of the card naming entries no key on this iPhone can open. It is literally true: the key was device-bound and is gone, so neither Fernlet nor anyone else can open them.")
        }

        /// A cycle count row. "Kind: count" rather than "N kind entries" so no plural form is needed.
        static func cycleCount(_ count: Int) -> String {
            String(localized: "lock.unopenable.count.cycle", defaultValue: "Cycle entries: \(count)", bundle: .module,
                   comment: "One row of counts on the card naming entries that can't be opened. The number is how many cycle entries.")
        }

        /// An intimacy count row.
        static func intimacyCount(_ count: Int) -> String {
            String(localized: "lock.unopenable.count.intimacy", defaultValue: "Intimacy entries: \(count)", bundle: .module,
                   comment: "One row of counts on the card naming entries that can't be opened. The number is how many intimacy entries.")
        }

        /// A journal count row.
        static func journalCount(_ count: Int) -> String {
            String(localized: "lock.unopenable.count.journal", defaultValue: "Journal entries: \(count)", bundle: .module,
                   comment: "One row of counts on the card naming entries that can't be opened. The number is how many journal entries.")
        }

        /// A Worry Box count row.
        static func worryCount(_ count: Int) -> String {
            String(localized: "lock.unopenable.count.worry", defaultValue: "Worry Box entries: \(count)", bundle: .module,
                   comment: "One row of counts on the card naming entries that can't be opened. The number is how many Worry Box entries. 'Worry Box' is a feature name in this app.")
        }

        /// The row for a kind that is hidden on this iPhone: counted, never named.
        static func otherCount(_ count: Int) -> String {
            String(localized: "lock.unopenable.count.other", defaultValue: "Other private entries: \(count)", bundle: .module,
                   comment: "One row of counts on the card naming entries that can't be opened. The number is how many entries of kinds the user has hidden in Settings. Must not name what kind they are.")
        }

        /// The pending buffer's row: one sealed file, so no count, and no kind named (it can be shown
        /// while cycle tracking is hidden).
        static var heldEntries: String {
            String(localized: "lock.unopenable.heldEntries", defaultValue: "Entries saved while Private was closed", bundle: .module,
                   comment: "One row on the card naming entries that can't be opened: what Fernlet was holding until Private opened. They are one sealed file, so there is no count. Must not name what kind they are.")
        }

        /// Said only when a Sealed backup will actually be restored afterwards.
        static var backupWillRestore: String {
            String(localized: "lock.unopenable.backupWillRestore", defaultValue: "Your Sealed backup will be restored after you continue.", bundle: .module,
                   comment: "Shown on the card only when a Sealed backup (a setting in Privacy & Data) will bring the user's history back after the unopenable entries are removed.")
        }

        /// The destructive button: deletes exactly the entries named above, then opens Private.
        static var remove: String {
            String(localized: "lock.unopenable.remove", defaultValue: "Remove them and open Private", bundle: .module,
                   comment: "Destructive button on the card. Permanently deletes exactly the entries listed (they can never be opened anyway), then opens the Private tab.")
        }

        /// Leaves Private closed and deletes nothing.
        static var notNow: String {
            String(localized: "lock.unopenable.notNow", defaultValue: "Not now", bundle: .module,
                   comment: "Button on the card that leaves the Private tab closed and deletes nothing.")
        }
    }

    /// The same card on the Cycle page, for cycle notes from before the cycle history moved into
    /// Fernlet's own records that this iPhone cannot open (period-data design 2026-09-30, §8.2, §10.2).
    enum EarlierCycleNotes {
        /// The card's heading.
        static var title: String {
            String(localized: "lock.unopenable.earlierNotes.title", defaultValue: "Some earlier cycle notes can't be opened here", bundle: .module,
                   comment: "Heading of a card on the Cycle page (inside the Private tab) naming cycle notes saved by an earlier version of the app that can no longer be opened on this iPhone.")
        }

        /// Why, in plain words.
        static var body: String {
            String(localized: "lock.unopenable.earlierNotes.body",
                   defaultValue: "Fernlet moved your earlier cycle notes into your cycle history. These ones can't be opened on this iPhone, so they were left behind. No one can open them now.",
                   bundle: .module,
                   comment: "Body of the Cycle page card naming earlier cycle notes that cannot be opened. They could not be moved into the cycle history because they will not open; nothing about them is readable.")
        }

        /// The count row.
        static func count(_ count: Int) -> String {
            String(localized: "lock.unopenable.earlierNotes.count", defaultValue: "Earlier cycle notes: \(count)", bundle: .module,
                   comment: "The count row on the Cycle page card naming earlier cycle notes that can't be opened. The number is how many notes.")
        }

        /// The destructive button: deletes exactly the notes named above. The Private tab is already
        /// open here, so it does not say "and open Private".
        static var remove: String {
            String(localized: "lock.unopenable.earlierNotes.remove", defaultValue: "Remove them", bundle: .module,
                   comment: "Destructive button on the Cycle page card. Permanently deletes exactly the earlier cycle notes listed (they can never be opened anyway).")
        }
    }
}

// MARK: - The tap gate overlay

/// The Private tab's no-passcode unlock screen (§10.1): a decorative symbol, the heading, one line
/// on what is here, the honest line, and exactly ONE interactive element — the Unlock button — which
/// hands the tap to the app's ``FernletPrivateHubOpening`` coordinator. Nothing happens on appear.
///
/// When the coordinator answers ``FernletTapOpenOutcome/unopenableEntries(_:)`` the button is
/// replaced by ``FernletUnopenableEntriesCard``; when it answers
/// ``FernletTapOpenOutcome/unrecoverable`` it is replaced by the lost-key card whose only control is
/// the reset, raised through `onResetRequested` onto the gate's own confirmation. Every in-flight
/// call is single-flight (``isWorking``).
///
/// Hosted by `FernletLockGateModifier` in its not-configured slot, which carries `.isModal`; the
/// modifier hides the gated content from assistive technology while this is up.
struct FernletTapGateOverlay: View {
    /// The app's open coordinator.
    let opener: any FernletPrivateHubOpening
    /// Raises the gate's destructive reset confirmation (the lost-key card's only way forward).
    let onResetRequested: () -> Void

    /// What the screen is showing below its heading.
    private enum Phase: Equatable {
        case unlock(showsTryAgain: Bool)
        case unopenable(FernletUnopenableEntryCounts)
        case unrecoverable
    }

    @State private var phase: Phase = .unlock(showsTryAgain: false)
    /// One coordinator call at a time; every control is disabled while one runs.
    @State private var isWorking = false
    /// The floating tab bar's height: the overlay paints beneath it, so the scroll content ends
    /// clear of it (a long card's "Not now" must never rest behind the bar).
    @Environment(\.fernletTabBarClearance) private var tabBarClearance

    var body: some View {
        ZStack {
            Color.parchment.ignoresSafeArea()
            GeometryReader { proxy in
                ScrollView {
                    VStack(spacing: 20) {
                        Spacer(minLength: 0)
                        heading
                        phaseContent
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 32)
                    .padding(.top, 24)
                    .padding(.bottom, 24 + tabBarClearance)
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
    }

    /// The symbol, the heading, what is here, and the honest line — text only, nothing operable.
    private var heading: some View {
        VStack(spacing: 12) {
            // Decorative next to the heading; without this VoiceOver speaks the raw symbol name.
            Image(systemName: "lock.open")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(Color.moss)
                .frame(width: 88, height: 88)
                .background(Color.moss.opacity(0.10), in: Circle())
                .accessibilityHidden(true)
            Text(GateCopy.Tap.title)
                .font(.fernlet(.header))
                .foregroundStyle(Color.bark)
                .accessibilityAddTraits(.isHeader)
            Text(GateCopy.Tap.body(namingCycle: opener.tapGateNamesCycleEntries))
                .font(.fernlet(.body))
                .foregroundStyle(Color.bark)
                .multilineTextAlignment(.center)
                .fernletWrappingText()
            Text(GateCopy.Tap.honesty)
                .font(.fernlet(.bodySmall))
                .foregroundStyle(Color.slate)
                .multilineTextAlignment(.center)
                .fernletWrappingText()
        }
    }

    @ViewBuilder private var phaseContent: some View {
        switch phase {
        case .unlock(let showsTryAgain):
            tapGateControls(showsTryAgain: showsTryAgain)
        case .unopenable(let counts):
            FernletUnopenableEntriesCard(
                counts: counts,
                isWorking: isWorking,
                onRemove: { run { await opener.removeUnopenableEntriesAndOpen(named: counts) } },
                onNotNow: { phase = .unlock(showsTryAgain: false) }
            )
        case .unrecoverable:
            unrecoverableCard
        }
    }

    // BEGIN tap-gate controls — exactly one interactive element (design invariant I20, pinned by
    // LockGateAccessibilityBoundaryTests). No credential field of any kind may be added here.
    private func tapGateControls(showsTryAgain: Bool) -> some View {
        VStack(spacing: 12) {
            if showsTryAgain {
                Text(GateCopy.Tap.tryAgain)
                    .font(.fernlet(.body))
                    .foregroundStyle(Color.terracottaInk)
                    .multilineTextAlignment(.center)
                    .fernletWrappingText()
            }
            Button(GateCopy.Tap.unlock) { run { await opener.openPrivateHub() } }
                .buttonStyle(.plain)
                .font(.fernlet(.label))
                .foregroundStyle(Color.onMoss)
                .padding(.horizontal, 36)
                .padding(.vertical, 16)
                .background(Color.mossFill.opacity(isWorking ? 0.55 : 1), in: RoundedRectangle(cornerRadius: 16))
                .contentShape(RoundedRectangle(cornerRadius: 16))
                .fernletTapTarget()
                .disabled(isWorking)
                .accessibilityHint(GateCopy.Tap.unlockHint)
                .accessibilityIdentifier("lock.tapGate.unlock")
        }
    }
    // END tap-gate controls

    /// The lost-key card: the heading the passcode screen uses for the same state, a no-passcode
    /// body, and the reset as the only control.
    private var unrecoverableCard: some View {
        VStack(spacing: 12) {
            Text(FernletLockCopy.Unlock.enclaveLostTitle)
                .font(.fernlet(.header))
                .foregroundStyle(Color.bark)
                .multilineTextAlignment(.center)
                .fernletWrappingText()
            Text(GateCopy.Tap.unrecoverableBody)
                .font(.fernlet(.body))
                .foregroundStyle(Color.slate)
                .multilineTextAlignment(.center)
                .fernletWrappingText()
            Button(FernletLockCopy.Action.resetAppLock, role: .destructive, action: onResetRequested)
                .font(.fernlet(.label))
                .fernletTapTarget()
                .accessibilityIdentifier("lock.tapGate.reset")
        }
        .padding(20)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 18))
    }

    /// Runs one coordinator call (single-flight) and moves to the phase its answer names. A failure
    /// is spoken, never only drawn; success is silent (the overlay simply goes away).
    private func run(_ call: @escaping () async -> FernletTapOpenOutcome) {
        guard !isWorking else { return }
        isWorking = true
        Task { @MainActor in
            let outcome = await call()
            isWorking = false
            apply(outcome)
        }
    }

    /// The phase an outcome leads to.
    private func apply(_ outcome: FernletTapOpenOutcome) {
        switch outcome {
        case .opened:
            phase = .unlock(showsTryAgain: false)
        case .unopenableEntries(let counts):
            phase = .unopenable(counts)
            AccessibilityNotification.ScreenChanged().post()
        case .tryAgain:
            phase = .unlock(showsTryAgain: true)
            FernletAnnouncer.system.announce(.error, resolved: GateCopy.Tap.tryAgain)
        case .unrecoverable:
            phase = .unrecoverable
            AccessibilityNotification.ScreenChanged().post()
        }
    }
}

// MARK: - The "can't be opened" card

/// "Some entries can't be opened here" (§10.2): what this iPhone holds that no key here can open,
/// counted by kind, with "Remove them and open Private" (destructive) and "Not now".
///
/// Nothing is deleted without the Remove tap, and Remove deletes exactly what the counts name — the
/// app's coordinator re-checks both before it deletes. Public so the Cycle page can show the same
/// component for its earlier-notes variant (design §8.2): ``Wording/earlierCycleNotes`` swaps the
/// heading, the body, the count line and the Remove label (the tab is already open there) and the
/// two identifiers, and keeps everything else.
public struct FernletUnopenableEntriesCard: View {
    /// Which of the card's two uses this is.
    public enum Wording: Sendable {
        /// The Private tab's gate: entries a fresh key would be minted over (§4.9, §10.2).
        case privateTab
        /// The Cycle page: earlier cycle notes the legacy import could not open (§8.2); counted in
        /// ``FernletUnopenableEntryCounts/cycleEntries``.
        case earlierCycleNotes
    }

    /// What to name.
    let counts: FernletUnopenableEntryCounts
    /// Disables both buttons while a call is in flight.
    let isWorking: Bool
    /// Which use this is.
    let wording: Wording
    /// The destructive button.
    let onRemove: () -> Void
    /// "Not now".
    let onNotNow: () -> Void

    /// Creates the card.
    ///
    /// - Parameters:
    ///   - counts: The entries to name.
    ///   - isWorking: Whether a removal is already running.
    ///   - wording: Which use this is; the Private tab's by default.
    ///   - onRemove: Called by the destructive button.
    ///   - onNotNow: Called by "Not now".
    public init(
        counts: FernletUnopenableEntryCounts,
        isWorking: Bool,
        wording: Wording = .privateTab,
        onRemove: @escaping () -> Void,
        onNotNow: @escaping () -> Void
    ) {
        self.counts = counts
        self.isWorking = isWorking
        self.wording = wording
        self.onRemove = onRemove
        self.onNotNow = onNotNow
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(wording == .earlierCycleNotes ? GateCopy.EarlierCycleNotes.title : GateCopy.Unopenable.title)
                .font(.fernlet(.header))
                .foregroundStyle(Color.bark)
                .accessibilityAddTraits(.isHeader)
                .fernletWrappingText()
            Text(wording == .earlierCycleNotes ? GateCopy.EarlierCycleNotes.body : GateCopy.Unopenable.body)
                .font(.fernlet(.body))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()
            VStack(alignment: .leading, spacing: 4) {
                ForEach(countLines, id: \.self) { line in
                    Text(line)
                        .font(.fernlet(.label))
                        .foregroundStyle(Color.bark)
                        .fernletWrappingText()
                }
            }
            if counts.sealedBackupRestoresAfterRemoval {
                Text(GateCopy.Unopenable.backupWillRestore)
                    .font(.fernlet(.bodySmall))
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()
            }
            buttons
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 18))
    }

    /// The two buttons, the destructive one first.
    private var buttons: some View {
        VStack(spacing: 8) {
            Button(wording == .earlierCycleNotes ? GateCopy.EarlierCycleNotes.remove : GateCopy.Unopenable.remove, role: .destructive, action: onRemove)
                .font(.fernlet(.label))
                .frame(maxWidth: .infinity)
                .fernletTapTarget()
                .disabled(isWorking)
                .accessibilityIdentifier(wording == .earlierCycleNotes ? "cycle.unopenableNotes.remove" : "lock.unopenable.remove")
            Button(GateCopy.Unopenable.notNow, action: onNotNow)
                .font(.fernlet(.label))
                .foregroundStyle(Color.slate)
                .frame(maxWidth: .infinity)
                .fernletTapTarget()
                .disabled(isWorking)
                .accessibilityIdentifier(wording == .earlierCycleNotes ? "cycle.unopenableNotes.notNow" : "lock.unopenable.notNow")
        }
        .padding(.top, 4)
    }

    /// One line per kind that has something to name, in a fixed order.
    private var countLines: [String] {
        guard wording == .privateTab else {
            return counts.cycleEntries > 0 ? [GateCopy.EarlierCycleNotes.count(counts.cycleEntries)] : []
        }
        var lines: [String] = []
        if counts.cycleEntries > 0 { lines.append(GateCopy.Unopenable.cycleCount(counts.cycleEntries)) }
        if counts.hasUnopenableHeldEntries { lines.append(GateCopy.Unopenable.heldEntries) }
        if counts.intimacyEntries > 0 { lines.append(GateCopy.Unopenable.intimacyCount(counts.intimacyEntries)) }
        if counts.journalEntries > 0 { lines.append(GateCopy.Unopenable.journalCount(counts.journalEntries)) }
        if counts.worryEntries > 0 { lines.append(GateCopy.Unopenable.worryCount(counts.worryEntries)) }
        if counts.otherEntries > 0 { lines.append(GateCopy.Unopenable.otherCount(counts.otherEntries)) }
        return lines
    }
}
