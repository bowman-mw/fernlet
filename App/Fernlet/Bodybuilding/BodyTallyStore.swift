import CryptoKit
import FernletFoundation
import Foundation
import Observation
import PrivateHealthStore
import PrivateStoreCore

/// Why a body-tally write did not land. Never shown as text: the UI picks its own gentle copy.
enum BodyTallyWriteFailure: Equatable {
    /// The day key is not a `yyyy-MM-dd` calendar day.
    case invalidDay
    /// The journal device key could not be read or created this instant (a keychain that did not
    /// answer, e.g. before the first unlock after a restart). Nothing is minted over an unreadable key.
    case keyUnavailable
    /// The store already holds `BodyTallyRepository.maxStoredRows` days.
    case storeFull
    /// A stored row could not be decided this attempt; nothing was written, and a retry may succeed.
    case undecidedRows
    /// The sealed store refused the read or the write (not loaded, mid-rebuild, a failed save).
    case storeError
}

/// What one body-tally write did.
enum BodyTallyWriteResult: Equatable {
    /// The change is sealed on disk.
    case saved
    /// The day already held exactly this; nothing was written.
    case unchanged
    /// Refused gently: the day already holds the most visits (30) or free meals (20) it can.
    case atLimit
    /// A decoy (duress) session: nothing was read or written.
    case droppedInDecoy
    /// The write did not land; ``BodyTallyStore/lastWriteFailure`` says so too, so it is never silent.
    case failed(BodyTallyWriteFailure)
}

/// The app's `@MainActor` funnel for the sealed body tallies — bathroom visits and free-meal tags
/// (World bodybuilding spec §5–§7; round 7 piece B1). Every read and write of a `BodyTally` row
/// goes through here; views reach it through the `FernletStore` extension in
/// `FernletStore+BodyTally.swift`, never a raw repository.
///
/// **Key.** Every tally is sealed under the journal's device fallback key (keychain
/// `com.fernlet.journal`, account `com.fernlet.journal.deviceKey`, `ThisDeviceOnly`) with the tallies'
/// own HKDF purpose — `BodyTallyRepository` explains why the Private tab's content key cannot be used
/// for a count shown on the Log panel. Reads use the key WITHOUT minting it (no key → no row can
/// open → nothing to show); a write mints it exactly as the journal's closed-tab write does, and never
/// over a keychain read that did not answer. So a tap on the Bathroom tile while Private is closed or
/// locked is sealed at once — never parked, never dropped. A write that cannot land returns
/// ``BodyTallyWriteResult/failed(_:)`` and sets ``lastWriteFailure``, which the UI can watch: never a
/// silent loss.
///
/// **Decoy.** Every gated call takes `isDecoy` (the `FernletStore` extension passes
/// `duressSessionActive`): in a decoy, reads answer empty and writes are dropped before any key or
/// row is touched, so nothing real shows and nothing is kept. ``deleteAll()`` is UNGATED and keyless
/// — a wipe must work in every state.
///
/// **Observation.** ``changeToken`` moves after every write and delete this funnel makes, and every
/// read registers a dependency on it, so a SwiftUI view that reads a tally redraws when one changes.
/// The decrypted cache is in memory only and re-validated on every read against the device key and
/// the keyless row count, so a wipe that emptied the store or destroyed the key underneath it is
/// never shown from the cache. A writer outside this funnel (the later Sealed backup restore) calls
/// ``noteExternalChange()``.
@MainActor
@Observable
final class BodyTallyStore {
    /// The process-wide funnel on the shared sealed store and the real journal device key.
    static let shared = BodyTallyStore()

    /// Moves by one after every change this funnel makes (and on ``noteExternalChange()``). Reads
    /// register on it; it answers "did anything change", never "how much".
    private(set) var changeToken = 0
    /// The most recent write that did not land, cleared by the next one that does.
    private(set) var lastWriteFailure: BodyTallyWriteFailure?

    /// The decrypted tallies of the last full read, tagged with the key bytes and row count they were
    /// read at.
    private struct Cache {
        let keyData: Data
        var rowCount: Int
        var tallies: [String: BodyDayTally]
    }

    @ObservationIgnored private let repository: BodyTallyRepository
    @ObservationIgnored private let deviceKeyService: String
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var cache: Cache?

    /// Creates the funnel.
    ///
    /// - Parameters:
    ///   - repository: The sealed CRUD layer; defaults to one on the shared private store.
    ///   - deviceKeyService: The keychain service of the journal device key —
    ///     `KeychainItem.journalService` in production; tests pass a scoped one.
    ///   - now: The clock for `updatedAt` stamps.
    init(
        repository: BodyTallyRepository = BodyTallyRepository(),
        deviceKeyService: String = KeychainItem.journalService,
        now: @escaping () -> Date = { Date() }
    ) {
        self.repository = repository
        self.deviceKeyService = deviceKeyService
        self.now = now
    }

    /// Creates the funnel over a repository on `controller`'s store (`nil`: the shared one).
    convenience init(controller: PrivatePersistenceController?, deviceKeyService: String = KeychainItem.journalService) {
        self.init(repository: BodyTallyRepository(controller: controller), deviceKeyService: deviceKeyService)
    }

    // MARK: - Reads (gated)

    /// Every tally that opens, by day — empty in a decoy, without a device key, or when the store
    /// could not be read (named in the audit log).
    func allTallies(isDecoy: Bool) -> [String: BodyDayTally] {
        access(keyPath: \.changeToken)
        guard !isDecoy, case .found(let keyData) = readDeviceKey() else { return [:] }
        return loadedTallies(keyData: keyData) ?? [:]
    }

    /// The tally of one `yyyy-MM-dd` day, or `nil` when it has none (or in a decoy).
    func tally(on dayKey: String, isDecoy: Bool) -> BodyDayTally? {
        guard BodyDayTally.isValidDayKey(dayKey) else { return nil }
        return allTallies(isDecoy: isDecoy)[dayKey]
    }

    /// The tallies of the days `startKey...endKey` (inclusive, `yyyy-MM-dd`), by day. Empty for a
    /// malformed or reversed range, and in a decoy.
    func tallies(from startKey: String, through endKey: String, isDecoy: Bool) -> [String: BodyDayTally] {
        guard BodyDayTally.isValidDayKey(startKey), BodyDayTally.isValidDayKey(endKey), startKey <= endKey else { return [:] }
        // `yyyy-MM-dd` keys order lexicographically exactly as their days do.
        return allTallies(isDecoy: isDecoy).filter { $0.key >= startKey && $0.key <= endKey }
    }

    // MARK: - Writes (gated)

    /// Adds one bathroom visit to the day (the Bathroom tile's tap). ``BodyTallyWriteResult/atLimit``
    /// at 30.
    @discardableResult
    func addBathroomVisit(on dayKey: String, isDecoy: Bool) -> BodyTallyWriteResult {
        mutate(dayKey, isDecoy: isDecoy) { $0.addingBathroomVisit() }
    }

    /// Sets the day's visit count (the tile's hold-to-fix), clamped to `0...30`; zero with no free
    /// meal leaves the day with no row at all.
    @discardableResult
    func setBathroomVisits(_ count: Int, on dayKey: String, isDecoy: Bool) -> BodyTallyWriteResult {
        mutate(dayKey, isDecoy: isDecoy) { $0.settingBathroomVisits(count) }
    }

    /// Tags or untags a meal as a free meal on the day. ``BodyTallyWriteResult/atLimit`` past 20.
    @discardableResult
    func setFreeMeal(_ isFree: Bool, mealID: UUID, on dayKey: String, isDecoy: Bool) -> BodyTallyWriteResult {
        mutate(dayKey, isDecoy: isDecoy) { $0.settingFreeMeal(isFree, mealID: mealID) }
    }

    /// Deletes the day's tally. Needs the device key (there is no plaintext day to find the row by);
    /// with no key on this iPhone nothing can open, so there is nothing to delete.
    @discardableResult
    func deleteTally(on dayKey: String, isDecoy: Bool) -> BodyTallyWriteResult {
        guard !isDecoy else { return .droppedInDecoy }
        guard BodyDayTally.isValidDayKey(dayKey) else { return fail(.invalidDay) }
        let keyData: Data
        switch readDeviceKey() {
        case .found(let data): keyData = data
        case .absent: return .unchanged
        case .unreadable: return fail(.keyUnavailable)
        }
        do {
            let removed = try repository.delete(dayKey: dayKey, key: SymmetricKey(data: keyData))
            cache = nil
            guard removed > 0 else { return .unchanged }
            lastWriteFailure = nil
            changeToken &+= 1
            return .saved
        } catch {
            cache = nil
            return fail(.storeError)
        }
    }

    // MARK: - Ungated

    /// Drops every tally row WITHOUT decrypting — ungated and keyless, for the wipe paths.
    ///
    /// - Returns: Whether the delete succeeded (an empty store counts as success).
    @discardableResult
    func deleteAll() -> Bool {
        cache = nil
        changeToken &+= 1
        do {
            _ = try repository.deleteAll()
            return true
        } catch {
            FernletAuditLog.log("bodyTally.deleteAll.failed", context: ["error": "\(type(of: error))"])
            return false
        }
    }

    /// Something outside this funnel changed the rows: drop the cache and move the token.
    func noteExternalChange() {
        cache = nil
        changeToken &+= 1
    }
}

// MARK: - Internals

extension BodyTallyStore {
    /// The three answers a no-mint keychain read can give.
    private enum DeviceKeyRead {
        case found(Data)
        case absent
        case unreadable
    }

    /// Reads the journal device key WITHOUT minting.
    private func readDeviceKey() -> DeviceKeyRead {
        switch KeychainItem.loadDistinguishingAbsence(account: KeychainItem.Account.deviceJournalKey.rawValue, service: deviceKeyService) {
        case .found(let data): return .found(data)
        case .absent: return .absent
        case .unreadable: return .unreadable
        }
    }

    /// The key a write seals under: the existing device key, or a new one minted exactly as the
    /// journal mints it — never over a read that did not answer. `nil` when there is none to use.
    private func writeKeyData() -> Data? {
        switch readDeviceKey() {
        case .found(let data):
            return data
        case .unreadable:
            return nil
        case .absent:
            guard KeychainItem.loadOrCreateSymmetricKey(for: .deviceJournalKey, service: deviceKeyService) != nil,
                  case .found(let data) = readDeviceKey() else { return nil }
            return data
        }
    }

    /// The decrypted tallies under `keyData`, from the cache when it is still valid (same key, same
    /// keyless row count), else from the store. `nil` when the store could not be read. A read that
    /// met an undecided row is answered but not cached, so the next read retries it.
    private func loadedTallies(keyData: Data) -> [String: BodyDayTally]? {
        let rowCount: Int
        do {
            rowCount = try repository.rowCount()
        } catch {
            FernletAuditLog.log("bodyTally.read.failed", context: ["step": "count"])
            cache = nil
            return nil
        }
        if let cache, cache.keyData == keyData, cache.rowCount == rowCount { return cache.tallies }
        do {
            let page = try repository.allTallies(key: SymmetricKey(data: keyData))
            cache = page.transientCount == 0 ? Cache(keyData: keyData, rowCount: rowCount, tallies: page.tallies) : nil
            return page.tallies
        } catch {
            FernletAuditLog.log("bodyTally.read.failed", context: ["step": "open"])
            cache = nil
            return nil
        }
    }

    /// The shared body of the three tally writes: gate, key, read the day, apply `change`, seal.
    private func mutate(_ dayKey: String, isDecoy: Bool, _ change: (BodyDayTally) -> BodyDayTally?) -> BodyTallyWriteResult {
        guard !isDecoy else { return .droppedInDecoy }
        guard BodyDayTally.isValidDayKey(dayKey) else { return fail(.invalidDay) }
        guard let keyData = writeKeyData() else { return fail(.keyUnavailable) }
        guard let current = loadedTallies(keyData: keyData) else { return fail(.storeError) }
        let stamp = now()
        let base = current[dayKey] ?? BodyDayTally(dayKey: dayKey, updatedAt: stamp)
        guard var next = change(base) else { return .atLimit }
        guard !next.hasSameContent(as: base) else { return .unchanged }
        next.updatedAt = stamp
        return persist(next, keyData: keyData)
    }

    /// Seals `tally` as its day's row and refreshes the cache and token.
    private func persist(_ tally: BodyDayTally, keyData: Data) -> BodyTallyWriteResult {
        do {
            try repository.save(tally, key: SymmetricKey(data: keyData))
        } catch let error as BodyTallyRepositoryError {
            cache = nil
            switch error {
            case .storeFull: return fail(.storeFull)
            case .undecidedRows: return fail(.undecidedRows)
            case .invalidDayKey: return fail(.invalidDay)
            }
        } catch {
            cache = nil
            return fail(.storeError)
        }
        refreshCache(after: tally, keyData: keyData)
        lastWriteFailure = nil
        changeToken &+= 1
        return .saved
    }

    /// Folds a landed write into the cache (re-counting rows keylessly); drops the cache when the
    /// count cannot be read.
    private func refreshCache(after tally: BodyDayTally, keyData: Data) {
        guard var updated = cache, updated.keyData == keyData else { return }
        do {
            updated.rowCount = try repository.rowCount()
        } catch {
            cache = nil
            return
        }
        updated.tallies[tally.dayKey] = tally.isEmpty ? nil : tally
        cache = updated
    }

    /// Records a write that did not land — the observable ``lastWriteFailure`` and one audit line
    /// (the reason only, never a day or a count) — and returns it as a result.
    private func fail(_ reason: BodyTallyWriteFailure) -> BodyTallyWriteResult {
        lastWriteFailure = reason
        FernletAuditLog.log("bodyTally.write.failed", context: ["reason": "\(reason)"])
        return .failed(reason)
    }
}
