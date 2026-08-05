// RowPayloadCoders.swift
// FernletFoundation
//
// Single source of truth for the JSON coder config shared by every persisted-JSON payload:
// the per-row Core Data + iCloud stores in `CloudKitSync` (day rows, coin-ledger rows,
// custom-item rows, the aggregate blob, and the legacy saved-recipe JSON file) and the
// local-only aggregate blob file in `LocalPersistence`. Previously each store carried its own
// private `makeEncoder`/`makeDecoder`, so the config drifted: three stores used `.sortedKeys`
// + `.iso8601` while the coin-ledger and custom-item stores encoded their rows with a BARE
// `JSONEncoder()`/`JSONDecoder()` (deferred-to-date numeric dates) — an inconsistent on-disk
// date format across sibling row stores.
//
// Canonical config: deterministic key ordering (`.sortedKeys`) + ISO-8601 dates, matched decoder.
// `prettyPrinted` is opt-in for the callers that write human-readable on-disk JSON files
// (`LegacySavedRecipeJSONRepository` and `LocalFernletRepository`'s blob file) and want that
// extra formatting flag the row stores don't.

import Foundation

/// Single source of truth for the JSON coder configuration shared by every persisted-JSON store.
///
/// Day rows, coin/milestone-ledger rows, custom-item rows, saved-recipe payloads, the synced
/// aggregate blob, and the legacy recipe JSON file (all in `CloudKitSync`), plus the local-only
/// blob file (`LocalPersistence`), all encode through this one config — deterministic
/// `.sortedKeys` ordering plus ISO-8601 dates — after per-store private coders drifted (two
/// stores once wrote bare numeric dates). ISO-8601 truncates dates to whole seconds, which
/// callers that compare dates across representations must account for (see
/// `SavedRecipeRepository`'s divergence flooring in `CloudKitSync`).
public nonisolated enum RowPayloadCoders {
    /// The canonical row-payload encoder: sorted keys + ISO-8601 dates. Pass `prettyPrinted: true`
    /// only for on-disk files that intentionally want human-readable output (the legacy recipe
    /// JSON and the local-only aggregate blob file).
    public static func makeEncoder(prettyPrinted: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = prettyPrinted ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    /// The matching decoder: ISO-8601 dates. One decoder reads every encoder above (pretty-printing
    /// affects only whitespace, not the decodable payload).
    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
