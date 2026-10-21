//
//  MeshConnectCues.swift
//  Fernlet
//
//  The two haptic decisions of the in-person connect (sounds-and-haptics Tier B, 2026-10-20;
//  `Docs/Handoff/Sounds-Haptics-Investigation.md` B19 and B20), kept as plain values so a test can
//  step them through the player's `perform` seam instead of holding two phones.
//
//  The flagship moment is felt as two steps: close enough, then connected. "Close enough" is
//  ``ProximityApproachCue`` — one `tick` as the phones come inside the 15 cm commit distance, which
//  the row's "Hold still…" line says in words. "Connected" is ``SessionConnectCue`` — `friendHere` on
//  a session's FIRST commit only, so a link that blips and heals in the same room is not
//  re-celebrated under the hand.
//
//  Fernlet's own feel, on purpose: one selection tick, then the heavy "friend's here" impact. It
//  does not try to imitate the system's contact-sharing animation or its haptic.
//
//  Both are haptic only (the mesh never sounds) and both answer the person's own movement or the
//  session they started; a peer appearing nearby on its own plays nothing. Neither reads duress
//  state: under a duress session every radio is off, so no distance and no commit ever arrive.
//

import FernletUI

/// The 15 cm approach: one `tick` per approach, with hysteresis (report B19).
///
/// ProximityKit's commit detector keeps its dwell state private, so the app derives "close enough"
/// from the public `ProximityCoordinator.lastKnownDistance` it already draws. The cue fires once when
/// a reading lands at or inside ``commitMeters`` and re-arms only after a reading beyond
/// ``rearmMeters``, so the jitter of a hand held right at the line never buzzes twice. A missing
/// reading (`nil` — ranging paused, or `.unknown`) changes nothing: losing ranging while the phones
/// are pressed together is not moving away.
struct ProximityApproachCue: Equatable {
    /// ProximityKit's friend-mode commit distance (its internal `friendCommitThresholdMeters`, which
    /// is not public), mirrored here. The row's "Hold still…" line reads the same figure.
    static let commitMeters = 0.15
    /// How far back the phones must move before the next approach can tick: twice the commit
    /// distance, so ordinary hand tremor at the line stays one approach.
    static let rearmMeters = 0.30

    /// Whether the next reading inside ``commitMeters`` plays. True until an approach has ticked.
    private(set) var isArmed = true

    /// Folds one distance reading in and names the cue it plays, if any.
    ///
    /// - Parameter meters: The latest measured distance, or nil when there is no reading.
    /// - Returns: `.tick` for the reading that completes an approach; nil otherwise.
    mutating func observe(_ meters: Double?) -> FernletFeedbackEvent? {
        guard let meters, meters.isFinite else { return nil }
        if meters > Self.rearmMeters {
            isArmed = true
            return nil
        }
        guard isArmed, meters <= Self.commitMeters else { return nil }
        isArmed = false
        return .tick
    }

    /// Whether `meters` is inside the commit distance — the row's "Hold still…" line, the cue's
    /// visual twin.
    static func isWithinCommitDistance(_ meters: Double) -> Bool {
        meters.isFinite && meters <= commitMeters
    }
}

/// "Your friend's here", once per session: `friendHere` on the first commit, silence on a heal
/// (report B20).
///
/// A founded mesh outlives its links (`MeshNetworkManager.hasCommittedPeer` dips during a blip while
/// `isSessionLive` holds), so the commit edge fires again when a link heals. The celebration overlay
/// may replay — it is the visual — but the haptic is for the moment the session began. The latch
/// resets when the session ends (`isSessionLive` goes false, or the session surface goes away), and a
/// fresh Friends surface that opens on a session already running starts greeted, as the overlay's
/// own "already in session — skip the animation" rule does.
struct SessionConnectCue: Equatable {
    /// Whether this session's first commit has already been felt.
    private(set) var hasGreeted = false

    /// A peer committed: `friendHere` the first time this session, nothing on a heal.
    mutating func committed() -> FernletFeedbackEvent? {
        guard !hasGreeted else { return nil }
        hasGreeted = true
        return .friendHere
    }

    /// The session ended: the next commit begins a new session and is felt.
    mutating func sessionEnded() {
        hasGreeted = false
    }

    /// The surface appeared: a session already running was greeted before this view existed.
    mutating func surfaceAppeared(inSession: Bool) {
        hasGreeted = inSession
    }
}
