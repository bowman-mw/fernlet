import Foundation
import WorldMapStore

/// Home's quiet-place card's one read of the World map (owner's P1-A, 2026-11-27): CAP-2's named exception.
///
/// Home is not behind the lock, so it never reads Where you've been. It reads only the small summary the
/// fold under the hub key writes for it (`PlaceVisitSummary`, under the map vault's buffer key), through
/// `PlaceVisitSummaryReader`, the one type `AmbientRemindersSealedBoundaryTests` allows: per place, the
/// person's own name or Fernlet's kind token, the last-visit day and a 60-day count. Never Apple's name,
/// a point, a reference, the timeline or the hub key. Nothing is read in a decoy.
extension FernletStore {
    /// The quiet-place finder's view of Home's place summary; none in a decoy.
    func ambientQuietPlaces() -> [AmbientQuietPlace] {
        guard !duressSessionActive else { return [] }
        let summary = PlaceVisitSummaryReader(vault: worldMapVault).read()
        return summary.entries.prefix(AmbientQuietPlaceFinder.maxPlaces).map { entry in
            AmbientQuietPlace(id: entry.id, label: entry.label, kind: entry.kind.map(Self.ambientPlaceKind),
                              lastVisitDay: entry.lastVisitDay, visits: entry.visits60)
        }
    }

    /// The card's kind word for Fernlet's kind token.
    nonisolated static func ambientPlaceKind(_ category: PlaceCategory) -> AmbientPlaceKind {
        switch category {
        case .foodAndDrink: .restaurant
        case .gym: .gym
        case .park: .park
        case .beach: .beach
        case .campground: .campground
        }
    }
}
