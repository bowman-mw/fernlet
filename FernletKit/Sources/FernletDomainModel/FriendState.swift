// FriendState.swift
// FernletDomainModel
//
// The friend-facing "fuzzy vibe" (spec: "Friends see fuzzy vibes, never numbers") plus the sealed
// payload that carries it — the ONLY wellbeing signal that may cross the friend wire. It is derived
// from the `CompanionState` ENUM, never the numeric score, so the number is structurally incapable of
// entering a shareable value; and `.sick`/`.resting`/`.tired` all fold to `.struggling` so a
// health-adverse state can't be distinguished by a friend (2026-07-11 fuzzy-state memo).

import Foundation

/// The three-way friend-facing state. Int-raw so every value serializes to the SAME one byte — a
/// passive observer can't read the state off a sealed envelope's length.
public nonisolated enum FriendFuzzyState: Int, Codable, CaseIterable, Sendable {
    case thriving = 1
    case okay = 2
    case struggling = 3

    /// The `CompanionState` a receiver renders for this bucket. `struggling` renders the `tired` visual
    /// (never `sick`/`resting`), so the render can't reveal the 5-way state the fold erased.
    public var representativeState: CompanionState {
        switch self {
        case .thriving: .thriving
        case .okay: .okay
        case .struggling: .tired
        }
    }

    public var label: String {
        switch self {
        case .thriving: "Thriving"
        case .okay: "Okay"
        case .struggling: "Struggling"
        }
    }
}

public extension CompanionState {
    /// The friend-facing fold. `sick`/`resting`/`tired` → `struggling`; nothing numeric survives.
    var fuzzy: FriendFuzzyState {
        switch self {
        case .thriving: .thriving
        case .okay: .okay
        case .tired, .resting, .sick: .struggling
        }
    }
}

/// The sealed payload exchanged at an in-person friend session: the 3-way fuzzy state + the sender's
/// avatar appearance (so a friend can render the companion "as of when you last met"). The appearance
/// keeps its `.state` palette UNRESOLVED — the receiver renders `.state` slots from the fuzzy value, so
/// the appearance can't leak the true 5-way state either.
public nonisolated struct FriendStatePayload: Codable, Equatable {
    public var format = "fernlet.friend.state"
    public var version = 1
    public var id = UUID()
    /// Exactly 1, 2, or 3 (a `FriendFuzzyState` raw value). Validated on receipt.
    public var state: Int
    public var appearance: CompanionAppearance

    public init(state: FriendFuzzyState, appearance: CompanionAppearance, id: UUID = UUID()) {
        self.state = state.rawValue
        self.appearance = appearance
        self.id = id
    }

    /// The decoded fuzzy state, or nil when a hostile peer sent an out-of-range code.
    public var fuzzyState: FriendFuzzyState? { FriendFuzzyState(rawValue: state) }

    /// Boundary shape-check: correct format/version and an in-range state code.
    public var isWellFormed: Bool {
        format == "fernlet.friend.state" && version == 1 && fuzzyState != nil
    }

    /// The appearance with any hostile custom-color hex clamped away — the appearance's only free-text
    /// surface (every other field is a tolerant-decoded enum). Renders safely on receipt.
    public var sanitizedAppearance: CompanionAppearance {
        var a = appearance
        a.bodyCustomColorHex = FriendStatePayload.cleanHex(a.bodyCustomColorHex)
        a.accessoryCustomColorHex = FriendStatePayload.cleanHex(a.accessoryCustomColorHex)
        a.clothingCustomColorHex = FriendStatePayload.cleanHex(a.clothingCustomColorHex)
        a.sideItemCustomColorHex = FriendStatePayload.cleanHex(a.sideItemCustomColorHex)
        return a
    }

    private static func cleanHex(_ hex: String?) -> String? {
        guard let hex else { return nil }
        let body = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard (3...8).contains(body.count), body.allSatisfy(\.isHexDigit) else { return nil }
        return "#" + body
    }
}
