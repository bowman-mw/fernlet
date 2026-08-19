//
//  WorryBoxService.swift
//  Fernlet
//
//  App-side owner of the Worry Box: sealed, LOCAL-ONLY worry notes. Mirrors the
//  JournalSealingCoordinator key model in miniature — user lock content key when
//  unlocked, a device Keychain key when no lock is configured (or as the write
//  fallback while locked), with device-key rows folded under the user key at unlock.
//
//  Because worries live EXCLUSIVELY in the sealed private store (never in FernletDay,
//  the synced blob, MemoryNotes, or any SealedBackup payload), none of the journal
//  strip/scrub/sealed-ID machinery is needed here. Deliberately device-only:
//  "let it go" data shouldn't follow you across devices.
//

import CryptoKit
import Foundation
import Observation
import FernletFoundation
import FernletLock
import PrivateMemoryStore

/// App-side owner of the Worry Box: sealed, LOCAL-ONLY worry notes.
///
/// Mirrors the ``JournalSealingCoordinator`` key model in miniature — the user lock content key
/// when unlocked, a device Keychain key when no lock is configured (or as the write fallback while
/// locked), with device-key rows folded under the user key at unlock via
/// ``updateActivation(lockState:contentKey:)``.
///
/// Because worries live EXCLUSIVELY in the sealed private store (`WorryNarrativeRepository` —
/// never in `FernletDay`, the synced blob, MemoryNotes, or any ``SealedBackupService`` payload),
/// none of the journal strip/scrub/sealed-ID machinery is needed here. Deliberately device-only:
/// "let it go" data shouldn't follow you across devices, and even the ``lifetimeLetGoCount``
/// metadata stays in local `UserDefaults` rather than the synced milestone ledger.
///
/// Main-actor isolated and `@Observable`; ``WorryEntryView`` (First Aid) and ``WorryBoxView``
/// (Private hub) drive it, ContentView's lock-state observers feed the activation lifecycle, and
/// ``FernletStore``'s reset-all funnel calls ``releaseAll()``. A write always finds a key (device
/// fallback while locked), so a worry never exists as plaintext at rest; reads yield an empty list
/// whenever no key is active.
@MainActor
@Observable
final class WorryBoxService {
    /// The lock-lifecycle mode the service was last activated into, which decides the active
    /// read/write key (device Keychain key, user content key, or none while locked/inactive).
    ///
    /// Set only by ``updateActivation(lockState:contentKey:)``; the `activeKey` computed
    /// property is its sole reader.
    private enum ActivationMode {
        case inactive
        case noLock
        case unlocked
        case locked
    }

    /// Decrypted worries, newest first. Empty while locked (the Private hub's lock gate
    /// blocks the list UI anyway; this keeps plaintext out of memory too).
    private(set) var worries: [WorryNarrative] = []

    /// Lifetime count of worries let go — the number MilestonesView shows ("you've let N worries go").
    /// DEVICE-LOCAL by design: kept in `UserDefaults`, never in the synced milestone ledger, because
    /// even the metadata "a worry was let go on day X" would contradict the Worry Box's promise that
    /// worries "never sync anywhere". No coins are awarded for it (a device-local coin award would
    /// desync the wallet across devices). Monotonic — only `releaseAll` (a full data reset) zeroes it.
    private(set) var lifetimeLetGoCount: Int {
        didSet { defaults.set(lifetimeLetGoCount, forKey: Self.letGoCountKey) }
    }
    private static let letGoCountKey = "worryBox.lifetimeLetGoCount"

    @ObservationIgnored private let repository: any WorryStoring
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var mode: ActivationMode = .inactive
    @ObservationIgnored private var userContentKey: SymmetricKey?

    /// The hard cap on a worry's text, enforced at ``addWorry(_:)`` — the one seam through which
    /// every composer (First Aid's entry view and the Private hub's field) reaches the sealed store.
    static let maxCharacters = 300

    init(repository: (any WorryStoring)? = nil, defaults: UserDefaults = .standard) {
        self.repository = repository ?? WorryNarrativeRepository()
        self.defaults = defaults
        self.lifetimeLetGoCount = defaults.integer(forKey: Self.letGoCountKey)
    }

    // MARK: - Lock lifecycle (driven by ContentView's lock-state observers)

    /// Call whenever the lock state changes (and once at startup). On unlock, worries written
    /// under the device fallback key (while locked / before a lock existed) are re-sealed under
    /// the user content key — the same migration journals perform on activation.
    /// The Worry Box lives in the Private tab, so it follows the `.privateHub` unlock scope and no
    /// other. Matched explicitly rather than on a bare `.unlocked` so an unlock held by the
    /// progress-photo strip or App-lock settings lands in the locked branch by construction — not
    /// merely because the caller happened to hand us a nil key.
    func updateActivation(lockState: FernletLockState, contentKey: SymmetricKey?) {
        switch lockState {
        case .notConfigured:
            mode = .noLock
            userContentKey = nil
        case .unlocked(.privateHub):
            if let contentKey {
                mode = .unlocked
                userContentKey = contentKey
                foldDeviceKeyRows(into: contentKey)
            } else {
                mode = .locked
                userContentKey = nil
            }
        case .unlocked, .locked:
            mode = .locked
            userContentKey = nil
        }
        reload()
    }

    /// Re-seals the worries written under the device fallback key so they open under the user key.
    ///
    /// The rows stay readable under the DEVICE key on either failure leg; this fold runs again on the
    /// next `.unlocked(.privateHub)` transition, so it retries then. Until it lands the hub shows only
    /// user-key rows — audited rather than silent.
    private func foldDeviceKeyRows(into contentKey: SymmetricKey) {
        guard let deviceKey = deviceWorryKey else {
            FernletAuditLog.log("worryBox.rekey.failed", context: [:])
            return
        }
        do {
            try repository.reencryptAll(from: deviceKey, to: contentKey)
        } catch {
            FernletAuditLog.log("worryBox.rekey.failed", context: [:])
        }
    }

    // MARK: - Worry mutations

    /// Seals a worry into the private store under the active key when available, else the device
    /// fallback key (mirrors `JournalSealingCoordinator.seal`), so a worry written from First Aid
    /// while locked still never exists as plaintext at rest.
    ///
    /// When NEITHER key is obtainable (a keychain row that exists but cannot be read), `insert`
    /// throws `FernletLockError.locked` and the lifetime count is deliberately not advanced: nothing
    /// is written under a doomed key and the composer surfaces the failure rather than claiming a
    /// worry was let go.
    func addWorry(_ text: String) throws {
        // R3/R5: the cap lives at the entry point, not in one composer — the hub's field has none.
        let trimmed = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxCharacters))
        guard !trimmed.isEmpty else { return }
        let worry = WorryNarrative(text: trimmed)
        try repository.insert(worry, contentKey: activeKey ?? deviceWorryKey)
        if activeKey != nil {
            worries.insert(worry, at: 0)
        }
        // Writing a worry down and setting it aside IS the "letting go" gesture (First Aid's "Let it
        // go" button routes here), so this is where the lifetime count grows — once per worry, keyed
        // to the write, so a later hub "Release" of the same worry doesn't double-count it.
        lifetimeLetGoCount += 1
    }

    /// Releases (deletes) a kept worry, reporting whether the sealed row actually went away.
    ///
    /// A failed disk delete keeps the worry in the in-memory list (so memory and disk agree and the
    /// row does not reappear on the next ``reload()``), audits the failure, and returns `false` so
    /// the caller can settle its release animation back instead of showing a letting-go that did not
    /// happen. Does NOT change the lifetime count (that grew at `addWorry`).
    func release(_ id: UUID) -> Bool {
        do {
            try repository.delete(id: id)
        } catch {
            FernletAuditLog.log("worryBox.release.failed", context: ["id": id.uuidString])
            return false
        }
        worries.removeAll { $0.id == id }
        return true
    }

    /// Bulk purge for "Reset everything": deletes every sealed worry row (even while locked — rows
    /// are dropped, not decrypted) and zeroes the lifetime count. Wired from `FernletStore.resetAll`
    /// so the app's most sensitive free-text data doesn't survive a full data reset. Returns whether
    /// the row delete landed — the "delete everything" dialog promises Worry Box notes by name, so a
    /// throw here must reach the outcome instead of being swallowed by `try?`. The in-memory state and
    /// count are cleared either way (the user asked for them gone; only the disk rows can fail).
    func releaseAll() -> Bool {
        let deleted: Bool
        do {
            try repository.deleteAll()
            deleted = true
        } catch {
            deleted = false
        }
        worries = []
        lifetimeLetGoCount = 0
        return deleted
    }

    /// Re-reads the sealed store with the currently active key (empty while locked/inactive).
    func reload() {
        guard let key = activeKey else {
            worries = []
            return
        }
        do {
            worries = try repository.worries(contentKey: key)
        } catch {
            // Fail closed (never a plaintext fallback), but say so: without the audit line a failed
            // decrypt is indistinguishable from an empty box.
            FernletAuditLog.log("worryBox.read.failed", context: [:])
            worries = []
        }
    }

    // MARK: - Keys

    private var activeKey: SymmetricKey? {
        switch mode {
        case .inactive, .locked: nil
        case .noLock: deviceWorryKey
        case .unlocked: userContentKey
        }
    }

    /// Device-bound key generated on first use and stored in the Keychain (never iCloud-synced).
    /// Shares `KeychainItem.loadOrCreateSymmetricKey` with `JournalSealingCoordinator.deviceJournalKey`.
    ///
    /// Nil when the keychain row exists but could not be read: the helper fails closed rather than
    /// minting over a key it could not read, which would make every sealed worry unopenable. A nil
    /// key means no read (empty box), no write (`insert` throws `FernletLockError.locked`) and no
    /// fold — never a mint. The property is recomputed on each access, so the next attempt retries.
    private var deviceWorryKey: SymmetricKey? {
        KeychainItem.loadOrCreateSymmetricKey(for: .deviceWorryKey, service: KeychainItem.journalService)
    }
}
