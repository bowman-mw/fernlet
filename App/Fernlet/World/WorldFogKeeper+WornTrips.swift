import Foundation
import WorldMapStore

/// The kept trips' actions the map's sheet and Home's question call (ferry and train build, owner 2026-11-15, C1 and
/// C2). The detection lane fills these in; until then they do nothing.
extension WorldFogKeeper {
    /// The kept trips whose way passes through `cell`, newest first (the tap-a-path sheet).
    func trips(through cell: HexCell) -> [WornTrip] {
        []
    }

    /// Changes trip `id` to `kind`, moving its passes in the counter to the new kind, and marks it confirmed.
    func changeTrip(_ id: UUID, to kind: WornWayKind) {}

    /// Forgets trip `id`: its record goes and its passes come out of the counter.
    func forgetTrip(_ id: UUID) {}

    /// Forgets every kept trip of `kind` through `cell` ("Forget this path").
    func forgetPath(through cell: HexCell, kind: WornWayKind) {}

    /// Answers Home's question about ``transitQuestion``: a kind, or nil for "Not sure" (kept as guessed, not asked
    /// again).
    func answerTransitQuestion(_ kind: WornWayKind?) {}
}
