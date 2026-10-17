//
//  IntimacyHealthWriteTests.swift
//  FernletTests
//
//  The Health half of an intimacy save (`IntimacyHealthWrite`, used by `LogIntimacySheet`): the sample
//  write and the local link mark are judged separately, so a sample that landed is never reported as
//  "Apple Health was not updated" when only the link mark failed (2026-10-17 anomaly re-triage).
//

import Foundation
import Testing
@testable import Fernlet

@MainActor
struct IntimacyHealthWriteTests {

    /// A stand-in failure with a readable description.
    private struct Refused: LocalizedError {
        let errorDescription: String?
    }

    /// Both halves land: no caveat, so the sheet dismisses.
    @Test func bothHalvesLandingLeavesNoCaveat() async {
        var linked = false
        let outcome = await IntimacyHealthWrite.run(save: {}, link: { linked = true })
        #expect(outcome == .saved)
        #expect(outcome.caveat == nil)
        #expect(linked)
    }

    /// The sample fails: Apple Health was not updated, the reason is carried, and the link mark never
    /// runs (there is no sample to link to).
    @Test func aFailedSampleSaysHealthWasNotUpdatedAndNeverLinks() async {
        var linkAttempted = false
        let outcome = await IntimacyHealthWrite.run(
            save: { throw Refused(errorDescription: "Sharing is off.") },
            link: { linkAttempted = true }
        )
        #expect(outcome == .healthNotUpdated(reason: "Sharing is off."))
        #expect(outcome.caveat?.contains("Apple Health was not updated") == true)
        #expect(!linkAttempted)
    }

    /// The defect: the sample lands, then the link mark throws. That used to read as "Apple Health was
    /// not updated", which was false. Now it is its own outcome, and its sentence says Health has it.
    @Test func aLandedSampleWhoseLinkFailsIsNotReportedAsAHealthFailure() async throws {
        var sampleWritten = false
        let outcome = await IntimacyHealthWrite.run(
            save: { sampleWritten = true },
            link: { throw Refused(errorDescription: "The store refused the write.") }
        )
        #expect(sampleWritten)
        #expect(outcome == .savedButUnlinked)
        let caveat = try #require(outcome.caveat)
        #expect(!caveat.contains("was not updated"), "a landed sample was reported as a Health failure")
        #expect(caveat.contains("sent to Apple Health"))
    }
}
