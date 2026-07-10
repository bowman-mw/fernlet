// EnumDecodeCompat.swift
// Forward-compatible decoding for synced raw-value enums — the generalization of the
// homeWidgets/quickLogItems fix in SettingsModel (commit faaf82d).
//
// The problem: every raw-value enum that reaches a synced payload (the FernletSnapshot blob, a
// DayRecord row) decodes STRICTLY — `decode`/`decodeIfPresent` throw `.dataCorrupted` on a raw
// value only a NEWER build knows (`decodeIfPresent` returns nil ONLY for an absent/null KEY, not
// for a present-but-unrecognized value). Inside the aggregate blob that throw cascades into
// decode-failure recovery (`markPersistenceBlockedByDecodeFailure`): the store comes back empty
// and read-only on the older paired device. Inside a DayRecord row it silently drops that day.
//
// The contract (identical to SettingsModel's array side channels):
// - The ORIGINAL key always carries a raw value this build knows (or the frozen default), so a
//   strict older build can still decode this build's re-save.
// - A raw value this build does NOT know decodes to the field's default; the token is PARKED in a
//   side-channel key and re-encoded, so a save on this device can't strip a newer build's value
//   from the synced payload.
// - A build that knows a parked token re-adopts it on decode (self-healing after upgrade) and
//   clears the channel.
// - An explicit local mutation clears the parked token (`didSet` on the typed field), so the last
//   editor wins over a stale parked value.

import Foundation

public nonisolated enum EnumDecodeCompat {
    /// Defensive bounds for parked unknown tokens: real ones are enum raw values from a future
    /// build (a handful, tens of characters), so anything past these is treated as corrupt and
    /// dropped. Shared with SettingsModel's array side channels.
    public static let unknownTokenCountLimit = 16
    public static let unknownTokenLengthLimit = 64

    /// Splits a synced raw-token array into the enum cases this build knows and the (deduped,
    /// bounded) tokens it doesn't. Both halves keep first-occurrence order.
    public static func splitRawTokens<Case: RawRepresentable>(
        _ tokens: [String],
        as type: Case.Type
    ) -> (known: [Case], unknown: [String]) where Case.RawValue == String {
        var known: [Case] = []
        var seenKnownTokens: Set<String> = []
        var unknown: [String] = []
        for token in tokens {
            if let value = Case(rawValue: token) {
                if seenKnownTokens.insert(token).inserted { known.append(value) }
            } else if token.count <= unknownTokenLengthLimit,
                      unknown.count < unknownTokenCountLimit,
                      !unknown.contains(token) {
                unknown.append(token)
            }
        }
        return (known, unknown)
    }

    /// Resolves a scalar enum field from its raw token + previously parked token.
    ///
    /// - A known main token wins unless a known parked token survives (a parked token only
    ///   survives while no explicit local edit has cleared it, so it is the latest true choice —
    ///   adopt it and clear the channel).
    /// - An unknown main token freezes the field to `defaultValue` and becomes the parked token
    ///   (the main key is the latest write, so it supersedes any previously parked token).
    /// - An absent key adopts a known parked token, else falls back to `defaultValue`.
    ///
    /// `resolve` maps a raw token to a case; the default is `Case.init(rawValue:)` — pass a custom
    /// resolver for enums with legacy aliases (e.g. `GoalType.init(persistedToken:)`).
    public static func resolveScalar<Case: RawRepresentable>(
        token: String?,
        parkedToken: String?,
        default defaultValue: Case,
        resolve: (String) -> Case? = { Case(rawValue: $0) }
    ) -> (value: Case, parkedToken: String?) where Case.RawValue == String {
        let parked = bounded(parkedToken)
        if let token {
            if let value = resolve(token) {
                if let parked, let adopted = resolve(parked) { return (adopted, nil) }
                return (value, parked)
            }
            return (defaultValue, bounded(token) ?? parked)
        }
        if let parked, let adopted = resolve(parked) { return (adopted, nil) }
        return (defaultValue, parked)
    }

    /// `resolveScalar` for an Optional enum field: an unknown token resolves to `nil` (rather than
    /// a made-up default) and is parked. Same adoption/supersede rules.
    public static func resolveOptionalScalar<Case: RawRepresentable>(
        token: String?,
        parkedToken: String?,
        resolve: (String) -> Case? = { Case(rawValue: $0) }
    ) -> (value: Case?, parkedToken: String?) where Case.RawValue == String {
        let parked = bounded(parkedToken)
        if let token {
            if let value = resolve(token) {
                if let parked, let adopted = resolve(parked) { return (adopted, nil) }
                return (value, parked)
            }
            return (nil, bounded(token) ?? parked)
        }
        if let parked, let adopted = resolve(parked) { return (adopted, nil) }
        return (nil, parked)
    }

    private static func bounded(_ token: String?) -> String? {
        token.flatMap { $0.count <= unknownTokenLengthLimit ? $0 : nil }
    }
}

public extension KeyedDecodingContainer {
    /// Freeze-on-unknown scalar enum decode with a parked-token side channel (see
    /// `EnumDecodeCompat.resolveScalar`). Absent keys resolve to `defaultValue` — tolerant by
    /// design, matching the house `decodeIfPresent ?? default` style.
    func decodeTolerantEnum<Case: RawRepresentable>(
        _ type: Case.Type,
        forKey key: Key,
        parkedTokenKey: Key,
        default defaultValue: Case,
        resolve: (String) -> Case? = { Case(rawValue: $0) }
    ) throws -> (value: Case, parkedToken: String?) where Case.RawValue == String {
        EnumDecodeCompat.resolveScalar(
            token: try decodeIfPresent(String.self, forKey: key),
            parkedToken: try decodeIfPresent(String.self, forKey: parkedTokenKey),
            default: defaultValue,
            resolve: resolve
        )
    }

    /// `decodeTolerantEnum` for an Optional enum field: unknown token → `nil` + parked.
    func decodeTolerantOptionalEnum<Case: RawRepresentable>(
        _ type: Case.Type,
        forKey key: Key,
        parkedTokenKey: Key,
        resolve: (String) -> Case? = { Case(rawValue: $0) }
    ) throws -> (value: Case?, parkedToken: String?) where Case.RawValue == String {
        EnumDecodeCompat.resolveOptionalScalar(
            token: try decodeIfPresent(String.self, forKey: key),
            parkedToken: try decodeIfPresent(String.self, forKey: parkedTokenKey),
            resolve: resolve
        )
    }

    /// Tolerant decode of a `Set` of raw-value enums with a parked-tokens side channel: known
    /// tokens (from the main key AND any previously parked ones this build now knows) become the
    /// typed set; unknown tokens are parked (deduped, bounded — `splitRawTokens`).
    func decodeTolerantEnumSet<Case: RawRepresentable & Hashable>(
        _ type: Case.Type,
        forKey key: Key,
        parkedTokensKey: Key
    ) throws -> (known: Set<Case>, unknownTokens: [String]) where Case.RawValue == String {
        let tokens = try decodeIfPresent([String].self, forKey: key) ?? []
        let parked = try decodeIfPresent([String].self, forKey: parkedTokensKey) ?? []
        let split = EnumDecodeCompat.splitRawTokens(tokens + parked, as: Case.self)
        return (Set(split.known), split.unknown)
    }
}
