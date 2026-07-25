import Foundation
import FernletDomainModel

/// The daily AI-call budget (Ladder §3.2). A device-local, NON-SYNCED counter with day-key rollover.
///
/// CRITICAL PRIVACY CONSTRAINT: `aiStatus` lives in `FernletSettings` — the SYNCED blob — but the
/// derived `.sleepy` / `.resting` states must NEVER be written back into synced settings, or device
/// A's usage would silently throttle device B. This type is therefore a pure value the *caller*
/// stores device-locally (`AICallQuotaStore`); it is never a `FernletSettings` field, never a
/// `FernletSnapshot` field, and never touches the sealed stores or CloudKit. The effective status is
/// computed as an overlay (`AIStatusOverlay`) — stored user intent stays as-is; the derived state is
/// `f(stored intent, local counter)`.
public struct AICallQuota: Sendable, Equatable {
    /// The day this counter is for, as a `yyyy-MM-dd` key in the current calendar.
    public var dayKey: String
    /// Calls made on `dayKey`.
    public var count: Int

    public init(dayKey: String, count: Int) {
        self.dayKey = dayKey
        self.count = count
    }

    /// An empty counter anchored to today.
    public init(now: Date = Date(), calendar: Calendar = .current) {
        self.dayKey = AICallQuota.dayKey(for: now, calendar: calendar)
        self.count = 0
    }

    /// `.sleepy` is entered at this many calls in a day (non-essential work falls back).
    public static let sleepyThreshold = 30
    /// `.resting` is entered at this many calls in a day (all work falls back).
    public static let restingThreshold = 60

    public static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// The count that is actually in effect at `now`: a counter left over from a previous day has
    /// rolled over to zero (we do not carry a stale day's tally into today).
    public func effectiveCount(now: Date = Date(), calendar: Calendar = .current) -> Int {
        dayKey == AICallQuota.dayKey(for: now, calendar: calendar) ? count : 0
    }

    /// Returns a new quota with one call recorded, rolling the day over first if `now` is a new day.
    public func recordingCall(now: Date = Date(), calendar: Calendar = .current) -> AICallQuota {
        let today = AICallQuota.dayKey(for: now, calendar: calendar)
        if today == dayKey {
            return AICallQuota(dayKey: today, count: count + 1)
        }
        return AICallQuota(dayKey: today, count: 1)
    }

    /// The quota-derived AI status at `now` — the *rate* component of the effective status. Never
    /// `.off` (that is user intent, applied by `AIStatusOverlay`).
    public func derivedStatus(now: Date = Date(), calendar: Calendar = .current) -> AIStatus {
        let n = effectiveCount(now: now, calendar: calendar)
        if n >= AICallQuota.restingThreshold { return .resting }
        if n >= AICallQuota.sleepyThreshold { return .sleepy }
        return .ready
    }
}

/// Combines stored user intent (`FernletSettings.aiStatus`, synced) with the device-local counter
/// into the *effective* status. Off stays off; anything the user left enabled is overlaid with the
/// rate-derived `.sleepy` / `.resting` state. This is the read side the settings label uses instead
/// of the raw stored value.
public enum AIStatusOverlay {
    public static func effectiveStatus(
        intent: AIStatus,
        quota: AICallQuota,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> AIStatus {
        // `.off` is user intent and is never overridden by usage. Any enabled intent (`.ready`, or a
        // future build's `.sleepy`/`.resting` stored token) defers to the live rate derivation.
        guard intent != .off else { return .off }
        return quota.derivedStatus(now: now, calendar: calendar)
    }
}

/// The injectable seam for the device-local counter. Declared here so `AIProviders` can consume the
/// quota ONLY through this protocol — the concrete `UserDefaults`-backed store lives in the app and
/// is never nameable from the walled module. Keeps the counter out of `FernletSnapshot` / sealed
/// stores / CloudKit by construction.
public protocol AICallQuotaStore: Sendable {
    /// The current on-disk quota (may be for a previous day; read through `AICallQuota.effectiveCount`).
    func currentQuota() -> AICallQuota
    /// Record one AI call (rolls the day over as needed) and return the updated quota.
    @discardableResult func recordCall() -> AICallQuota
    /// Reset the counter (e.g. delete-all-data). Device-local only.
    func reset()
}
