// PersistenceFailureAudit.swift
// FernletFoundation
//
// The one audit seam for ENVIRONMENTAL persistence failures — a Core Data fetch/save/delete, a
// file read/write/remove, or the payload encode that feeds one.
//
// Why it exists (P9 item 1, plan §14.3 finding 3): every per-row store used to answer such a
// failure with `assertionFailure` inside its `catch`. An assert traps the process in DEBUG, and
// these failures are not programmer errors — the Core Data stores and the local JSON blob load
// with `FileProtectionType.complete`, and nothing defers a day write while the device is locked,
// so an ordinary locked-device or full-disk write returns `NSCocoaErrorDomain` and the DEBUG
// build dies ("Fatal error: day record delete failed"). Every one of those sites now records
// here and returns its existing `false`/empty result, which the callers already retry on.
//
// S3: the record carries the event token and the error's KIND ONLY — `NSError.domain` and
// `NSError.code`, both frozen strings/integers from the framework. Never `localizedDescription`
// (an `EncodingError`'s description embeds the coding path, which can name a day key), never
// `userInfo` (Cocoa file errors carry `NSFilePath`), and never anything user-derived: no day
// contents, narrative, recipe title, or photo path.

import Foundation

/// Audits an environmental persistence failure without trapping the process.
///
/// A store or file operation can fail for reasons entirely outside the program's control — the
/// device is locked and the `FileProtectionType.complete` store is unreadable, the disk is full,
/// a directory has been removed, iCloud rolled the context back. Those are runtime conditions,
/// not violated invariants, so the sites that hit them record through ``record(_:error:context:)``
/// and propagate their existing failure result rather than asserting. Programmer-error guards
/// (an empty day key, an unreachable enum case) keep their `assertionFailure`.
///
/// Emitted events follow the codebase's dotted `<area>.<subject>.<event>` convention, e.g.
/// `dayRecord.delete.failed`. All members are `nonisolated` and callable from any executor.
public nonisolated enum PersistenceFailureAudit {
    /// The context key carrying the failing error's `NSError` domain.
    public static let domainKey = "domain"
    /// The context key carrying the failing error's `NSError` code.
    public static let codeKey = "code"

    /// Records an environmental persistence failure.
    ///
    /// - Parameters:
    ///   - event: The frozen dotted audit token (never localized — it is a token, not display
    ///     text).
    ///   - error: The failure, when one is available. Only its `NSError` domain and code are
    ///     recorded; the description and `userInfo` are deliberately dropped, because they can
    ///     embed a coding path or a file path. `nil` for the sites whose failure carries no error
    ///     value (a `try?` that only yields absence).
    ///   - context: Extra frozen, non-user-derived detail — e.g. which row store failed. Keys
    ///     collide-last with ``domainKey``/``codeKey``, which are added here.
    nonisolated public static func record(
        _ event: String,
        error: Error? = nil,
        context: [String: String] = [:]
    ) {
        var merged = context
        if let error {
            let bridged = error as NSError
            merged[domainKey] = bridged.domain
            merged[codeKey] = String(bridged.code)
        }
        FernletAuditLog.log(event, context: merged)
    }
}
