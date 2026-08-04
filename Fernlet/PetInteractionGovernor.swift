//
//  PetInteractionGovernor.swift
//  Fernlet
//
//  Gentle anti-compulsion pacing for the tap-to-pet interaction (the Quabble pattern):
//  petting stays warm and playful for a handful of pets, then the companion is simply
//  *content* for a little while. Everything is framed positively — the companion
//  settles into the affection; nothing is ever "locked", "limited", or "too much".
//

import Foundation

/// Small pure-ish state machine deciding how the companion responds to each pet.
///
/// Rules:
/// - Pets are counted inside a rolling window. Going quiet for longer than the window
///   starts a fresh count (casual petting throughout the day never accumulates).
/// - The `petsPerWindow`-th pet produces one **settling** response — the companion is
///   visibly content — and begins a ~10-minute settled period.
/// - Pets during the settled period produce a small **calm idle** acknowledgement
///   (no bounce, no new thought); a soft "nice and settled" line may show exactly once
///   per settled period.
/// - When the settled period ends, the window re-arms and petting is playful again.
///
/// State lives in device-local `UserDefaults` (injectable for tests, along with the
/// clock) — deliberately NOT in `FernletSettings`: how often someone pets the companion
/// on this phone is not wellbeing data and should never sync between devices.
final class PetInteractionGovernor {
    /// How the companion responds to a single pet.
    enum Response: Equatable {
        /// The normal playful pet response (bounce + occasional passing thought).
        case bounce
        /// The final pet of the window: one content, settled response — the companion
        /// soaks it in and then rests in that feeling for a while.
        case settling
        /// A pet while settled: a small calm acknowledgement — no bounce, no new
        /// thought. `showsSettledLine` is true exactly once per settled period so the
        /// soft "nice and settled" line never repeats.
        case calmIdle(showsSettledLine: Bool)
    }

    /// Pets counted within one rolling window before the companion settles.
    let petsPerWindow: Int
    /// The rolling window pets are counted in.
    let window: TimeInterval
    /// How long the companion stays settled after the final pet.
    let settleDuration: TimeInterval

    private let defaults: UserDefaults
    private let now: () -> Date

    init(
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init,
        petsPerWindow: Int = 5,
        window: TimeInterval = 10 * 60,
        settleDuration: TimeInterval = 10 * 60
    ) {
        self.defaults = defaults
        self.now = now
        self.petsPerWindow = petsPerWindow
        self.window = window
        self.settleDuration = settleDuration
    }

    // MARK: - Device-local persistence keys (never synced)

    /// The `UserDefaults` keys the governor persists its window/settle state under.
    ///
    /// Device-local only (never in `FernletSettings`, never synced); note `settledUntil` keeps
    /// its historical "cooldownUntil" raw key so existing installs don't lose an in-flight settle.
    private enum Key {
        static let petCount = "fernlet.companionPets.count"
        static let windowStart = "fernlet.companionPets.windowStart"
        static let settledUntil = "fernlet.companionPets.cooldownUntil"
        /// The settled period (its end timestamp) whose soft line has already shown,
        /// so the line appears at most once per settle — even across relaunches.
        static let settledLineShownFor = "fernlet.companionPets.settledLineShownFor"
    }

    /// Whether the companion is currently resting in its settled/content period.
    var isSettled: Bool {
        guard let until = date(forKey: Key.settledUntil) else { return false }
        return now() < until
    }

    /// Records one pet and returns how the companion should respond.
    func registerPet() -> Response {
        let now = self.now()

        if let until = date(forKey: Key.settledUntil), now < until {
            let marker = until.timeIntervalSinceReferenceDate
            let alreadyShown = defaults.double(forKey: Key.settledLineShownFor) == marker
            if !alreadyShown {
                defaults.set(marker, forKey: Key.settledLineShownFor)
            }
            return .calmIdle(showsSettledLine: !alreadyShown)
        }

        var count = defaults.integer(forKey: Key.petCount)
        var windowStart = date(forKey: Key.windowStart)

        // Start a fresh window on the first-ever pet, when the previous window aged
        // out, or right after a settled period ended (the re-arm).
        let windowAgedOut = windowStart.map { now.timeIntervalSince($0) > window } ?? true
        let settleJustEnded = date(forKey: Key.settledUntil) != nil
        if windowAgedOut || settleJustEnded {
            count = 0
            windowStart = now
            defaults.removeObject(forKey: Key.settledUntil)
            defaults.removeObject(forKey: Key.settledLineShownFor)
        }

        count += 1
        defaults.set(count, forKey: Key.petCount)
        if let windowStart { set(windowStart, forKey: Key.windowStart) }

        if count >= petsPerWindow {
            set(now.addingTimeInterval(settleDuration), forKey: Key.settledUntil)
            return .settling
        }
        return .bounce
    }

    /// Clears all governor state. Used by the DEBUG UX-appearance seed hook so test
    /// runs never start with the companion already settled from a previous run.
    static func clearPersistentState(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: Key.petCount)
        defaults.removeObject(forKey: Key.windowStart)
        defaults.removeObject(forKey: Key.settledUntil)
        defaults.removeObject(forKey: Key.settledLineShownFor)
    }

    // MARK: - Date <-> defaults plumbing

    private func date(forKey key: String) -> Date? {
        let stored = defaults.double(forKey: key)
        guard stored != 0 else { return nil }
        return Date(timeIntervalSinceReferenceDate: stored)
    }

    private func set(_ date: Date, forKey key: String) {
        defaults.set(date.timeIntervalSinceReferenceDate, forKey: key)
    }
}
