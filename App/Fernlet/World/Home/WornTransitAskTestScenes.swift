import Foundation
import WorldMapStore

/// DEBUG screenshots of the transit question and the worn way sheet (`FERNLET_UI_TEST_WORLD_HOME` scenes
/// `transitAsk` and `transitSheet`), display only: nothing is written, and the scene list is empty in release builds.
@MainActor
enum WornTransitAskTestScenes {
    /// Whether Home stages "Was that a train?".
    static var asks: Bool { UITestSupport.worldHomeScenes.contains("transitAsk") }
    /// Whether Home opens a staged train path's sheet.
    static var opensSheet: Bool { UITestSupport.worldHomeScenes.contains("transitSheet") }

    /// A train ride that ended ten minutes ago, unsure.
    static func question(now: Date = Date()) -> WornTransitQuestion? {
        WornTransitQuestion(WornTrip(kind: .rail, confirmed: false, day: WornDay.number(for: now),
                                     start: now.addingTimeInterval(-1_800), end: now.addingTimeInterval(-600), line: []))
    }

    /// The staged train path under `here`.
    static func key(around here: GeoPoint) -> WornWayKey {
        WornWayKey(cell: MercatorHexGrid.cell(containing: here), kind: .rail)
    }

    /// Twelve trips, the last three days ago, and four kept rides (three by train, one by road); changes do nothing.
    static func book(now: Date = Date()) -> WornWayBook {
        let today = WornDay.number(for: now)
        let rides: [WornTrip] = [3, 5, 9, 12].enumerated().map { index, daysAgo in
            let start = now.addingTimeInterval(-Double(daysAgo) * 86_400 - 3_600)
            return WornTrip(kind: index == 2 ? .road : .rail, confirmed: index == 0, day: today &- UInt16(daysAgo),
                            start: start, end: start.addingTimeInterval(1_500), line: [])
        }
        return WornWayBook(tally: { _ in WornTally(count: 12, lastDay: today &- 3) }, trips: { _ in rides },
                           changeTrip: { _, _ in }, forgetTrip: { _ in }, forgetPath: { _, _ in })
    }
}
