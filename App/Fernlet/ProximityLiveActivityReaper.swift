// ProximityLiveActivityReaper.swift — Fernlet (app target only)
//
// The once-per-launch reaper of proximity-connection Live Activities a killed previous process
// stranded, and the attributes type it enumerates. Both lived in ProximityKit's foreground anchor
// until plan step A0.6 (Docs/Plan-FernletCoach-ProximityKit-2026-10-01.md §4, Mac readiness) moved
// them here unchanged in behaviour: the same attributes, name and stored shape, the same ended
// content, stale date, enumeration and dismissal, called at the same moment of launch. ProximityKit
// builds for native macOS, where no ActivityKit type is available, and only this app ever requested
// one of these activities. Only the launching process reaps, so this file lives in the Fernlet folder
// and is deliberately NOT in the widget's dual-membership set (`LiveActivityStarter.swift`'s
// precedent): no widget renders a proximity activity.

import ActivityKit
import Foundation

/// ActivityKit attributes for the proximity-connection Live Activity.
///
/// **Nothing requests one of these any more** (P9 item 5). The type is kept for exactly one
/// reader — ``ProximityLiveActivityReaper``, whose enumeration
/// `Activity<ProximityConnectionActivityAttributes>.activities` is spelled in terms of it, so
/// deleting the struct deletes the reaper. No widget declares an `ActivityConfiguration` for it,
/// which is why no request could ever render.
///
/// **Do not change its stored shape.** ActivityKit decodes an activity a previous process
/// stranded against this declaration; a renamed or re-typed property makes such an activity
/// unreapable rather than merely unrendered. Shipping a proximity widget later means ADDING a
/// configuration, not editing these fields.
///
/// ActivityKit matches attributes by unqualified type name, as `WorkoutActivityAttributes`' dual
/// membership shows (one declaration compiled into the app, which requests, and the widget, which
/// renders); this declaration is how the app reaps an activity one of its earlier builds requested
/// under ProximityKit's identical type, which lived there until plan step A0.6.
/// `FernletFeatureGoldenTests` pins its unqualified name and its stored shape.
struct ProximityConnectionActivityAttributes: ActivityAttributes {
    /// The mutable half of the Live Activity: running byte counters and a status word. Only the
    /// reaper writes one now, and only ever `"Ended"`.
    struct ContentState: Codable, Hashable {
        var bytesSent: Int
        var bytesReceived: Int
        var status: String
    }

    var peerName: String
    var startedAt: Date
}

/// Ends every proximity-connection Live Activity left system-side by a PREVIOUS process.
///
/// **Since P9 item 5 nothing in this app requests one**, so this reaper cannot find an activity
/// THIS build created. It is kept deliberately, for two reasons. (1) A build installed before the
/// retirement could in principle have stranded one: the requester held its `Activity` in a private
/// property, the only code that ended it was that same anchor's `stop()`, and a process kill while
/// a session was live left nothing holding a handle — so it lingered until ActivityKit's own
/// maximum-lifetime auto-end (hours), spending a per-app Live Activity slot a later
/// workout/cooking `Activity.request` needs. (2) It is the cheap, already-correct half of shipping
/// a proximity widget later: the reap side exists, so only the configuration and the request would
/// be new. It costs one enumeration of an empty list per launch.
///
/// Call `endOrphans()` ONCE per launch, from the composition root, BEFORE any proximity manager can
/// start a coordinator — never on scene activation, where it would end the activities of anchors
/// still live in this process. The workout/cooking kinds have their own relaunch reapers
/// (`LiveActivityStarter`); this one touches only the proximity kind.
///
/// The app's since plan step A0.6, and internal: ``FernletStoreLoader`` is its one caller. The app
/// target compiles its `end(_:dismissalPolicy:)` call as it compiles the same loop in
/// `LiveActivityReflector.end`, with no transfer local; in ProximityKit's Swift 6 mode the call
/// needed a `nonisolated(unsafe)` local and a Power-of-10 allowlist entry, and both are gone.
@MainActor
enum ProximityLiveActivityReaper {
    /// Ends every stranded proximity activity with `.immediate` dismissal. Bounded by the OS
    /// per-app Live Activity cap (R2); a no-op — no awaits — when there is nothing to reap.
    static func endOrphans() async {
        let content = ActivityContent(
            state: ProximityConnectionActivityAttributes.ContentState(bytesSent: 0, bytesReceived: 0, status: "Ended"),
            staleDate: nil
        )
        for orphan in Activity<ProximityConnectionActivityAttributes>.activities {
            await orphan.end(content, dismissalPolicy: .immediate)
        }
    }
}
