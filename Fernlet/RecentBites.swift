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

/// How a meal photo should render, given whether the meal claims a photo, whether a sealed file for it
/// exists on THIS device, and whether that file could actually be opened. Multi-device day-split sync
/// copies a day's data between devices but not the sealed photo bytes, so a meal photographed on another
/// device arrives here with a photo id but no file at all ("on your other device"). A file that IS here
/// but won't open (corrupt seal, decrypt failure) is a different, local problem — surfaced as a gentle
/// "unavailable" state — and must NOT be mislabelled as living on another device.
enum MealPhotoPresence: Equatable {
    /// The meal carries no photo at all.
    case none
    /// The meal has a photo and its bytes are readable on this device.
    case onThisDevice
    /// The meal has a photo, but no sealed file for it exists on this device (never synced here).
    case onOtherDevice
    /// A sealed file IS on this device but couldn't be opened (corrupt / undecryptable) — it's here and
    /// broken, not elsewhere.
    case unavailable

    /// - Parameter hasPhoto: the meal carries a photo id.
    /// - Parameter sealedFileExists: a sealed file for that photo is present on THIS device (existence
    ///   only — says nothing about whether it can be decrypted).
    /// - Parameter bytesAvailable: a sealed-store read for that photo returned openable bytes on THIS
    ///   device.
    static func classify(hasPhoto: Bool, sealedFileExists: Bool, bytesAvailable: Bool) -> MealPhotoPresence {
        guard hasPhoto else { return .none }
        if bytesAvailable { return .onThisDevice }
        // No openable bytes: a file that's present but unreadable is broken-here; no file means the
        // photo lives on the device it was taken on.
        return sealedFileExists ? .unavailable : .onOtherDevice
    }
}

enum RecentBites {
    /// The recent photographed meals for the strip: every meal that carries a photo across the given
    /// `days`, newest first, capped at `limit`. Pure over already-loaded day rows (it reads no photo
    /// bytes). An explicit `window` (in days, inclusive of `today`) keeps a stale row from sneaking past
    /// the recent horizon even if the caller hands over more days than it should.
    ///
    /// Repeat day keys collapse to their FIRST row, because the caller assembles `days` from two sources
    /// that can briefly name the same day: today's live in-memory row first, then the prior days it
    /// fetched. Across local midnight (day T → T+1) the fetch can re-run before the store has advanced
    /// off T, and asking the store for T while T is still its "today" hands back that same in-memory row —
    /// so T arrives twice. Without collapsing, T's photographed meals would each yield two bites sharing
    /// one `id` and the strip's `ForEach` would see duplicate ids. First-wins is also the fresher row:
    /// the caller's leading entry is the live one, any later copy a snapshot.
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

        var seenDayKeys = Set<String>()
        return days
            .filter { seenDayKeys.insert($0.date).inserted }
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
