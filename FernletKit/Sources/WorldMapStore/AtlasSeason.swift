import Foundation

/// The season at a place on a day (idea A; a frozen token, so it stays English and never changes).
///
/// Meteorological seasons, whole months: in the north March to May is spring, June to August summer,
/// September to November autumn, December to February winter; south of the equator each is flipped (April is
/// autumn in Sydney). The equator itself counts as north.
///
/// **The tropics** (Fernlet's choice, 2026-10-29): within ``tropicsLatitude`` (23.44°, the tropics of Cancer
/// and Capricorn) the Sun passes overhead and the year turns on rain, not on four temperature seasons, so
/// ``hasFourSeasons(latitude:)`` is false there and the art should not paint four seasons. ``season(at:on:calendar:)``
/// still answers, by the same months, for anything that wants a label anyway.
public nonisolated enum AtlasSeason: String, CaseIterable, Codable, Sendable {
    case spring, summer, autumn, winter

    /// The tropics' edge: 23.44°, the Sun's greatest declination.
    public static let tropicsLatitude = 23.44

    /// The meteorological season at `latitude` on `date`, the month read in `calendar` (its time zone decides
    /// the day the month turns). A non-finite latitude counts as north.
    public static func season(at latitude: Double, on date: Date, calendar: Calendar) -> AtlasSeason {
        let month = calendar.component(.month, from: date)
        let northern: AtlasSeason
        switch month {
        case 3, 4, 5: northern = .spring
        case 6, 7, 8: northern = .summer
        case 9, 10, 11: northern = .autumn
        default: northern = .winter
        }
        guard latitude.isFinite, latitude < 0 else { return northern }
        return northern.opposite
    }

    /// Whether `latitude` has four seasons: false within the tropics (and for a non-finite latitude).
    public static func hasFourSeasons(latitude: Double) -> Bool {
        guard latitude.isFinite else { return false }
        return abs(latitude) >= tropicsLatitude
    }

    /// The season half a year away.
    public var opposite: AtlasSeason {
        switch self {
        case .spring: .autumn
        case .summer: .winter
        case .autumn: .spring
        case .winter: .summer
        }
    }
}
