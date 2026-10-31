import FernletFoundation
import Foundation
import WorldMapStore

/// The bundled `WorldAirports.pack` (World-Airports-Spec §1), opened once on first use and kept: the flight gate
/// places readings in its grounds, and the Flighty import, the Flights page and Your world's arcs read its codes,
/// zones, points and names. With no pack (or an unreadable one) no reading is inside any airport's grounds, a
/// flight is still found by its speed alone, and an import names every code as unknown.
///
/// Owned by the ``WorldFlightKeeper`` (`store.worldLocation.flights.airportsShelf`); it holds public data only.
@MainActor
final class WorldAirportsShelf {
    private var opened: WorldAirports?
    private var tried = false

    /// The pack, opened on first use, or nil when it is missing or unreadable.
    func pack() -> WorldAirports? {
        guard !tried else { return opened }
        tried = true
        guard let url = Bundle.main.url(forResource: "WorldAirports", withExtension: "pack") else {
            FernletAuditLog.log("worldMap.airports.packMissing")
            return nil
        }
        do {
            opened = try WorldAirports(data: Data(contentsOf: url, options: .mappedIfSafe))
        } catch {
            FernletAuditLog.log("worldMap.airports.packUnreadable")
        }
        return opened
    }

    /// The grounds lookup: the pack, or none.
    func lookup() -> any AirportGroundsLookup {
        pack().map { $0 as any AirportGroundsLookup } ?? NoAirports()
    }

    /// The IATA code of the airport `token`, when the pack lists one.
    func iata(of token: String) -> String? {
        pack()?.airport(token: token)?.iata
    }
}
