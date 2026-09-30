import Foundation
import FernletFoundation

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
/// **Only while the review that shows the alert is open** (session photos U3, fix round 1, finding
/// U3-C-U3-R1). The host opens it when its review presents (``reviewDidOpen()``) and closes it when
/// that review goes (``reviewDidClose()``: the overlay's hides, the Develop sheet's flag falling on
/// a swipe-down or on the camera leaving the hierarchy). A wait that begins after the review has
/// gone — the export failed after First Aid, a duress session, a delete-all or a termination took
/// the review down under it — returns at once and audits the failure as unseen: there is no alert
/// left to close, and before this rule that wait never ended, so the answer's `endAnswer()` never
/// ran and the discovery block and every later review's buttons were stuck for the process.
///
/// Resumed by ``acknowledge()`` — which the host calls when the failure binding clears (either
/// alert button, or the system dismissing it) — and by ``reviewDidClose()``, so a review torn down
/// while its answer waits never strands it. Starts CLOSED: a host that never opened it can never
/// wait on it.
///
/// Concurrency: `@MainActor` — the hosts are main-actor state; the stored continuation is touched
/// only on the main actor, and it is resumed at most once (it is cleared before it is resumed).
@MainActor
final class PhotoSaveFailureAcknowledgement {
    /// Which review this acknowledgement belongs to ("overlay", "develop") — the audit's only context.
    let host: String
    /// The suspended answer, if one is waiting.
    private var waiting: CheckedContinuation<Void, Never>?
    /// Whether the review that shows the failure alert is on screen.
    private(set) var reviewIsOpen = false

    /// Creates a closed acknowledgement.
    ///
    /// - Parameter host: Which review it belongs to, for the unseen-failure audit (a frozen token).
    init(host: String) {
        self.host = host
    }

    /// Whether an answer is suspended here right now.
    var isWaiting: Bool { waiting != nil }

    /// The host's review is on screen: a failure from now on is shown there and waited for.
    func reviewDidOpen() {
        reviewIsOpen = true
    }

    /// The host's review went: resumes a waiting answer and makes any later wait return at once.
    func reviewDidClose() {
        reviewIsOpen = false
        acknowledge()
    }

    /// Suspends until ``acknowledge()`` or ``reviewDidClose()`` — if the review is open. With the
    /// review closed there is no alert to close: it returns at once and audits the failure as
    /// unseen. A second waiter while one is already suspended returns at once rather than replacing
    /// (and stranding) the first; the hosts run one answer at a time.
    func wait() async {
        guard reviewIsOpen else {
            FernletAuditLog.log("sessionPhotoReview.exportFailureUnseen", context: ["host": host])
            return
        }
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
