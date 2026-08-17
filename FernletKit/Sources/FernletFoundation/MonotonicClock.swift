// MonotonicClock.swift
// FernletFoundation
//
// A monotonic time source that KEEPS COUNTING while the device is asleep (`mach_continuous_time`),
// unlike `ProcessInfo.systemUptime` (which pauses in sleep). Needed for the multi-week store-ban
// clock: a ban must accrue real time even while the phone sleeps most of every night, or a 30-day
// ban would take far longer than 30 days to serve. Injectable so tests can drive elapsed time.

import Foundation

/// A monotonic time source whose reading keeps advancing while the device is asleep.
///
/// The abstraction behind the multi-week moderation store-ban clock (`ModerationBanStore` in
/// ProximityKit): a ban must accrue real elapsed time even while the phone sleeps most of every
/// night, which rules out `ProcessInfo.systemUptime` (paused during sleep). Production code
/// injects ``SystemMonotonicClock``; tests inject fakes that drive ``seconds`` forward
/// deterministically. `Sendable` so a clock can be captured by long-lived stores without
/// isolation friction.
public protocol MonotonicClock: Sendable {
    /// Seconds since an arbitrary fixed point (device boot). Counts time spent asleep. Resets on reboot.
    var seconds: Double { get }
}

/// The production ``MonotonicClock``, backed by `mach_continuous_time`.
///
/// Converts continuous-time ticks to seconds via `mach_timebase_info`. The reading counts time
/// spent asleep but resets on reboot, so intervals measured against it survive overnight sleep
/// yet not a restart — callers needing reboot survival must persist an anchor alongside it.
public struct SystemMonotonicClock: MonotonicClock {
    /// Creates the system-backed clock; it holds no state of its own.
    public init() {}
    /// The current `mach_continuous_time` reading converted to seconds.
    ///
    /// R7: `mach_timebase_info`'s `kern_return_t` is checked rather than discarded. A failure (or a
    /// zero denominator) would otherwise divide by zero and hand every caller `+inf`/`NaN` — the
    /// multi-week store-ban clock reads this — so the recovery is the identity conversion, correct
    /// on every shipping Apple platform, where a tick already is a nanosecond.
    public var seconds: Double {
        let ticks = mach_continuous_time()
        var timebase = mach_timebase_info_data_t()
        guard mach_timebase_info(&timebase) == KERN_SUCCESS, timebase.denom != 0 else {
            return Double(ticks) / 1_000_000_000.0
        }
        return Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000.0
    }
}
