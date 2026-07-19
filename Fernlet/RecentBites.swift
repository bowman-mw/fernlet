//
//  RecentBites.swift
//  Fernlet
//
//  The pure windowing behind Home's "Recent bites" polaroid strip (#11). Kept UI-free so the 7-day
//  window is unit-testable and reads no sealed photo bytes: the strip resolves which photographed meals
//  to show from already-loaded day rows, then the polaroids decode their JPEGs lazily as they scroll in.
//

import Foundation
import FernletDomainModel

/// One photographed meal to show in the "Recent bites" strip — just the fields the polaroid and its
/// tap-through viewer need. Carries the meal's `photoID` (non-nil by construction) rather than any bytes,
/// so building the list never touches the sealed `MealPhotoStore`.
struct RecentBite: Identifiable, Equatable {
    /// The meal's own id — stable across the strip and the presented viewer.
    let id: UUID
    let name: String
    /// When the meal was logged; drives both the newest-first order and the viewer's date line.
    let loggedAt: Date
    /// The day key this meal was logged under.
    let dateKey: String
    /// Non-nil by construction: only meals that carry a photo become bites.
    let photoID: UUID
}

enum RecentBites {
    /// The recent photographed meals for the strip: every meal that carries a photo across the given
    /// `days`, newest first, capped at `limit`. Pure over already-loaded day rows (it reads no photo
    /// bytes). An explicit `window` (in days, inclusive of `today`) keeps a stale row from sneaking past
    /// the recent horizon even if the caller hands over more days than it should.
    static func recent(
        from days: [FernletDay],
        today: Date,
        window: Int = 7,
        limit: Int = 6
    ) -> [RecentBite] {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: today)
        // `window` days INCLUSIVE of today → reach back window - 1 days.
        let cutoff = calendar.date(byAdding: .day, value: -(max(window, 1) - 1), to: startOfToday) ?? startOfToday

        return days
            .flatMap { day in
                day.meals.compactMap { meal -> RecentBite? in
                    guard let photoID = meal.photoID else { return nil }
                    return RecentBite(
                        id: meal.id, name: meal.name, loggedAt: meal.loggedAt,
                        dateKey: day.date, photoID: photoID)
                }
            }
            .filter { $0.loggedAt >= cutoff }
            .sorted { $0.loggedAt > $1.loggedAt }
            .prefix(limit)
            .map { $0 }
    }
}
