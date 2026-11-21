import Foundation

/// The tracker diary's lines in words (drafts for the owner, 2026-11-21). The diary's file holds frozen tokens;
/// these are their display strings, and a token this build does not know reads as "Something else".
nonisolated enum TrackerDiaryCopy {
    /// A line's words.
    static func title(_ event: WorldDiaryEvent) -> LocalizedStringResource {
        switch event.kind {
        case .fenceExit:
            LocalizedStringResource("trackerDiary.fenceExit", defaultValue: "Woke: you left the circle Fernlet was watching", comment: "Tracker diary (Settings, Home map): one line of what background mapping did")
        case .fenceArmed:
            LocalizedStringResource("trackerDiary.fenceArmed", defaultValue: "Watching a circle of \(event.value) m for you to leave", comment: "Tracker diary (Settings, Home map): one line of what background mapping did")
        case .listenStarted: listenStarted(WorldListenReason(rawValue: event.detail))
        case .listenEnded: listenEnded(WorldListenEnd(rawValue: event.detail))
        case .traceStarted: traceStarted(event.detail)
        case .traceEnded: traceEnded(event.detail)
        case .readings:
            LocalizedStringResource("trackerDiary.readings", defaultValue: "Location readings this minute: \(event.counts.reduce(0, +))", comment: "Tracker diary (Settings, Home map): one line of what background mapping did")
        case .mode: mode(event.detail)
        case .motion: motion(WorldMotionKind(rawValue: event.detail))
        case .walkNotSeen: walkNotSeen(WorldWalkBlocker(rawValue: event.detail))
        }
    }

    /// A minute's readings by accuracy, or the readings of a listen that followed no walk; nil for any other line.
    static func detail(_ event: WorldDiaryEvent) -> LocalizedStringResource? {
        if event.kind == .walkNotSeen, event.counts.count == 2 {
            return LocalizedStringResource(
                "trackerDiary.walkNotSeen.detail",
                defaultValue: "Good readings: \(event.counts[0]) · too rough to use: \(event.counts[1])",
                comment: "Tracker diary: how many of a check's location readings were good enough to count, and how many were not")
        }
        guard event.kind == .readings, event.counts.count == WorldDiaryLog.bucketLimits.count + 1 else { return nil }
        let counts = event.counts
        return LocalizedStringResource(
            "trackerDiary.readings.detail",
            defaultValue: "Within 10 m: \(counts[0]) · within 30 m: \(counts[1]) · within 65 m: \(counts[2]) · rougher: \(counts[3])",
            comment: "Tracker diary: how many of a minute's location readings were how accurate")
    }

    static let other = LocalizedStringResource("trackerDiary.other", defaultValue: "Something else",
                                               comment: "Tracker diary: a line this version of Fernlet has no words for")

    private static func listenStarted(_ reason: WorldListenReason?) -> LocalizedStringResource {
        switch reason {
        case .fenceExit: LocalizedStringResource("trackerDiary.listen.fenceExit", defaultValue: "Started checking: you left the circle", comment: "Tracker diary (Settings, Home map): one line of what background mapping did")
        case .carLinked: LocalizedStringResource("trackerDiary.listen.carLinked", defaultValue: "Started checking: a car connected", comment: "Tracker diary (Settings, Home map): one line of what background mapping did")
        case .hint: LocalizedStringResource("trackerDiary.listen.hint", defaultValue: "Started checking: Driving Focus or Start a drive", comment: "Tracker diary (Settings, Home map): one line of what background mapping did")
        case .fastReading: LocalizedStringResource("trackerDiary.listen.fastReading", defaultValue: "Started checking: a reading faster than walking", comment: "Tracker diary (Settings, Home map): one line of what background mapping did")
        case .leftFront: LocalizedStringResource("trackerDiary.listen.leftFront", defaultValue: "Started checking: you closed Fernlet while moving", comment: "Tracker diary (Settings, Home map): one line of what background mapping did")
        case .visitDeparture: LocalizedStringResource("trackerDiary.listen.visitDeparture", defaultValue: "Started checking: you left a place you stopped at", comment: "Tracker diary (Settings, Home map): one line of what background mapping did")
        case nil: other
        }
    }

    private static func listenEnded(_ end: WorldListenEnd?) -> LocalizedStringResource {
        switch end {
        case .timeUp: LocalizedStringResource("trackerDiary.listenEnd.timeUp", defaultValue: "Stopped checking: nothing found", comment: "Tracker diary (Settings, Home map): one line of what background mapping did")
        case .traceTookOver: LocalizedStringResource("trackerDiary.listenEnd.traceTookOver", defaultValue: "Stopped checking: found something to follow", comment: "Tracker diary (Settings, Home map): one line of what background mapping did")
        case .passengerDriving: LocalizedStringResource("trackerDiary.listenEnd.passenger", defaultValue: "Stopped checking: a road trip friend's iPhone maps this drive", comment: "Tracker diary (Settings, Home map): one line of what background mapping did")
        case .mappingOff: LocalizedStringResource("trackerDiary.listenEnd.mappingOff", defaultValue: "Stopped checking: background mapping went off", comment: "Tracker diary (Settings, Home map): one line of what background mapping did")
        case nil: other
        }
    }

    private static func walkNotSeen(_ blocker: WorldWalkBlocker?) -> LocalizedStringResource {
        switch blocker {
        case .motionSaysRide: LocalizedStringResource("trackerDiary.walkNotSeen.motionSaysRide", defaultValue: "No walk followed: Motion said vehicle or bike", comment: "Tracker diary (Settings, Home map): one line of what background mapping did")
        case .noRun: LocalizedStringResource("trackerDiary.walkNotSeen.noRun", defaultValue: "No walk followed: no good reading at walking pace", comment: "Tracker diary (Settings, Home map): one line of what background mapping did")
        case .tooShort: LocalizedStringResource("trackerDiary.walkNotSeen.tooShort", defaultValue: "No walk followed: under 45 seconds at walking pace", comment: "Tracker diary (Settings, Home map): one line of what background mapping did")
        case .notFar: LocalizedStringResource("trackerDiary.walkNotSeen.notFar", defaultValue: "No walk followed: the readings didn't go far enough", comment: "Tracker diary (Settings, Home map): one line of what background mapping did")
        case .tooSlow: LocalizedStringResource("trackerDiary.walkNotSeen.tooSlow", defaultValue: "No walk followed: slower than a walk", comment: "Tracker diary (Settings, Home map): one line of what background mapping did")
        case .tooFast: LocalizedStringResource("trackerDiary.walkNotSeen.tooFast", defaultValue: "No walk followed: faster than a walk", comment: "Tracker diary (Settings, Home map): one line of what background mapping did")
        case .motionUnsure: LocalizedStringResource("trackerDiary.walkNotSeen.motionUnsure", defaultValue: "No walk followed: Motion didn't say walking, and the readings alone weren't sure", comment: "Tracker diary (Settings, Home map): one line of what background mapping did")
        case nil: other
        }
    }

    private static func traceStarted(_ token: String) -> LocalizedStringResource {
        switch token {
        case WorldTrackerDiary.token(for: .drive): LocalizedStringResource("trackerDiary.trace.drive", defaultValue: "Started following a drive", comment: "Tracker diary (Settings, Home map): one line of what background mapping did")
        case WorldTrackerDiary.token(for: .ride): LocalizedStringResource("trackerDiary.trace.ride", defaultValue: "Started following a bike ride", comment: "Tracker diary (Settings, Home map): one line of what background mapping did")
        case WorldTrackerDiary.token(for: .walk): LocalizedStringResource("trackerDiary.trace.walk", defaultValue: "Started following a walk", comment: "Tracker diary (Settings, Home map): one line of what background mapping did")
        default: other
        }
    }

    private static func traceEnded(_ token: String) -> LocalizedStringResource {
        switch token {
        case WorldTrackerDiary.token(for: .drive): LocalizedStringResource("trackerDiary.traceEnd.drive", defaultValue: "Stopped following the drive", comment: "Tracker diary (Settings, Home map): one line of what background mapping did")
        case WorldTrackerDiary.token(for: .ride): LocalizedStringResource("trackerDiary.traceEnd.ride", defaultValue: "Stopped following the bike ride", comment: "Tracker diary (Settings, Home map): one line of what background mapping did")
        case WorldTrackerDiary.token(for: .walk): LocalizedStringResource("trackerDiary.traceEnd.walk", defaultValue: "Stopped following the walk", comment: "Tracker diary (Settings, Home map): one line of what background mapping did")
        default: other
        }
    }

    private static func mode(_ token: String) -> LocalizedStringResource {
        switch token {
        case "onFoot": LocalizedStringResource("trackerDiary.mode.onFoot", defaultValue: "Now on foot", comment: "Tracker diary (Settings, Home map): one line of what background mapping did")
        case "driving": LocalizedStringResource("trackerDiary.mode.driving", defaultValue: "Now in a car, bus or train", comment: "Tracker diary (Settings, Home map): one line of what background mapping did")
        case "cycling": LocalizedStringResource("trackerDiary.mode.cycling", defaultValue: "Now on a bike", comment: "Tracker diary (Settings, Home map): one line of what background mapping did")
        default: other
        }
    }

    private static func motion(_ kind: WorldMotionKind?) -> LocalizedStringResource {
        switch kind {
        case .stationary: LocalizedStringResource("trackerDiary.motion.stationary", defaultValue: "Motion: still", comment: "Tracker diary (Settings, Home map): one line of what background mapping did")
        case .walking: LocalizedStringResource("trackerDiary.motion.walking", defaultValue: "Motion: walking", comment: "Tracker diary (Settings, Home map): one line of what background mapping did")
        case .running: LocalizedStringResource("trackerDiary.motion.running", defaultValue: "Motion: running", comment: "Tracker diary (Settings, Home map): one line of what background mapping did")
        case .cycling: LocalizedStringResource("trackerDiary.motion.cycling", defaultValue: "Motion: cycling", comment: "Tracker diary (Settings, Home map): one line of what background mapping did")
        case .automotive: LocalizedStringResource("trackerDiary.motion.automotive", defaultValue: "Motion: in a vehicle", comment: "Tracker diary (Settings, Home map): one line of what background mapping did")
        case .unknown: LocalizedStringResource("trackerDiary.motion.unknown", defaultValue: "Motion: can't tell", comment: "Tracker diary (Settings, Home map): one line of what background mapping did")
        case nil: other
        }
    }
}
