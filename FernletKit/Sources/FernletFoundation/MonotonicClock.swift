// MonotonicClock.swift
// FernletFoundation
//
// A monotonic time source that KEEPS COUNTING while the device is asleep (`mach_continuous_time`),
// unlike `ProcessInfo.systemUptime` (which pauses in sleep). Needed for the multi-week store-ban
// clock: a ban must accrue real time even while the phone sleeps most of every night, or a 30-day
// ban would take far longer than 30 days to serve. Injectable so tests can drive elapsed time.

import Foundation

public protocol MonotonicClock: Sendable {
    /// Seconds since an arbitrary fixed point (device boot). Counts time spent asleep. Resets on reboot.
    var seconds: Double { get }
}

public struct SystemMonotonicClock: MonotonicClock {
    public init() {}
    public var seconds: Double {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let ticks = mach_continuous_time()
        return Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000.0
    }
}
