// HeartSharing.swift
// FernletDomainModel
//
// Wire model + presentation math for "send good vibes" hearts between friends (spec §10,
// proximity-only v1). The payload lives here — not in ProximityKit — so the Phase-6 remote
// dead-drop (CloudKitSync carrying pre-sealed envelopes) can reference the type without an
// edge into the proximity subsystem, mirroring how PayloadType itself was carved down.

import Foundation

/// The entire content of a heart. Deliberately minimal (the fuzzy-vibes axiom): NO free-text
/// note, NO numbers, NO sender wellbeing state — a heart says "a friend is thinking of you"
/// and nothing else. Signed/sealed on the wire exactly like a recipe share.
public nonisolated struct HeartPayload: Codable, Equatable, Identifiable, Sendable {
    public var format = "fernlet.proximity.heart"
    public var version = 1
    public var id = UUID()
    /// The sender's local calendar day (`yyyy-MM-dd`) when the heart was sent. The only
    /// non-identity field, and it carries no wellbeing information.
    public var sentAtDayKey: String

    public init(
        format: String = "fernlet.proximity.heart",
        version: Int = 1,
        id: UUID = UUID(),
        sentAtDayKey: String
    ) {
        self.format = format
        self.version = version
        self.id = id
        self.sentAtDayKey = sentAtDayKey
    }

    /// Wire-boundary shape check for the (untrusted, peer-supplied) day key: exactly
    /// `yyyy-MM-dd` — ten characters, ASCII digits with dashes at positions 4 and 7.
    /// Anything else is a protocol violation and the heart is dropped, so a hostile peer
    /// can never land an oversized or control-character string in local state.
    public static func isValidDayKey(_ key: String) -> Bool {
        let scalars = Array(key.unicodeScalars)
        guard scalars.count == 10 else { return false }
        for (index, scalar) in scalars.enumerated() {
            if index == 4 || index == 7 {
                if scalar != "-" { return false }
            } else if !(scalar.value >= 0x30 && scalar.value <= 0x39) {
                return false
            }
        }
        return true
    }
}

/// Pure decay math for the received-heart glow on the health bar. Presentation-only by design:
/// hearts must never enter `FernletScoring.compute` or any persisted score — the glow is a
/// display overlay that fades out, not a score input (spec §10 "decaying health-bar segments").
public nonisolated enum HeartGlowMath {
    /// How long a received heart glows: 24 hours from receipt, fading linearly.
    public static let decayWindow: TimeInterval = 24 * 60 * 60

    /// Linear 1 → 0 glow over `window` seconds from `receivedAt`, clamped to [0, 1].
    /// A receipt timestamp in the future (device clock moved back) reads as just-received
    /// rather than producing an out-of-range value.
    public static func glow(receivedAt: Date, at date: Date, window: TimeInterval = decayWindow) -> Double {
        guard window > 0 else { return 0 }
        let elapsed = max(0, date.timeIntervalSince(receivedAt))
        return max(0, min(1, 1 - elapsed / window))
    }
}
