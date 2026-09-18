// MeshContinuationProgress.swift
// Fernlet
//
// Network migration P8 item 4 (plan §14), the arithmetic half: what the continued-processing task's
// `Progress` reads, and the two sentences beside it.
//
// **Why the unit is elapsed session time.** §14 is blunt about it — "progress must advance
// monotonically or the system kills the task" — so the unit is elapsed session time toward the
// ceiling's budget, which is monotonic by construction. This value ratchets on top of that with
// `max(previous, computed)`, so even a source that goes backwards (a resumed clock, a re-read
// ceiling, a hand-fed test) cannot make the bar retreat. Two independent guarantees, because the
// consequence of losing the property is the system killing the mesh.
//
// **Plain scalars, no ProximityKit symbol.** `MeshSessionCeiling`'s `hardDeadline` and
// `monotonicBudgetSeconds` are internal to the package today (only `ceilingSeconds` is public); the
// widenings belong to items 5/6. This file takes `TimeInterval`s and an `Int`, computes nothing
// about the mesh, and imports nothing but Foundation — which also makes it free to test.
//
// **The bar never reaches the total**, exactly as `NetworkMeshFeasibilityProbe.updateBackgroundTask`
// clamps to `total - 1`: a `Progress` that completes is a task that has finished, and this one has
// not. The ceiling's own expiry ends it, not the bar.
//
// **Copy is display, the states are tokens.** `BGContinuedProcessingTaskRequest` takes `String`s,
// but a `String` in THIS value would opt the two sentences out of localization forever with a clean
// build. So ``MeshContinuationCopy`` carries `LocalizedStringResource`s and item 6 renders them with
// `String(localized:)` at the request site — the app target IS `Bundle.main`, so no `bundle:`
// argument applies (the `SessionResumeCopy` rule). Two catalog keys, owed to the close-out's sync:
// `Fernlet mesh` and `%lld friends connected`.
//
// **The count key owes a plural rule at that sync.** A `%lld` in a default is not a plural rule — it
// is one string with a number in it, and English is already wrong at one friend. `xcstringstool sync`
// harvests the key but will never INVENT the block, so the sync must hand-author `one`/`other` for
// `%lld friends connected` AND add it to `LocalizationBoundaryTests.pluralRuledKeys`, which reads the
// committed catalog and is the only thing that would ever notice. The row cannot be added before the
// sync: with the key absent from `App/Fernlet/Localizable.xcstrings` the wall is red, not green.

import Foundation

// MARK: - MeshContinuationProgress

/// The continued-processing task's progress, as a ratcheted fraction of the session ceiling.
///
/// Immutable and clamped at construction: ``fraction`` is always finite and in `0 ... 1`, so
/// ``completedUnitCount`` converts without a trap on any input, including a NaN budget.
nonisolated struct MeshContinuationProgress: Equatable, Sendable {

    /// The scale the task's `Progress` is reported on — the probe's 100.
    static let totalUnitCount: Int64 = 100

    /// No progress at all: where a task starts, and where a missing or unusable budget leaves it.
    static let zero = MeshContinuationProgress(fraction: 0)

    /// How far through the session ceiling this reading is — finite, `0 ... 1`.
    let fraction: Double

    /// The fraction on ``totalUnitCount``'s scale, capped one short of the total.
    ///
    /// The cap is the probe's: a `Progress` that reaches its total says the work is done, and a mesh
    /// that is still running has not finished. The system ends the task; the bar never claims to.
    var completedUnitCount: Int64 {
        min(Int64(fraction * Double(Self.totalUnitCount)), Self.totalUnitCount - 1)
    }

    /// Builds a reading, clamping anything out of range rather than trusting its caller.
    ///
    /// - Parameter fraction: The raw fraction. A non-finite value reads as `0`, and anything outside
    ///   `0 ... 1` is clamped into it, so no arithmetic downstream can trap.
    init(fraction: Double) {
        guard fraction.isFinite else {
            self.fraction = 0
            return
        }
        self.fraction = min(max(fraction, 0), 1)
    }

    /// The next reading, which is never lower than the last.
    ///
    /// - Parameters:
    ///   - previous: The last reading handed to the system, or nil for the first.
    ///   - elapsed: Monotonic seconds since the session started.
    ///   - budget: The session ceiling's budget in seconds. A budget of zero or less — or a
    ///     non-finite one, or a non-finite `elapsed` — yields no NEW progress rather than a
    ///     division by zero: the previous reading stands, and a first reading is ``zero``.
    /// - Returns: The ratcheted reading.
    static func advancing(
        from previous: MeshContinuationProgress?,
        elapsed: TimeInterval,
        budget: TimeInterval
    ) -> MeshContinuationProgress {
        let floor = previous ?? .zero
        guard budget > 0, budget.isFinite, elapsed.isFinite else { return floor }
        return MeshContinuationProgress(fraction: max(floor.fraction, elapsed / budget))
    }
}

// MARK: - MeshContinuationCopy

/// The two sentences on the continued-processing task's card.
///
/// Display text, never tokens: both are `LocalizedStringResource`, so the catalog sync harvests them
/// and item 6 renders them with `String(localized:)` where `BGContinuedProcessingTaskRequest` needs
/// `String`s. A `String` here would be English forever with a clean build, which is the localization
/// wall's failure mode (A).
nonisolated struct MeshContinuationCopy: Equatable, Sendable {

    /// The card's title — the app's name for what is running, not a status.
    let title: LocalizedStringResource

    /// The card's subtitle: how many friends are connected.
    let subtitle: LocalizedStringResource

    /// The card for a friend count.
    ///
    /// - Parameter friendCount: How many friends the mesh is connected to, EXCLUDING self. Item 6
    ///   passes the branch's external present fingerprints — committed, active slots. That is branch
    ///   PRESENCE, which is a smaller and honester claim than §14's "fresh authenticated heartbeats":
    ///   the session has one `lastExternalHeartbeatAt` for the whole mesh, not one per member, so
    ///   per-member freshness is not a fact anything can report today. A negative count reads as
    ///   zero rather than rendering a negative sentence.
    /// - Returns: The title and subtitle, unrendered.
    static func card(friendCount: Int) -> MeshContinuationCopy {
        let count = max(friendCount, 0)
        return MeshContinuationCopy(
            title: LocalizedStringResource("Fernlet mesh"),
            subtitle: LocalizedStringResource("\(count) friends connected")
        )
    }
}
