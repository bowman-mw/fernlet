import Foundation

/// The session-photo review hosts' wait for the person to acknowledge a failed "Also save kept
/// photos to Photos" export before the review goes on to leave the session and hide.
///
/// Design §4.6 orders the answer as: commit, export, the failure alert INSIDE the review, then the
/// leave, then the hide. The alert (`photoSaveFailureAlert`) hangs off the review sheet, so a host
/// that hid the sheet in the same turn the export failed took the alert down unseen — the person
/// believed the photos were in their camera roll, and the stale error opened the NEXT review
/// (fix round 1, findings U2-C-U2-R2 / U2-L-U2-R2). The host's answer action now suspends here
/// while an export failure is on screen, so the sheet's `runExclusively` keeps every button
/// disabled until the alert is closed.
///
/// Resumed by ``acknowledge()`` — which the host calls when the failure binding clears (either
/// alert button, or the system dismissing it) AND when the review sheet disappears, so a sheet torn
/// down underneath (a heal, a duress withdrawal) never strands the suspended answer.
///
/// Concurrency: `@MainActor` — the hosts are SwiftUI views; the stored continuation is touched only
/// on the main actor, and it is resumed at most once (it is cleared before it is resumed).
@MainActor
final class PhotoSaveFailureAcknowledgement {
    /// The suspended answer, if one is waiting.
    private var waiting: CheckedContinuation<Void, Never>?

    /// Whether an answer is suspended here right now.
    var isWaiting: Bool { waiting != nil }

    /// Suspends until ``acknowledge()``. A second waiter while one is already suspended returns at
    /// once rather than replacing (and stranding) the first; the hosts run one answer at a time.
    func wait() async {
        guard waiting == nil else { return }
        await withCheckedContinuation { continuation in
            waiting = continuation
        }
    }

    /// Resumes the suspended answer, if any. Safe to call any number of times.
    func acknowledge() {
        guard let continuation = waiting else { return }
        waiting = nil
        continuation.resume()
    }
}
