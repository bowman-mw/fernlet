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

import Foundation
import Testing
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

    /// The answer stays suspended until the alert is closed, and resumes exactly then.
    @Test func anAnswerWaitsUntilTheAlertIsClosed() async {
        let acknowledgement = PhotoSaveFailureAcknowledgement()
        let waiter = await Self.suspendedWaiter(on: acknowledgement)
        #expect(acknowledgement.isWaiting, "the answer is suspended while the failure is on screen")

        acknowledgement.acknowledge()

        #expect(await waiter.value, "closing the alert resumes it")
        #expect(!acknowledgement.isWaiting)
    }

    /// Acknowledging with nobody waiting — the alert closing after the sheet already went, or the
    /// sheet's disappearance after the alert already closed — does nothing, any number of times.
    @Test func anAcknowledgementWithNobodyWaitingIsHarmless() async {
        let acknowledgement = PhotoSaveFailureAcknowledgement()
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
        let acknowledgement = PhotoSaveFailureAcknowledgement()
        let first = await Self.suspendedWaiter(on: acknowledgement)

        await acknowledgement.wait()   // returns at once

        #expect(acknowledgement.isWaiting, "the first answer is still the one waiting")
        acknowledgement.acknowledge()
        #expect(await first.value)
    }
}

/// Both review hosts show a failed export inside the review and wait for it to be closed before they
/// leave and hide, and neither opens a review with an earlier review's failure.
@MainActor
struct ReviewHostsExportFailureSourceWallTests {

    /// One host's shape: its keep action, the function that opens its review, and that function's
    /// signature as the scan finds it.
    private struct Host {
        let file: String
        let presenter: String
        let finish: String
    }

    private static let hosts = [
        Host(file: "App/Fernlet/ConnectView.swift",
             presenter: "private func presentDisconnectReviewIfNeeded()",
             finish: "await finishPhotoReview(after: answer, leaving: leaving)"),
        Host(file: "App/Fernlet/DisposableCameraView.swift",
             presenter: "private func beginDevelop()",
             finish: "await finishDevelopReview(after: answer)")
    ]

    /// Export, then the wait on the acknowledgement, then the leave-and-hide — in that order, in
    /// both hosts; the alert's closing and the sheet's disappearance both release the wait; and the
    /// function that opens the review clears any earlier failure.
    @Test func theExportFailureIsAcknowledgedBeforeTheReviewLeavesAndHides() throws {
        for host in Self.hosts {
            let source = MeshRoutedSourceScan.codeOnly(try RepoRoot.source(host.file))
            let keep = try #require(MeshRoutedSourceScan.bracedBody(
                after: "private func keepSelectedSessionPhotos() async", in: source), "\(host.file): keep action renamed?")
            let export = try #require(keep.range(of: "await exportKeptPhotosIfAsked(answer)"), "\(host.file)")
            let wait = try #require(
                keep.range(of: "if photoSaveError != nil { await saveFailureAcknowledgement.wait() }"),
                "\(host.file): the keep must wait for a failed export's alert to be closed"
            )
            let finish = try #require(keep.range(of: host.finish), "\(host.file)")
            #expect(export.lowerBound < wait.lowerBound && wait.lowerBound < finish.lowerBound,
                    "\(host.file): export, then the acknowledged alert, then the leave and the hide")
            #expect(source.contains(
                ".onChange(of: photoSaveError == nil) { _, cleared in if cleared { saveFailureAcknowledgement.acknowledge() } }"),
                "\(host.file): the alert closing releases the wait")
            #expect(source.contains(".onDisappear { saveFailureAcknowledgement.acknowledge() }"),
                    "\(host.file): a torn-down sheet never strands the answer")
            let opener = try #require(MeshRoutedSourceScan.bracedBody(after: host.presenter, in: source), "\(host.file)")
            #expect(opener.contains("photoSaveError = nil"),
                    "\(host.file): a failure from an earlier review never opens this one")
        }
    }
}
