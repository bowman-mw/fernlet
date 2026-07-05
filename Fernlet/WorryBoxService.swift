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

    @ObservationIgnored private let repository: any WorryStoring
    @ObservationIgnored private var mode: ActivationMode = .inactive
    @ObservationIgnored private var userContentKey: SymmetricKey?

    init(repository: (any WorryStoring)? = nil) {
        self.repository = repository ?? WorryNarrativeRepository()
    }

    // MARK: - Lock lifecycle (driven by ContentView's lock-state observers)

    /// Call whenever the lock state changes (and once at startup). On unlock, worries written
    /// under the device fallback key (while locked / before a lock existed) are re-sealed under
    /// the user content key — the same migration journals perform on activation.
    func updateActivation(lockState: FernletLockState, contentKey: SymmetricKey?) {
        switch lockState {
        case .notConfigured:
            mode = .noLock
            userContentKey = nil
        case .unlocked:
            if let contentKey {
                mode = .unlocked
                userContentKey = contentKey
                try? repository.reencryptAll(from: deviceWorryKey, to: contentKey)
            } else {
                mode = .locked
                userContentKey = nil
            }
        case .locked:
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
    }

    /// Releases (deletes) a kept worry. Best-effort — releasing is a letting-go gesture and
    /// should never surface an error.
    func release(_ id: UUID) {
        try? repository.delete(id: id)
        worries.removeAll { $0.id == id }
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
