import CryptoKit
import FernletFoundation
import Foundation

/// "Where you've been" on disk (World build step 5c; `b2-where-been`, owner's option A of 2026-10-24),
/// in two sealed files in the map's vault:
///
/// - **The log** (``PlaceLog``, `places.bin`): the 30-day timeline and Places you return to, sealed with the
///   **Private tab's hub key**, passed per call while Private is open, as the journal's entries are. The
///   vault never holds that key, so the log opens only inside Private, and a decoy, which never has it,
///   sees none of it. A log the current hub key can't open (the app lock was reset) is removed and starts
///   again empty: it is a rolling record, not a corpus anyone restores.
/// - **The device side** (``PlaceDeviceState``, `places-device.bin`): what was captured while Private was
///   closed (the stops and any new places' names), and the allowed places' points that background visits
///   are matched against, under the vault's after-first-unlock buffer key, because Always mode's visits
///   arrive with the phone locked. Folding moves the waiting stops under the hub key.
///
/// Both go with the vault: Delete everything, the silent wipe and the recovery lock remove the folder and
/// its keys together. Nothing here is synced, backed up, exported, shared, given to the AI or sent anywhere.
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

    // MARK: The device side

    /// The device side now (empty when there is none, or when its bytes can't be opened or read as one:
    /// they are removed). Throws when the file or the vault's key can't be read right now.
    public func deviceState() throws -> PlaceDeviceState {
        let file = WorldMapVault.File.placesDevice
        guard let data = try openedOrRemoved(file, read: { try self.vault.read(file) }) else { return .empty }
        do {
            return try decoder.decode(PlaceDeviceState.self, from: data)
        } catch {
            FernletAuditLog.log("worldMap.places.deviceUnreadable")
            vault.remove(file)
            return .empty
        }
    }

    /// `read`'s bytes, or nil when the file is absent or can never open (it is then removed). A key or file
    /// that can't be read right now throws.
    private func openedOrRemoved(_ file: WorldMapVault.File, read: () throws -> Data?) throws -> Data? {
        do {
            return try read()
        } catch WorldMapVault.VaultError.unopenable {
            FernletAuditLog.log("worldMap.places.unopenable", context: ["file": file.name])
            vault.remove(file)
            return nil
        }
    }

    /// Seals `state` as the device side.
    public func saveDeviceState(_ state: PlaceDeviceState) throws {
        try vault.write(try encoder.encode(state), to: WorldMapVault.File.placesDevice)
    }

    // MARK: The log, under the hub key

    /// The log sealed with `hubKey` (empty when there is none, or when it can't be opened with this key:
    /// it is removed).
    public func log(hubKey: SymmetricKey) throws -> PlaceLog {
        let file = WorldMapVault.File.places
        guard let data = try openedOrRemoved(file, read: { try self.vault.read(file, sealedWith: hubKey) }) else { return .empty }
        do {
            let log = try decoder.decode(PlaceLog.self, from: data)
            guard log.schemaVersion == PlaceLog.currentSchema else { throw WorldMapVault.VaultError.unopenable }
            return log
        } catch {
            FernletAuditLog.log("worldMap.places.logUnreadable")
            vault.remove(file)
            return .empty
        }
    }

    /// Seals `log` with `hubKey`.
    public func saveLog(_ log: PlaceLog, hubKey: SymmetricKey) throws {
        try vault.write(try encoder.encode(log), to: WorldMapVault.File.places, sealedWith: hubKey)
    }

    /// Folds the device side into the log at `now` and returns the log: the log is written first, then the
    /// waiting stops are cleared, so a fold cut short between the two adds nothing twice (each stop is
    /// added once, by id).
    public func fold(hubKey: SymmetricKey, now: Date, calendar: Calendar = .current) throws -> PlaceLog {
        let device = try deviceState()
        let current = try log(hubKey: hubKey)
        let next = current.folding(device, now: now, calendar: calendar)
        if next != current { try saveLog(next, hubKey: hubKey) }
        if !device.pending.isEmpty || !device.newPlaces.isEmpty { try saveDeviceState(device.folded) }
        return next
    }

    /// Deletes the day that starts at `day`: its stops, their visits off each place's count (a place left
    /// with none goes, and is forgotten for matching). The walks' and runs' workout ids that day, so their
    /// saved lines can go too.
    public func deleteDay(_ day: Date, hubKey: SymmetricKey, now: Date, calendar: Calendar = .current) throws -> [UUID] {
        let current = try fold(hubKey: hubKey, now: now, calendar: calendar)
        let result = current.deletingDay(day, calendar: calendar)
        try saveLog(result.log, hubKey: hubKey)
        try saveDeviceState(try deviceState().forgetting(result.removedPlaces))
        return result.workoutIDs
    }

    /// Renames place `id` to `name`.
    public func rename(_ id: UUID, to name: String, hubKey: SymmetricKey, now: Date) throws -> PlaceLog {
        let current = try fold(hubKey: hubKey, now: now)
        let next = current.renaming(id, to: name)
        if next != current { try saveLog(next, hubKey: hubKey) }
        return next
    }

    /// Deletes all of it: the log and the device side ("Delete all of it"). Keyless. Whether both are gone.
    public func deleteAll() -> Bool {
        let log = vault.remove(WorldMapVault.File.places)
        let device = vault.remove(WorldMapVault.File.placesDevice)
        return log && device
    }
}
