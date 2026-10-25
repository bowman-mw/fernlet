import FernletDomainModel
import FernletFoundation
import Foundation
import WorldMapStore

/// The store's side of the map widget (owner's Q36, `b4-new-map`, round 6b) and of its status plate.
///
/// - **What the picture draws** (``worldWidgetMapContent(in:now:)``): the homes and the hotel of a stay,
///   the kept places to eat and train, and the saved walk and run lines of the last
///   ``worldSavedLineDays`` days that cross the picture. Never a visit count, a day, a photo or Where
///   you've been, and nothing at all in a decoy.
/// - **When it changes** (``worldWidgetMapStamp()``): a stamp over those marked places and saved lines
///   wherever they are, so the writer redraws when one is added or removed, not when the person moves.
/// - **The plate's macro bars** (``widgetMacroTargets()``): the day's protein, carbs and fat targets,
///   benign numbers the snapshot carries beside the day's grams.
extension FernletStore {

    /// The day's macro targets in grams, for the widgets' protein, carbs and fat bars (as Home's plate).
    func widgetMacroTargets() -> WidgetSnapshot.MacroSummary {
        let targets = nutritionTargets
        return WidgetSnapshot.MacroSummary(protein: Double(max(targets.protein, 0)), carbs: Double(max(targets.carbs, 0)),
                                           fat: Double(max(targets.fat, 0)))
    }

    /// What the map widget's picture of `viewport` draws. Empty in a decoy.
    func worldWidgetMapContent(in viewport: MapViewport, now: Date = Date()) -> WorldWidgetMapContent {
        guard !duressSessionActive, viewport.isUsable else { return .empty }
        let homes = worldHomes.bases.filter { WorldWidgetMapContent.contains(viewport, $0.point) }
        let places = worldPlaceMarkers(near: nil).markers
            .filter { WorldWidgetMapContent.contains(viewport, $0.point) }
            .prefix(WorldWidgetMapContent.maxPlaces)
            .map { WorldMapMarker(id: $0.id, kind: $0.kind, name: "", point: $0.point) }
        return WorldWidgetMapContent(homes: homes, places: Array(places), trails: worldWidgetTrails(in: viewport, now: now))
    }

    /// The saved walk and run lines that cross `viewport`, newest first: the last ``worldSavedLineDays``
    /// days, at most ``worldSavedLineWalksPerDay`` a day (the blue button's own window), at most
    /// `WorldWidgetMapContent.maxTrails`. None in a decoy; DEBUG `trails` stands two in, display only.
    func worldWidgetTrails(in viewport: MapViewport, now: Date = Date()) -> [[GeoPoint]] {
        guard !duressSessionActive, viewport.isUsable else { return [] }
        let size = WorldWidgetMap.pictureSize
        if UITestSupport.worldHomeScenes.contains("trails") {
            return WorldWidgetMapContent.testTrails(around: viewport.center)
                .compactMap { WorldWidgetMapContent.drawable($0, in: viewport, size: size) }
        }
        var trails: [[GeoPoint]] = []
        for workoutID in worldWidgetSavedLineIDs(now: now) where trails.count < WorldWidgetMapContent.maxTrails {
            guard let line = worldRoute(for: workoutID)?.map(\.point),
                  let drawn = WorldWidgetMapContent.drawable(line, in: viewport, size: size) else { continue }
            trails.append(drawn)
        }
        return trails
    }

    /// A stamp over everything the picture could draw, wherever it is: the homes and hotel, the kept
    /// places and the saved lines' workouts. It moves when one is added, moved or removed. Zero in a decoy.
    func worldWidgetMapStamp(now: Date = Date()) -> Int {
        guard !duressSessionActive else { return 0 }
        var hasher = Hasher()
        for base in worldHomes.bases {
            hasher.combine(base.id)
            hasher.combine(base.kind)
            hasher.combine(base.point)
        }
        for marker in worldPlaceMarkers(near: nil).markers.prefix(WorldWidgetMapContent.maxPlaces * 4) {
            hasher.combine(marker.id)
            hasher.combine(marker.point)
        }
        // Which of those workouts still have a line: one listing of the vault's folder, no file opened.
        let stored: Set<UUID>
        do {
            stored = try worldRoutes.workoutIDs()
        } catch {
            stored = []
        }
        for workoutID in worldWidgetSavedLineIDs(now: now) where stored.contains(workoutID) {
            hasher.combine(workoutID)
        }
        if UITestSupport.worldHomeScenes.contains("trails") { hasher.combine("trails") }
        return hasher.finalize()
    }

    /// The walks' and runs' workout ids of the last ``worldSavedLineDays`` days, newest first, at most
    /// ``worldSavedLineWalksPerDay`` a day.
    private func worldWidgetSavedLineIDs(now: Date) -> [UUID] {
        var ids: [UUID] = []
        for offset in 0..<Self.worldSavedLineDays {
            guard let date = Calendar.current.date(byAdding: .day, value: -offset, to: now) else { continue }
            let key = FernletDate.dayKey(for: date)
            let outings = (key == todayKey ? day : loadDay(for: key)).workouts
                .filter { Self.savedLineKind(of: $0) != nil }
                .sorted { $0.completedAt > $1.completedAt }
                .prefix(Self.worldSavedLineWalksPerDay)
            ids += outings.map(\.id)
        }
        return ids
    }
}
