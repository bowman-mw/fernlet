import FernletFoundation
import FernletUI
import Foundation
import WorldMapStore

/// Opens the bundled country stamps (`WorldCountryStamps.json`, the design session's approved batches;
/// World-Exploration-Spec §3) for the passport's screens. A missing or refused file is logged and answers nil, so
/// the passport draws dashed spaces rather than wrong stamps; the countries themselves still count.
enum WorldCountryStampsLoader {
    /// The bundled file's resource name (a frozen file name).
    static let resource = "WorldCountryStamps"
    /// The bundled file's extension.
    static let fileExtension = "json"
    /// The face the passport draws stamp labels in: DM Sans Bold, the stamp book's label face. The design
    /// assumes Pixelify Sans, which Fernlet does not carry and never adds; `WorldCountryStampsTests` holds every
    /// label character to this face's glyphs, so a missing one fails rather than falling back silently.
    static let labelFontName = FernletFontName.dmSansBold

    /// The stamps bundled in `bundle`, or nil (logged).
    static func bundled(in bundle: Bundle = .main) -> WorldCountryStamps? {
        guard let url = bundle.url(forResource: resource, withExtension: fileExtension) else {
            FernletAuditLog.log("worldMap.countryStamps.fileMissing")
            return nil
        }
        do {
            return try WorldCountryStamps(data: Data(contentsOf: url))
        } catch {
            FernletAuditLog.log("worldMap.countryStamps.fileUnreadable")
            return nil
        }
    }
}
