// PhotoSaveFailureAcknowledgementTests.swift
// FernletTests
//
// Fix round 1 of the 2026-09-30 session-photo Unit 2, findings U2-C-U2-R2 / U2-L-U2-R2: a failed
// "Also save kept photos to Photos" export was effectively swallowed. Both review hosts set
// `photoSaveError` and then hid the review in the same main-actor turn — the Friends host with no
// mesh left to leave, the camera host right after its leave — so the failure alert, which hangs off
// the review sheet, was taken down with it. The person believed the photos were in their camera
// roll, and the stale error opened the NEXT review.
//
// Design §4.6's order is: commit, export, the failure alert INSIDE the review, then the leave, then
// the hide. The hosts now suspend their answer on `PhotoSaveFailureAcknowledgement` while an export
// failure is on screen, resume it when the alert closes (or the sheet goes away), and reset the
// error each time a review presents. The behavioural half drives the acknowledgement itself; the
// source half pins both hosts to it, because the ordering lives in SwiftUI actions no tier-1 cell
// can press.
//
// Session photos U3, fix round 1 (U3-C-U3-R1): the wait runs only while the review that shows the
// alert is OPEN. A failure that lands after the review was taken down (First Aid, duress, a
// delete-all, a termination, a swipe-down) has no alert left to close; waiting for it stranded the
// answer's `endAnswer()` for the process — discovery stayed blocked and every later review refused
// its actions. The acknowledgement now starts closed, is opened and closed by its host, returns at
// once (audited) when closed, and a close resumes a waiter.

import Foundation
import Testing
import FernletFoundation
@testable import Fernlet

/// The acknowledgement a review's answer waits on.
@MainActor
@Suite(.serialized)
struct PhotoSaveFailureAcknowledgementTests {

    /// Starts a task that waits on `acknowledgement` and reports when it resumed, and returns once
    /// the task is suspended there.
    private static func suspendedWaiter(
        on acknowledgement: PhotoSaveFailureAcknowledgement
    ) async -> Task<Bool, Never> {
        let task = Task { @MainActor in
            await acknowledgement.wait()
            return true
        }
        // R2: bounded — at most 100 yields for the task to reach its suspension.
        for _ in 0..<100 where !acknowledgement.isWaiting { await Task.yield() }
        return task
    }

    /// Whether a wait on `acknowledgement` returns without suspending. Bounded, and it never
    /// hangs: a wait that did suspend (the bug this pins) is released before the answer is read, so
    /// the cell fails instead of stranding the run.
    private static func waitReturnsAtOnce(_ acknowledgement: PhotoSaveFailureAcknowledgement) async -> Bool {
        let waiter = Task { @MainActor in await acknowledgement.wait() }
        // R2: bounded — at most 100 yields for the wait to return or to suspend.
        for _ in 0..<100 where !acknowledgement.isWaiting { await Task.yield() }
        let suspended = acknowledgement.isWaiting
        acknowledgement.acknowledge()
        await waiter.value
        return !suspended
    }

    /// An acknowledgement whose review is open, as a host's is while its review is on screen.
    private static func opened() -> PhotoSaveFailureAcknowledgement {
        let acknowledgement = PhotoSaveFailureAcknowledgement(host: "test")
        acknowledgement.reviewDidOpen()
        return acknowledgement
    }

    /// The answer stays suspended until the alert is closed, and resumes exactly then.
    @Test func anAnswerWaitsUntilTheAlertIsClosed() async {
        let acknowledgement = Self.opened()
        let waiter = await Self.suspendedWaiter(on: acknowledgement)
        #expect(acknowledgement.isWaiting, "the answer is suspended while the failure is on screen")

        acknowledgement.acknowledge()

        #expect(await waiter.value, "closing the alert resumes it")
        #expect(!acknowledgement.isWaiting)
    }

    /// Acknowledging with nobody waiting — the alert closing after the sheet already went, or the
    /// sheet's disappearance after the alert already closed — does nothing, any number of times.
    @Test func anAcknowledgementWithNobodyWaitingIsHarmless() async {
        let acknowledgement = Self.opened()
        acknowledgement.acknowledge()
        acknowledgement.acknowledge()
        #expect(!acknowledgement.isWaiting)

        let waiter = await Self.suspendedWaiter(on: acknowledgement)
        acknowledgement.acknowledge()
        acknowledgement.acknowledge()   // the sheet's onDisappear right after the alert's OK
        #expect(await waiter.value)
    }

    /// A second wait while one answer is already suspended returns at once instead of replacing —
    /// and stranding — the first; the first still resumes on the acknowledgement.
    @Test func aSecondWaitNeverStrandsTheFirst() async {
        let acknowledgement = Self.opened()
        let first = await Self.suspendedWaiter(on: acknowledgement)

        await acknowledgement.wait()   // returns at once

        #expect(acknowledgement.isWaiting, "the first answer is still the one waiting")
        acknowledgement.acknowledge()
        #expect(await first.value)
    }

    /// **U3-C-U3-R1.** A wait that begins after the review went — the export failed after First
    /// Aid, a duress session, a termination or a swipe-down took the review down under it — returns
    /// at once and audits the failure as unseen: there is no alert left to close. A fresh
    /// acknowledgement is closed, so a host that never opened it can never wait on it.
    @Test func aWaitWithTheReviewClosedReturnsAtOnceAndIsAudited() async {
        let host = "test-\(UUID().uuidString)"
        let capture = MeshRoutedBackpressureAuditCapture()
        capture.install()
        defer { capture.uninstall() }
        let acknowledgement = PhotoSaveFailureAcknowledgement(host: host)

        let neverOpened = await Self.waitReturnsAtOnce(acknowledgement)
        acknowledgement.reviewDidOpen()
        acknowledgement.reviewDidClose()   // the review went before the export failed
        let afterClose = await Self.waitReturnsAtOnce(acknowledgement)

        let unseen = capture.values(of: "sessionPhotoReview.exportFailureUnseen", key: "host").filter { $0 == host }
        #expect(neverOpened, "a review never opened has no alert to wait for")
        #expect(afterClose, "nor does one that already went")
        #expect(unseen.count == 2, "each unseen failure is audited, never swallowed")
    }

    /// **U3-C-U3-R1.** The review going while an answer waits on its alert resumes that answer, and
    /// a review that opens again waits again.
    @Test func theReviewGoingResumesAWaitingAnswer() async {
        let acknowledgement = Self.opened()
        let waiter = await Self.suspendedWaiter(on: acknowledgement)
        #expect(acknowledgement.isWaiting, "the alert is up in the open review: the answer waits")

        acknowledgement.reviewDidClose()   // a termination unmounts the camera, or a hide

        #expect(!acknowledgement.isWaiting, "closing the review resumes the answer")
        acknowledgement.acknowledge()   // releases a waiter the close failed to (so the cell ends)
        #expect(await waiter.value)
        acknowledgement.reviewDidOpen()
        let next = await Self.suspendedWaiter(on: acknowledgement)
        #expect(acknowledgement.isWaiting, "a review open again waits again")
        acknowledgement.acknowledge()
        #expect(await next.value)
    }
}

/// Both review hosts show a failed export inside the review and wait for it to be closed before they
/// leave and hide, and neither opens a review with an earlier review's failure. Since session photos
/// U3 the two hosts are `SessionPhotoReviewCoordinator` (the overlay; its screen, in its own file,
/// hangs the alert and releases the wait) and the camera's Develop sheet.
@MainActor
struct ReviewHostsExportFailureSourceWallTests {

    /// One host's shape: its keep action, the function that opens its review, the leave-and-hide
    /// call, and the file (with its needles) that releases the wait when the alert closes or the
    /// review goes.
    private struct Host {
        let file: String
        let keep: String
        let presenter: String
        let finish: String
        let releaseFile: String
        let releases: [String]
    }

    private static let hosts = [
        Host(file: "App/Fernlet/SessionPhotoReviewCoordinator.swift",
             keep: "func keepSelected() async",
             presenter: "private func present()",
             finish: "await finish(after: answer)",
             releaseFile: "App/Fernlet/SessionPhotoReviewScreen.swift",
             releases: [".onChange(of: coordinator.photoSaveError == nil) { _, cleared in",
                        "if cleared { coordinator.acknowledgeSaveFailure() }",
                        ".onDisappear { coordinator.acknowledgeSaveFailure() }"]),
        Host(file: "App/Fernlet/DisposableCameraView.swift",
             keep: "private func keepSelectedSessionPhotos() async",
             presenter: "private func beginDevelop()",
             finish: "await finishDevelopReview(after: answer)",
             releaseFile: "App/Fernlet/DisposableCameraView.swift",
             releases: [".onChange(of: photoSaveError == nil) { _, cleared in if cleared { saveFailureAcknowledgement.acknowledge() } }",
                        "saveFailureAcknowledgement.acknowledge()\n            reviewCoordinator.cameraDevelopReviewUp = false"]),
    ]

    /// Export, then the wait on the acknowledgement, then the leave-and-hide — in that order, in
    /// both hosts; the alert's closing and the review's disappearance both release the wait; and the
    /// function that opens the review clears any earlier failure.
    @Test func theExportFailureIsAcknowledgedBeforeTheReviewLeavesAndHides() throws {
        for host in Self.hosts {
            let source = MeshRoutedSourceScan.codeOnly(try RepoRoot.source(host.file))
            let keep = try #require(MeshRoutedSourceScan.bracedBody(after: host.keep, in: source), "\(host.file): keep action renamed?")
            let export = try #require(keep.range(of: "await exportKeptPhotosIfAsked(answer)"), "\(host.file)")
            let wait = try #require(
                keep.range(of: "if photoSaveError != nil { await saveFailureAcknowledgement.wait() }"),
                "\(host.file): the keep must wait for a failed export's alert to be closed"
            )
            let finish = try #require(keep.range(of: host.finish), "\(host.file)")
            #expect(export.lowerBound < wait.lowerBound && wait.lowerBound < finish.lowerBound,
                    "\(host.file): export, then the acknowledged alert, then the leave and the hide")
            let releaser = MeshRoutedSourceScan.codeOnly(try RepoRoot.source(host.releaseFile))
            for needle in host.releases {
                #expect(releaser.contains(needle), "\(host.releaseFile): the alert closing, or the review going, releases the wait")
            }
            let opener = try #require(MeshRoutedSourceScan.bracedBody(after: host.presenter, in: source), "\(host.file)")
            #expect(opener.contains("photoSaveError = nil"),
                    "\(host.file): a failure from an earlier review never opens this one")
        }
        let coordinator = MeshRoutedSourceScan.codeOnly(try RepoRoot.source("App/Fernlet/SessionPhotoReviewCoordinator.swift"))
        let acknowledge = try #require(MeshRoutedSourceScan.bracedBody(after: "func acknowledgeSaveFailure()", in: coordinator))
        #expect(acknowledge.contains("saveFailureAcknowledgement.acknowledge()"), "the screen's release reaches the wait")
    }

    /// **U3-C-U3-R1.** Each host's acknowledgement is open exactly while its review is, so no wait
    /// can outlive the alert it waits for: the overlay's opens in `present()` and closes in both
    /// hides; the Develop review's follows the coordinator's Develop flag (whose three clears end its
    /// wait) and lives on the store-owned coordinator — the camera constructs none in its `@State`,
    /// where a termination that tears the camera down would leave a running answer unreachable. And
    /// the sheet cannot be swiped away mid-answer, taking the alert with it.
    @Test func eachAcknowledgementIsOpenExactlyWhileItsReviewIs() throws {
        let coordinator = MeshRoutedSourceScan.codeOnly(try RepoRoot.source("App/Fernlet/SessionPhotoReviewCoordinator.swift"))
        let present = try #require(MeshRoutedSourceScan.bracedBody(after: "private func present()", in: coordinator))
        #expect(present.contains("saveFailureAcknowledgement.reviewDidOpen()"), "the overlay's opens with its review")
        for hide in ["private func hide()", "private func hideWithoutAnswer()"] {
            let body = try #require(MeshRoutedSourceScan.bracedBody(after: hide, in: coordinator), "\(hide) is gone")
            #expect(body.contains("saveFailureAcknowledgement.reviewDidClose()"), "\(hide) closes it")
        }
        let flag = try #require(MeshRoutedSourceScan.bracedBody(after: "var cameraDevelopReviewUp = false", in: coordinator))
        #expect(flag.contains("developSaveFailureAcknowledgement.reviewDidOpen()")
                && flag.contains("developSaveFailureAcknowledgement.reviewDidClose()"),
                "the Develop review's follows the Develop flag")
        let camera = MeshRoutedSourceScan.codeOnly(try RepoRoot.source("App/Fernlet/DisposableCameraView.swift"))
        #expect(!camera.contains("PhotoSaveFailureAcknowledgement("), "the camera constructs no acknowledgement of its own")
        #expect(camera.contains("reviewCoordinator.developSaveFailureAcknowledgement"), "it waits on the coordinator's")
        let sheet = MeshRoutedSourceScan.codeOnly(
            try RepoRoot.source("FernletKit/Sources/ProximityKit/UI/FriendPhotoReviewSheet.swift"))
        #expect(sheet.contains(".interactiveDismissDisabled(isBusy)"), "no review is swiped away while its answer runs")
    }
}
