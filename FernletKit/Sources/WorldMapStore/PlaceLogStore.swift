import CryptoKit
import FernletFoundation
import Foundation

/// "Where you've been" on disk (World build step 5c; `b2-where-been`, owner's option A of 2026-10-24),
/// in two sealed files in the map's vault:
///
/// - **The log** (``PlaceLog``, `places.bin`): the 30-day timeline and Places you return to, sealed with the
///   **Private tab's hub key**, passed per call while Private is open, as the journal's entries are. The
///   vault never holds that key, so the log opens only inside Private, and a decoy, which never has it,
///   sees none of it. A log the current hub key can't open (the app lock was reset, whose screen says it
///   deletes Where you've been) is removed with the device side's waiting captures, and starts again
///   empty: it is a rolling record, not a corpus anyone restores.
/// - **The device side** (``PlaceDeviceState``, `places-device.bin`): what was captured while Private was
///   closed (the stops and any new places' points and references), and the allowed places' points that
///   background visits are matched against, under the vault's after-first-unlock buffer key, because Always
///   mode's visits arrive with the phone locked. Folding moves the waiting stops under the hub key.
///
/// What either file keeps of a place is Fernlet's own point, the lookup's reference to it, the person's
/// own name for it and the visits (World build round 5, the MapKit terms): never the lookup's name or kind.
/// Round 6 adds, on the device side only: the homes and hotel the person marked (their name and pin), and
/// the places they eat out at (the reference, their name, the point and the meals logged there; no dates).
/// "Delete all of it" keeps the homes and hotel, which go in Settings › Home map, with the map history, in
/// every wipe and with an app-lock reset.
/// A file from the first format, which held those, is read with them dropped and sealed again at once.
///
/// Both go with the vault: Delete everything, the silent wipe and the recovery lock remove the folder and
/// its keys together. Nothing here is synced, backed up, exported, shared, given to the AI or sent anywhere.
///
/// **Home's summary** (owner's P1-A, 2026-11-27; ``PlaceVisitSummary``, `places-summary.bin`, the buffer key):
/// each fold also counts the visits it adds into a small summary Home's quiet-place card reads with
/// Private closed (``PlaceVisitSummaryReader``): the person's own name or Fernlet's kind token, the
/// last-visit day and a 60-day count per place. The one exception to "never its kind": the summary keeps
/// Fernlet's own five-word kind token (a place to eat, or the kind the name lookup reported while Private
/// was open), never Apple's name, point or reference. Deleting a place, a day or a stop forgets those
/// places in it; "Delete all of it", the app-lock reset and every wipe remove it.
@MainActor
public final class PlaceLogStore {
    private let vault: WorldMapVault
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// A store over `vault`.
    public init(vault: WorldMapVault) {
        self.vault = vault
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
    }

    /// A sealed file as it was found.
    private enum Found {
        /// Its opened bytes.
        case bytes(Data)
        /// No such file.
        case absent
        /// It could never open with the key given, and was removed.
        case removed
    }

    // MARK: The device side

    /// The device side now (empty when there is none, or when its bytes can't be opened or read as one:
    /// they are removed). A first-format state is sealed again in the current one before it is returned.
    /// Throws when the file or the vault's key can't be read right now.
    public func deviceState() throws -> PlaceDeviceState {
        let file = WorldMapVault.File.placesDevice
        guard case .bytes(let data) = try found(file, read: { try self.vault.read(file) }) else { return .empty }
        let state: PlaceDeviceState
        do {
            state = try decoder.decode(PlaceDeviceState.self, from: data)
        } catch {
            FernletAuditLog.log("worldMap.places.deviceUnreadable")
            vault.remove(file)
            return .empty
        }
        guard state.needsMigration else { return state }
        let migrated = PlaceDeviceState(known: state.known, pending: state.pending, newPlaces: state.newPlaces,
                                        homes: state.homes, restaurants: state.restaurants)
        try saveDeviceState(migrated)
        FernletAuditLog.log("worldMap.places.deviceMigrated")
        return migrated
    }

    /// `read`'s bytes, absent, or removed when the file can never open. A key or file that can't be read
    /// right now throws.
    private func found(_ file: WorldMapVault.File, read: () throws -> Data?) throws -> Found {
        do {
            return try read().map(Found.bytes) ?? .absent
        } catch WorldMapVault.VaultError.unopenable {
            FernletAuditLog.log("worldMap.places.unopenable", context: ["file": file.name])
            vault.remove(file)
            return .removed
        }
    }

    /// Seals `state` as the device side.
    public func saveDeviceState(_ state: PlaceDeviceState) throws {
        try vault.write(try encoder.encode(state), to: WorldMapVault.File.placesDevice)
    }

    // MARK: The log, under the hub key

    /// The log sealed with `hubKey` (empty when there is none, or when it can't be opened with this key:
    /// it is removed). A log in an older format is sealed again in the current one first.
    public func log(hubKey: SymmetricKey) throws -> PlaceLog {
        try reading(hubKey: hubKey).log
    }

    /// The log sealed with `hubKey`, and whether a log was there that this key could never open (the key
    /// changed: the app lock was reset).
    private func reading(hubKey: SymmetricKey) throws -> (log: PlaceLog, keyChanged: Bool) {
        let file = WorldMapVault.File.places
        switch try found(file, read: { try self.vault.read(file, sealedWith: hubKey) }) {
        case .absent: return (.empty, false)
        case .removed: return (.empty, true)
        case .bytes(let data): return (try decodedLog(data, hubKey: hubKey), false)
        }
    }

    /// `data` read as a log, migrated to the current format (and sealed again) when it is an older one, or
    /// empty when it reads as none (it is removed).
    private func decodedLog(_ data: Data, hubKey: SymmetricKey) throws -> PlaceLog {
        let log: PlaceLog
        do {
            log = try decoder.decode(PlaceLog.self, from: data)
        } catch {
            FernletAuditLog.log("worldMap.places.logUnreadable")
            vault.remove(WorldMapVault.File.places)
            return .empty
        }
        guard (PlaceLog.oldestReadableSchema...PlaceLog.currentSchema).contains(log.schemaVersion) else {
            FernletAuditLog.log("worldMap.places.logUnreadable")
            vault.remove(WorldMapVault.File.places)
            return .empty
        }
        guard log.schemaVersion != PlaceLog.currentSchema else { return log }
        let migrated = log.migrated
        try saveLog(migrated, hubKey: hubKey)
        FernletAuditLog.log("worldMap.places.logMigrated")
        return migrated
    }

    /// Seals `log` with `hubKey`.
    public func saveLog(_ log: PlaceLog, hubKey: SymmetricKey) throws {
        try vault.write(try encoder.encode(log), to: WorldMapVault.File.places, sealedWith: hubKey)
    }

    /// Folds the device side into the log at `now` and returns the log: the log is written first, then the
    /// waiting stops are cleared, so a fold cut short between the two adds nothing twice (each stop is
    /// added once, by id). When the hub key could not open the log (the app lock was reset), the device
    /// side goes too, so nothing captured before the reset joins the new, empty log.
    public func fold(hubKey: SymmetricKey, now: Date, calendar: Calendar = .current) throws -> PlaceLog {
        let current = try reading(hubKey: hubKey)
        if current.keyChanged {
            vault.remove(WorldMapVault.File.placesDevice)
            vault.remove(WorldMapVault.File.placeSummary)
            FernletAuditLog.log("worldMap.places.resetCleared")
            return .empty
        }
        let device = try deviceState()
        let next = current.log.folding(device, now: now, calendar: calendar)
        if next != current.log { try saveLog(next, hubKey: hubKey) }
        updateVisitSummary(before: current.log, after: next, eating: device.eatingPlaces, now: now, calendar: calendar)
        if device.waitsForFold { try saveDeviceState(device.folded) }
        return next
    }

    // MARK: Home's summary (P1-A)

    /// Counts the visits `after` holds that `before` did not into Home's summary (every visit in `after`
    /// when no summary was written yet), and brings its names in line. Written after the log, so a fold
    /// cut short counts nothing twice (the next fold sees those stops as already in the log). A failure is
    /// audited and never fails the fold: the summary is Home's convenience, not a record.
    private func updateVisitSummary(before: PlaceLog, after: PlaceLog, eating: [EatingPlace], now: Date, calendar: Calendar) {
        do {
            let stored = try visitSummary()
            let counted = stored == nil ? Set<UUID>() : Set(before.stops.map(\.id))
            let visits = after.stops.filter { $0.kind == .visit && !counted.contains($0.id) }
            let next = (stored ?? .empty).folding(newVisits: visits, log: after, eating: eating, now: now, calendar: calendar)
            if next != stored { try saveVisitSummary(next) }
        } catch {
            FernletAuditLog.log("worldMap.places.summaryUnsaved")
        }
    }

    /// Home's summary as stored, or nil when none was written yet (or it could never open, or reads as
    /// none: it is removed and written again).
    func visitSummary() throws -> PlaceVisitSummary? {
        let file = WorldMapVault.File.placeSummary
        guard case .bytes(let data) = try found(file, read: { try self.vault.read(file) }) else { return nil }
        do {
            let summary = try decoder.decode(PlaceVisitSummary.self, from: data)
            return summary.schemaVersion == PlaceVisitSummary.currentSchema ? summary : nil
        } catch {
            FernletAuditLog.log("worldMap.places.summaryUnreadable")
            vault.remove(file)
            return nil
        }
    }

    /// Seals `summary` as Home's summary.
    func saveVisitSummary(_ summary: PlaceVisitSummary) throws {
        try vault.write(try encoder.encode(summary), to: WorldMapVault.File.placeSummary)
    }

    /// Notes Fernlet's kind token for place `id` in Home's summary, from the kind the app's name lookup
    /// reported while Private was open. Nothing when the place has no entry; a failure is audited.
    public func notePlaceKind(_ kind: PlaceCategory, for id: UUID) {
        do {
            guard let stored = try visitSummary() else { return }
            let next = stored.notingKind(kind, for: id)
            if next != stored { try saveVisitSummary(next) }
        } catch {
            FernletAuditLog.log("worldMap.places.summaryKindUnsaved")
        }
    }

    /// Forgets places `ids` in Home's summary (the person deleted the place, or one of its visits): a
    /// place comes back only with its next visit. A summary that can't be read or written now is removed.
    public func forgetInVisitSummary(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        do {
            guard let stored = try visitSummary() else { return }
            let next = stored.forgetting(ids)
            if next != stored { try saveVisitSummary(next) }
        } catch {
            FernletAuditLog.log("worldMap.places.summaryForgetFailed")
            vault.remove(WorldMapVault.File.placeSummary)
        }
    }

    /// Deletes the day that starts at `day`: its stops, their visits off each place's count (a place left
    /// with none goes, and is forgotten for matching). The walks' and runs' workout ids that day, so their
    /// saved lines can go too.
    public func deleteDay(_ day: Date, hubKey: SymmetricKey, now: Date, calendar: Calendar = .current) throws -> [UUID] {
        let current = try fold(hubKey: hubKey, now: now, calendar: calendar)
        let result = current.deletingDay(day, calendar: calendar)
        try saveLog(result.log, hubKey: hubKey)
        try saveDeviceState(try deviceState().forgetting(result.removedPlaces))
        let visited = current.stops(on: day, calendar: calendar).filter { $0.kind == .visit }.compactMap(\.placeID)
        forgetInVisitSummary(Set(visited).union(result.removedPlaces))
        return result.workoutIDs
    }

    /// Gives place `id` the person's own name `name`.
    public func rename(_ id: UUID, to name: String, hubKey: SymmetricKey, now: Date) throws -> PlaceLog {
        let current = try fold(hubKey: hubKey, now: now)
        let next = current.renaming(id, to: name)
        if next != current {
            try saveLog(next, hubKey: hubKey)
            // Home's summary takes the person's name at once (no visit is counted: both logs hold the same stops).
            updateVisitSummary(before: next, after: next, eating: [], now: now, calendar: .current)
        }
        return next
    }

    /// Deletes all of it ("Delete all of it"): the log and Home's summary (keyless), and of the device side everything but the
    /// homes and hotel, which stay until they are removed in Settings › Home map (the approved policy
    /// sentence; round 6). A device side that can't be read now goes whole. Whether it all went.
    public func deleteAll() -> Bool {
        let log = vault.remove(WorldMapVault.File.places)
        let summary = vault.remove(WorldMapVault.File.placeSummary)
        let homes: HomeBook?
        do {
            homes = try deviceState().homes
        } catch {
            homes = nil
        }
        let device = vault.remove(WorldMapVault.File.placesDevice)
        guard let homes, homes != .empty else { return log && device && summary }
        do {
            try saveDeviceState(PlaceDeviceState.empty.withHomes(homes))
        } catch {
            FernletAuditLog.log("worldMap.places.homesNotKept")
        }
        return log && device && summary
    }

    // MARK: Homes and hotels, places to eat (round 6)

    /// Reads the device side, applies `change` and seals it when it changed; the state after the change.
    /// Throws when the device side or its key can't be read or written right now.
    @discardableResult
    public func updateDeviceState(_ change: (PlaceDeviceState) -> PlaceDeviceState) throws -> PlaceDeviceState {
        let state = try deviceState()
        let next = change(state)
        if next != state { try saveDeviceState(next) }
        return next
    }

    /// Removes both files whole (and Home's summary), the homes and hotel with them: the app-lock reset, whose screen says it
    /// deletes the places you've been. Keyless. Whether both are gone.
    public func deleteEverything() -> Bool {
        let log = vault.remove(WorldMapVault.File.places)
        let device = vault.remove(WorldMapVault.File.placesDevice)
        let summary = vault.remove(WorldMapVault.File.placeSummary)
        return log && device && summary
    }
}
