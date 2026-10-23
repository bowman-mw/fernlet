import Foundation

/// Gold hearts: a heart a friend gives **in person** shows as a gold heart after the six on the World
/// Home's status bar, and lifts the companion while it lasts (World build, branch `world-ui`; design
/// page "A World for Fernlet" answers 7 and 12, owner's answers of 2026-10-23).
///
/// The rules, in one place so the status bar, the companion and the widget agree:
/// - only hearts given in person count (the mesh and presence paths); a dead-drop heart picked up
///   later does not;
/// - each lasts ``lifetime`` (12 hours) from when it arrived;
/// - at most ``maxActive`` (2) at a time, the newest;
/// - each adds ``boostPerHeart`` (one half heart of six, 1/12) to the live care score, capped at a
///   full score.
///
/// **The saved day score is never boosted.** The boost is applied only where the live score is shown
/// (`FernletStore.liveCareScore`); the day rows `DiaryStore` keeps are computed on their own path and
/// never read it, so a friend's visit can't rewrite anyone's history.
public nonisolated enum GoldHeartRules {
    /// How long one gold heart lasts.
    public static let lifetime: TimeInterval = 12 * 60 * 60
    /// The most gold hearts shown, and counted, at once.
    public static let maxActive = 2
    /// What one gold heart adds to the live care score: one half heart of the status bar's six.
    public static let boostPerHeart = 1.0 / 12

    /// The arrival times of the hearts that are gold at `date`, newest first: given in person, under
    /// ``lifetime`` old, at most ``maxActive``. An arrival in the future (the clock moved back) counts
    /// as just arrived, as `HeartGlowMath` reads it.
    public static func activeArrivals(_ inPersonArrivals: [Date], at date: Date) -> [Date] {
        let live = inPersonArrivals.filter { max(0, date.timeIntervalSince($0)) < lifetime }
        return Array(live.sorted(by: >).prefix(maxActive))
    }

    /// When the gold glow ends: the latest expiry among the hearts gold at `date`, or nil when none
    /// is. The companion's "loved" feeling lasts until then.
    public static func glowEnds(_ inPersonArrivals: [Date], at date: Date) -> Date? {
        activeArrivals(inPersonArrivals, at: date).first.map { min($0, date).addingTimeInterval(lifetime) }
    }

    /// `score` lifted by `goldHearts` gold hearts, clamped to 0...1. A non-finite score reads as 0.
    public static func boosted(score: Double, goldHearts: Int) -> Double {
        guard score.isFinite else { return 0 }
        let hearts = min(max(goldHearts, 0), maxActive)
        return min(1, max(0, score + Double(hearts) * boostPerHeart))
    }
}
