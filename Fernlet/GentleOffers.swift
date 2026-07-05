//
//  GentleOffers.swift
//  Fernlet
//
//  The pure gating/rotation logic behind the ambient gentle-offer card (max ONE per day,
//  persisted via DiaryStore's gentle-offer dismissal key). Offers are invitations, never
//  demands: dismissing or accepting one quiets the card until tomorrow.
//

import Foundation
import FernletScoring

/// One of the small kindnesses Fernlet can offer on a heavier day.
enum GentleOfferKind: String, CaseIterable, Equatable {
    case breathing
    case worryBox
    case shortWalk

    /// Invitation copy — offered, never prescribed. No pressure words, no "you should".
    var invitation: String {
        switch self {
        case .breathing:
            "Would a minute of slow breathing feel nice? No pressure at all."
        case .worryBox:
            "Carrying something around? You could write it down and let the worry box hold it for a while."
        case .shortWalk:
            "It's gentle outside right now — a short stroll might feel nice, only if you want to."
        }
    }

    var icon: String {
        switch self {
        case .breathing: "wind"
        case .worryBox: "archivebox"
        case .shortWalk: "figure.walk"
        }
    }
}

/// Pure, deterministic offer selection. The persisted once-per-day cap lives in
/// `DiaryStore.isGentleOfferAvailable` / `dismissGentleOfferForToday`; this engine only decides
/// WHETHER today warrants an offer and WHICH one.
enum GentleOfferEngine {
    /// Picks today's offer, or `nil` when the day doesn't call for one.
    ///
    /// Gates (either opens the door):
    /// - the opt-in body-signals reading is at least "tense" (`stressAwarenessEnabled` + state), or
    /// - the mood trend derived signal reads "needs gentleness" (its exact emitted literal).
    ///
    /// Rotation is deterministic per `dateKey` so the offer doesn't shuffle between renders, and
    /// the short walk only enters the rotation when the (opt-in, cached) weather comfort check
    /// says pleasant + daytime.
    static func offer(
        dateKey: String,
        stressAwarenessEnabled: Bool,
        stressState: StressState?,
        moodTrendValue: String?,
        walkIsInviting: Bool
    ) -> GentleOfferKind? {
        let bodyGate = stressAwarenessEnabled && (stressState == .tense || stressState == .needsCare)
        let moodGate = moodTrendValue == "needs gentleness"
        guard bodyGate || moodGate else { return nil }

        var candidates: [GentleOfferKind] = [.breathing, .worryBox]
        if walkIsInviting { candidates.append(.shortWalk) }
        return candidates[rotationSeed(dateKey: dateKey) % candidates.count]
    }

    /// Stable per-day seed (djb2 over the day key) — `String.hashValue` is randomized per launch,
    /// which would make the offer flicker across app restarts on the same day.
    static func rotationSeed(dateKey: String) -> Int {
        var hash: UInt64 = 5381
        for scalar in dateKey.unicodeScalars {
            hash = (hash << 5) &+ hash &+ UInt64(scalar.value)
        }
        return Int(hash % 1000)
    }
}
