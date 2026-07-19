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

/// How a meal photo should render, given whether the meal claims a photo and whether that photo's bytes
/// are on THIS device. Multi-device day-split sync copies a day's data between devices but not the sealed
/// photo bytes, so a meal photographed on another device arrives here with a photo id but no bytes — this
/// distinguishes that ("on your other device") from a meal that simply has no photo, so the former reads
/// as a deliberate, gentle state rather than a broken frame.
enum MealPhotoPresence: Equatable {
    /// The meal carries no photo at all.
    case none
    /// The meal has a photo and its bytes are readable on this device.
    case onThisDevice
    /// The meal has a photo, but its bytes never synced to this device.
    case onOtherDevice

    /// - Parameter hasPhoto: the meal carries a photo id.
    /// - Parameter bytesAvailable: a sealed-store read for that photo returned bytes on THIS device.
    static func classify(hasPhoto: Bool, bytesAvailable: Bool) -> MealPhotoPresence {
        guard hasPhoto else { return .none }
        return bytesAvailable ? .onThisDevice : .onOtherDevice
    }
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
