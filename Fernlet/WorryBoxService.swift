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

@MainActor
@Observable
final class WorryBoxService {
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
    /// Fired after a worry is released (deleted) from the hub, with the worry's id. Optional hook for
    /// callers that want to react to a release; the lifetime count is NOT driven from here — it is
    /// incremented at the "let it go" gesture (`addWorry`) so First Aid's primary flow counts.
    @ObservationIgnored var onRelease: ((UUID) -> Void)?

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
                try? repository.reencryptAll(from: deviceWorryKey, to: contentKey)
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

    // MARK: - Worry mutations

    /// Seals a worry into the private store. Always succeeds in finding a key: the active key
    /// when available, else the device fallback key (mirrors `JournalSealingCoordinator.seal`),
    /// so a worry written from First Aid while locked still never exists as plaintext at rest.
    func addWorry(_ text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
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

    /// Releases (deletes) a kept worry. Best-effort — releasing is a letting-go gesture and
    /// should never surface an error. Does NOT change the lifetime count (that grew at `addWorry`).
    func release(_ id: UUID) {
        try? repository.delete(id: id)
        worries.removeAll { $0.id == id }
        onRelease?(id)
    }

    /// Bulk purge for "Reset everything": deletes every sealed worry row (even while locked — rows
    /// are dropped, not decrypted) and zeroes the lifetime count. Wired from `FernletStore.resetAll`
    /// so the app's most sensitive free-text data doesn't survive a full data reset. Returns whether
    /// the row delete landed — the "delete everything" dialog promises Worry Box notes by name, so a
    /// throw here must reach the outcome instead of being swallowed by `try?`. The in-memory state and
    /// count are cleared either way (the user asked for them gone; only the disk rows can fail).
    @discardableResult
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
        if let key = activeKey {
            worries = (try? repository.worries(contentKey: key)) ?? []
        } else {
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
    /// Mirrors `JournalSealingCoordinator.deviceJournalKey`.
    private var deviceWorryKey: SymmetricKey {
        if let data = KeychainItem.load(for: .deviceWorryKey, service: KeychainItem.journalService) {
            return SymmetricKey(data: data)
        }
        let key = SymmetricKey(size: .bits256)
        let keyData = key.withUnsafeBytes { Data($0) }
        KeychainItem.store(keyData, for: .deviceWorryKey, service: KeychainItem.journalService)
        return key
    }
}
