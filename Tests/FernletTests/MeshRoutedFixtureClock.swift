// MeshRoutedFixtureClock.swift
// FernletTests
//
// Network migration P5 item 6a: the ONE rolling instant every routed fixture anchors to.
//
// The routed rigs used to inherit `MeshMergeWire.start`'s pinned `MeshP3Acceptance.base` (1.8e9 =
// 2027-01-15T08:00:00Z) as their mesh's `createdAt`. The manifest verifier pins the two together —
// `MeshRoutedManifestVerifier.structuralRejection` demands
// `floored(expiresAt) == expiry(afterHardDeadline: hardDeadline)` exactly — so every routed fixture
// manifest expired at `base + ceiling + grace` = **2027-01-15T14:20:00Z**, and from the first
// wall-clock instant after that date every settle-driven routed cell would have started refusing
// `.itemExpired`. That is the fixed-date fixture rot this repo has paid for before; the remedy is
// the same one: anchor to the injected clock, not to a literal.
//
// Three properties make this safe, and all three are load-bearing:
//
// - **The anchor stays AHEAD of the wall clock, never behind it.** Every routed fixture instant is
//   `anchor + offset`, while the settle path takes the shipping default `now: Date = Date()`. Today
//   `MeshP3Acceptance.base` sits ~4 months in the future, so the whole family was written and proved
//   against "injected instants lead the real clock". Rolling the anchor *behind* the wall clock
//   instead flips that regime, and it is not a theoretical worry: it was measured, and it fails
//   seven custody/hand-off cells. So the roll is `now + margin`, which keeps the relationship the
//   fixtures already hold.
// - **`max(base, …)`, so nothing moves today.** `base` is still in the future, so the anchor is
//   bit-for-bit the value it replaces and NO fixture, digest or golden moves. It stays exactly
//   `base` until `Date() + aheadMarginSeconds` first exceeds it — **2026-12-16T08:00:00Z**, one
//   whole margin BEFORE the pinned instant, not when the wall clock reaches it — and tracks the
//   wall clock from that crossover on.
// - **`static let`, never a computed `var`.** Swift evaluates it once per process, so a cell that
//   replays twice in one process (`MeshP5DeterminismAcceptanceTests.oneRoutedCellReplaysIdentically`)
//   sees one instant, and the mesh route and the manifest route cannot disagree within a run. The
//   margin is a month rather than minutes for the same reason: a run that outlived the margin would
//   change regime halfway through.
//
// The `Date()` below is why this lives in its own file: `MeshP4DeterminismAcceptanceTests` and
// `MeshP5DeterminismAcceptanceTests` grep-ban that token in `MeshConvergenceSchedule.swift`,
// `MeshConvergencePropertyTests.swift` and `MeshRoutedDrainConvergenceTests.swift`. Those files may
// reference this symbol; they may not spell the clock themselves, and neither wall is relaxed.
//
// **And this file is walled too, so the indirection is not a loophole.** It is on
// `MeshP5DeterminismAcceptanceTests.scannedFiles` with exactly ONE named single-line exception —
// the `createdAt` initialiser below, matched by its whole code line — so a *second* clock read
// here fails that wall rather than passing silently. The three properties above are not left to
// this comment either: `theRoutedFixtureAnchorHoldsItsContract` pins the `max` floor, the forward
// roll and the one-instant-per-process rule as assertions.

import Foundation

// MARK: - MeshRoutedFixtureClock

/// The rolling creation instant every routed rig's mesh — and therefore every routed manifest,
/// chunk and receipt derived from it — is anchored to.
///
/// Use it wherever a routed fixture needs "when this mesh was made": `MeshRoutedDrainRig.createdAt`,
/// `MeshConvergenceRun.anchor` on a routed run, and `MeshRoutedPipeline.mintInstant`. P4's
/// membership-only fixtures deliberately keep `MeshP3Acceptance.base` — nothing about their claims
/// is expiry-bearing, and moving them would churn cells this item has no business touching.
@MainActor
enum MeshRoutedFixtureClock {

    /// How far AHEAD of the process's own "now" the rolled anchor sits.
    ///
    /// A month, not minutes: the value is fixed once per process, and the invariant it preserves is
    /// "every injected fixture instant leads the wall clock the settle path reads". A margin shorter
    /// than a run could be overtaken mid-suite, which is the same regime flip the rolled-behind
    /// probe showed breaks the custody family.
    static let aheadMarginSeconds: TimeInterval = 30 * 24 * 60 * 60

    /// The anchor itself: exactly `MeshP3Acceptance.base` while that instant is still more than
    /// ``aheadMarginSeconds`` away, and `Date()` plus that margin from the crossover on.
    ///
    /// The crossover is **2026-12-16T08:00:00Z** — one whole margin BEFORE the pinned
    /// 2027-01-15T08:00:00Z instant, not when the wall clock reaches it. Evaluated exactly once per
    /// process, and pinned as an assertion by
    /// `MeshP5DeterminismAcceptanceTests.theRoutedFixtureAnchorHoldsItsContract`.
    static let createdAt: Date = max(
        MeshP3Acceptance.base, Date().addingTimeInterval(aheadMarginSeconds)
    )
}
