// MirrorSyncHealth.swift
// CloudKitSync
//
// What the app knows about whether iCloud is taking the mirrored store's changes (release review
// 2026-11-18, finding F2). `NSPersistentCloudKitContainer` exports in the background and reports a
// refused export only through `eventChangedNotification`; until this file nothing listened, so a
// Production schema that lacked a field left every export refused while the switch read "on".
// The pure half lives here (classifying an error, folding events into a state) so it is testable
// without CloudKit; `PersistenceController` owns the observer and the state.

import CloudKit
import Foundation

/// Which of the mirror's three activities an event reports.
public nonisolated enum MirrorSyncActivity: String, Equatable, Hashable, Sendable {
    /// Setting up the zone and subscriptions.
    case setup
    /// Bringing iCloud's changes down.
    case importing = "import"
    /// Sending this device's changes up.
    case exporting = "export"
}

/// Whether a failed mirror event will mend itself.
public nonisolated enum MirrorSyncFailureKind: String, Equatable, Sendable {
    /// Network, rate limit, a busy zone, an account that is briefly unavailable: the mirror retries
    /// and the next attempt can succeed with nothing changed. Logged, never shown.
    case transient
    /// iCloud refused the change itself: a record type or field the schema lacks, a permission, a
    /// full account. Retrying the same change fails the same way, so the person is told.
    case lasting
}

/// One lasting failure the mirror has not yet recovered from.
public nonisolated struct MirrorSyncIssue: Equatable, Sendable {
    /// The activity that failed.
    public let activity: MirrorSyncActivity
    /// The deciding error as `domain.code` (for a partial failure, the refused record's own error).
    /// A token for the audit log, never display text.
    public let code: String
    /// When the first failure of this run was seen.
    public let since: Date
}

/// Sorts a mirror event's error into ``MirrorSyncFailureKind``.
///
/// A CloudKit partial failure is judged by its per-record errors: one refused record makes the whole
/// event lasting, because the mirror's zone saves atomically and that record holds the batch back.
/// An error with no CloudKit error inside it (Core Data's own "no account" codes among them) counts
/// as transient: the person is warned only on evidence that iCloud refused the change.
public nonisolated enum MirrorSyncErrorClassifier {
    /// How many nested errors one classification reads at most (Power of 10: a fixed loop bound).
    static let maximumErrorsRead = 512

    /// The CloudKit codes that mean "this change will be refused again".
    static let lastingCodes: Set<CKError.Code> = [
        .invalidArguments, .unknownItem, .serverRejectedRequest, .permissionFailure, .badContainer,
        .missingEntitlement, .incompatibleVersion, .constraintViolation, .assetFileNotFound,
        .badDatabase, .referenceViolation, .quotaExceeded, .managedAccountRestricted
    ]

    /// The kind of `error`, with the `domain.code` of the error that decided it.
    public static func classify(_ error: any Error) -> (kind: MirrorSyncFailureKind, code: String) {
        let top = error as NSError
        var queue: [NSError] = [top]
        var read = 0
        while let next = queue.popLast(), read < maximumErrorsRead {
            read += 1
            if next.domain == CKErrorDomain, let code = CKError.Code(rawValue: next.code), lastingCodes.contains(code) {
                return (.lasting, token(next))
            }
            queue.append(contentsOf: nested(in: next))
        }
        return (.transient, token(top))
    }

    /// The errors one level inside `error`: a partial failure's per-record errors, and Foundation's
    /// underlying and detailed errors (how Core Data wraps what CloudKit told it).
    private static func nested(in error: NSError) -> [NSError] {
        var found: [NSError] = []
        if let perItem = error.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: any Error] {
            found.append(contentsOf: perItem.values.map { $0 as NSError })
        }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            found.append(underlying)
        }
        if let detailed = error.userInfo["NSDetailedErrors"] as? [NSError] {
            found.append(contentsOf: detailed)
        }
        return found
    }

    private static func token(_ error: NSError) -> String {
        "\(error.domain).\(error.code)"
    }
}

/// The mirror's lasting failures, folded from its finished events.
///
/// A lasting failure of an activity stands until that same activity next finishes cleanly; a
/// transient failure neither raises nor clears one. Exports are sent in batches, so after a refusal
/// a later batch that lands clears the issue until the refused one is retried and reports again.
public nonisolated struct MirrorSyncHealth: Equatable, Sendable {
    /// What one finished event did to the state.
    public enum Change: Equatable, Sendable {
        /// The event succeeded and there was nothing to clear.
        case healthy
        /// The event succeeded and cleared a standing issue.
        case recovered
        /// The event failed in a way that mends itself.
        case transientFailure(code: String)
        /// The event failed in a way that will repeat.
        case lastingFailure(code: String)
    }

    private var issues: [MirrorSyncActivity: MirrorSyncIssue] = [:]

    /// A state with no failure recorded.
    public init() {}

    /// The standing issue to tell the person about, an export's first (their own changes are the
    /// ones not reaching iCloud), or nil when every activity last finished cleanly.
    public var lastingIssue: MirrorSyncIssue? {
        issues[.exporting] ?? issues[.importing] ?? issues[.setup]
    }

    /// Folds one finished event in.
    ///
    /// - Parameters:
    ///   - activity: Which activity finished.
    ///   - error: The event's error, or nil when it succeeded.
    ///   - date: When it finished.
    public mutating func record(_ activity: MirrorSyncActivity, error: (any Error)?, at date: Date) -> Change {
        guard let error else {
            return issues.removeValue(forKey: activity) == nil ? .healthy : .recovered
        }
        let verdict = MirrorSyncErrorClassifier.classify(error)
        guard verdict.kind == .lasting else { return .transientFailure(code: verdict.code) }
        if issues[activity] == nil {
            issues[activity] = MirrorSyncIssue(activity: activity, code: verdict.code, since: date)
        }
        return .lastingFailure(code: verdict.code)
    }
}
