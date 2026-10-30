import FernletDomainModel
import FernletFoundation
import Foundation
import WorldMapStore

/// Home's saved lines (the approved `b1-home-bike` draws earlier walks' line in green; built in round 7,
/// owner 2026-10-29): the walks', runs' and bike rides' lines kept on this iPhone, read from the route
/// store under the blue button's own window.
///
/// - **Only while "Save new routes" is on**, and none in a decoy.
/// - **Gone when their file is**: Delete map history, Delete all stored routes, a wipe, deleting a workout
///   or Undo remove the file, and Home reads the lines again at its next front edge or note.
extension FernletStore {
    /// The saved walk, run and ride lines Home draws, newest first: the last ``worldSavedLineDays`` days, at
    /// most ``worldSavedLineWalksPerDay`` outings with a line a day. Empty while Save new routes is off or a
    /// decoy is open.
    func worldHomeSavedLines(now: Date = Date(), defaults: UserDefaults = .standard) -> [[GeoPoint]] {
        guard !duressSessionActive, WorldMapPreferences.saveNewRoutes(in: defaults) else { return [] }
        // Which workouts still have a line: one listing of the vault's folder, no file opened.
        let stored: Set<UUID>
        do {
            stored = try worldRoutes.workoutIDs()
        } catch {
            return []
        }
        guard !stored.isEmpty else { return [] }
        var lines: [[GeoPoint]] = []
        for offset in 0..<Self.worldSavedLineDays {
            guard let date = Calendar.current.date(byAdding: .day, value: -offset, to: now) else { continue }
            let key = FernletDate.dayKey(for: date)
            let outings = (key == todayKey ? day : loadDay(for: key)).workouts
                .filter { Self.drawsHomeLine($0) && stored.contains($0.id) }
                .sorted { $0.completedAt > $1.completedAt }
                .prefix(Self.worldSavedLineWalksPerDay)
            for outing in outings {
                guard let line = worldRoute(for: outing.id), line.count >= 2 else { continue }
                lines.append(line.map(\.point))
            }
        }
        return lines
    }

    /// Whether `workout`'s saved line shows on Home: a walk's, a run's (``savedLineKind(of:)``) or a bike
    /// ride's (an outdoor cycling workout; only a ride the map followed has a line).
    static func drawsHomeLine(_ workout: Workout) -> Bool {
        savedLineKind(of: workout) != nil || workout.activityType == .cycling
    }
}
