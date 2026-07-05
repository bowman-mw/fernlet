// RowPayloadCoders.swift
// CloudKitSync
//
// Single source of truth for the JSON coder config used by the per-row Core Data + iCloud stores
// (day rows, coin-ledger rows, custom-item rows, the aggregate blob, and the legacy saved-recipe
// JSON file). Previously each store carried its own private `makeEncoder`/`makeDecoder`, so the
// config drifted: three stores used `.sortedKeys` + `.iso8601` while the coin-ledger and custom-item
// stores encoded their rows with a BARE `JSONEncoder()`/`JSONDecoder()` (deferred-to-date numeric
// dates) — an inconsistent on-disk date format across sibling row stores.
//
// Canonical config: deterministic key ordering (`.sortedKeys`) + ISO-8601 dates, matched decoder.
// `prettyPrinted` is opt-in for the one caller (`LegacySavedRecipeJSONRepository`) that writes a
// human-readable on-disk JSON file and wants that extra formatting flag the row stores don't.

import Foundation

nonisolated enum RowPayloadCoders {
    /// The canonical row-payload encoder: sorted keys + ISO-8601 dates. Pass `prettyPrinted: true`
    /// only for on-disk files that intentionally want human-readable output (the legacy recipe JSON).
    static func makeEncoder(prettyPrinted: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = prettyPrinted ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    /// The matching decoder: ISO-8601 dates. One decoder reads every encoder above (pretty-printing
    /// affects only whitespace, not the decodable payload).
    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
