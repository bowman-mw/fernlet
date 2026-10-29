import FernletFoundation
import Foundation
import WorldMapStore

/// What "Remember this place" keeps on this iPhone beside the places file (World build round 7,
/// owner-approved 2026-10-26: `ref-tag-how`, `ref-tag-named`): the quiet "don't ask here" spots the person
/// said "Not here" to, and the places they remembered themselves, so the button never asks at either again
/// and a remembered restaurant or gym gets its map icon at once.
///
/// Only the person's own choices: a point for each "Not here"; for a remembered place its id in Where
/// you've been, Fernlet's point, Apple's reference when it has one, the icon its kind earned when they
/// remembered it, and their own name only when they changed Apple's (the MapKit terms: an unchanged name is
/// asked for again by the reference). Never Apple's name, never a refused place's.
///
/// Frozen at rest: `quiet` and `kept` are field names.
nonisolated struct WorldPlaceMarks: Codable, Equatable, Sendable {
    /// The most "Not here" spots kept; the oldest goes past it.
    static let maxQuiet = 200
    /// The most remembered places kept (Where you've been's own cap).
    static let maxKept = PlaceLog.maxPlaces
    /// How near a "Not here" spot keeps the button from asking, in metres (the button's own reach,
    /// ``WorldPlacesKeeper/rememberReach``).
    static let quietRadius = 50.0
    /// How near a remembered place counts as being there, in metres (a known place's match radius).
    static let keptRadius = PlaceDeviceState.matchRadius
    /// Nothing marked.
    static let empty = WorldPlaceMarks(quiet: [], kept: [])

    /// The "Not here" spots, oldest first.
    var quiet: [GeoPoint]
    /// The places the person remembered themselves, oldest first.
    var kept: [WorldKeptPlace]

    /// Whether a "Not here" spot is within ``quietRadius`` of `point`.
    func isQuiet(near point: GeoPoint) -> Bool {
        quiet.contains { $0.distance(to: point) <= Self.quietRadius }
    }

    /// Whether a remembered place is within ``keptRadius`` of `point`.
    func isKept(near point: GeoPoint) -> Bool {
        kept.contains { $0.point.distance(to: point) <= Self.keptRadius }
    }

    /// These marks with `point` as a "Not here" spot (the oldest dropped past ``maxQuiet``).
    func addingQuiet(_ point: GeoPoint) -> WorldPlaceMarks {
        guard point.isValid, !isQuiet(near: point) else { return self }
        var next = self
        next.quiet.append(point)
        if next.quiet.count > Self.maxQuiet { next.quiet.removeFirst(next.quiet.count - Self.maxQuiet) }
        return next
    }

    /// These marks with `place` remembered (in place of an older mark with its id; the oldest dropped past
    /// ``maxKept``).
    func keeping(_ place: WorldKeptPlace) -> WorldPlaceMarks {
        guard place.point.isValid else { return self }
        var next = self
        next.kept.removeAll { $0.id == place.id }
        next.kept.append(place)
        if next.kept.count > Self.maxKept { next.kept.removeFirst(next.kept.count - Self.maxKept) }
        return next
    }

    /// These marks without the remembered places `ids` (deleted from Where you've been, W-14): their icons
    /// go, and the button may ask there again.
    func forgetting(_ ids: Set<UUID>) -> WorldPlaceMarks {
        var next = self
        next.kept.removeAll { ids.contains($0.id) }
        return next
    }

    /// These marks with the remembered place `id` given the person's own name (a rename in Where you've
    /// been); an empty name changes nothing.
    func renaming(_ id: UUID, to name: String) -> WorldPlaceMarks {
        guard let label = PlaceRecord.validLabel(name), let index = kept.firstIndex(where: { $0.id == id }) else { return self }
        var next = self
        next.kept[index].label = label
        return next
    }
}

/// A place the person remembered with "Remember this place" (round 7): its id in Where you've been, where
/// it is, Apple's reference when it has one, the icon a restaurant or gym gets on the map at once, and the
/// person's own name only when they changed Apple's.
///
/// Frozen at rest: the field names and ``Icon``'s raw values.
nonisolated struct WorldKeptPlace: Codable, Equatable, Identifiable, Sendable {
    /// The map icon a remembered place gets at once (`ref-tag-named` → `ref-places-map`).
    enum Icon: String, Codable, Sendable {
        /// A place to eat: the bowl.
        case eat
        /// A gym: the dumbbell.
        case gym

        /// The icon a place of `category` gets, or nil (parks, beaches, campgrounds, a place of no kind).
        static func of(_ category: PlaceCategory?) -> Icon? {
            switch category {
            case .foodAndDrink: .eat
            case .gym: .gym
            case .park, .beach, .campground, nil: nil
            }
        }
    }

    let id: UUID
    let point: GeoPoint
    /// Apple's reference to the place, or nil (a spot Apple has no name for, or one Fernlet won't name).
    let placeID: String?
    let icon: Icon?
    /// The person's own name, only when they changed Apple's (or gave a spot with none).
    var label: String?
}

/// Seals ``WorldPlaceMarks`` in the map's vault (``WorldMapVault/File/placeMarks``: the device side's
/// purpose and buffer key, its own context), read afresh on every use so nothing outlives a wipe. Every
/// wipe and Delete map history remove it with the vault; "Delete all of it" and the app-lock reset remove
/// it with Where you've been. A decoy never reads or writes it (the keeper's gate).
@MainActor
final class WorldPlaceMarksStore {
    private let vault: WorldMapVault

    /// A store over `vault`.
    init(vault: WorldMapVault) {
        self.vault = vault
    }

    /// The marks, empty when none were ever written (or the file can't be opened any more, when it is
    /// removed); nil when they can't be read right now (the phone locked before its first unlock).
    func read() -> WorldPlaceMarks? {
        let file = WorldMapVault.File.placeMarks
        let data: Data?
        do {
            data = try vault.read(file)
        } catch WorldMapVault.VaultError.unopenable {
            vault.remove(file)
            return .empty
        } catch {
            FernletAuditLog.log("worldMap.placeMarks.readDeferred")
            return nil
        }
        guard let data else { return .empty }
        do {
            return try JSONDecoder().decode(WorldPlaceMarks.self, from: data)
        } catch {
            FernletAuditLog.log("worldMap.placeMarks.unreadable")
            vault.remove(file)
            return .empty
        }
    }

    /// Seals `marks`. Whether they were written.
    @discardableResult
    func save(_ marks: WorldPlaceMarks) -> Bool {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try vault.write(try encoder.encode(marks), to: WorldMapVault.File.placeMarks)
            return true
        } catch {
            FernletAuditLog.log("worldMap.placeMarks.saveFailed")
            return false
        }
    }

    /// Removes every mark. Keyless. Whether the file is gone.
    @discardableResult
    func removeAll() -> Bool {
        vault.remove(WorldMapVault.File.placeMarks)
    }
}
