// AIAuditLogScreenTests.swift
// FernletTests
//
// The reader half of the device-local AI audit log (Ladder §7.2): `AIAuditRow`, the row-model
// builder behind the "AI activity log" Settings screen. `AIAuditLogTests` covers the log itself
// (ring buffer, tolerant decode, persistence, delete-all); this file covers what a person is shown.
//
// The load-bearing test here is `parkedDestinationTokenIsShownInsteadOfTheFrozenOnDeviceDefault`.
// The tolerant decode freezes an unknown future destination to `.onDeviceFoundationModels` and an
// unknown outcome to `.succeeded` — the PRIVACY-WORST direction — parking the true token beside it.
// A screen that rendered the frozen enum would tell the user a call that left the device stayed
// home. That is the one lie this log exists to prevent, so it is pinned rather than reviewed.
//
// `@MainActor`: the app target builds with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so its
// types (including `AIAuditRow`) are main-actor isolated.

import Foundation
import SwiftUI
import Testing
import AIContext
import FernletDomainModel
@testable import Fernlet

@MainActor
struct AIAuditLogScreenTests {

    // MARK: - Helpers

    private func entry(
        payloadKind: String = "companion-thought",
        secondsFromEpoch: TimeInterval = 1_800_000_000,
        destination: AIDestination = .onDeviceFoundationModels,
        outcome: AIAuditOutcome = .succeeded,
        includedFields: [String] = ["mood", "sleepHours"],
        destinationParkedToken: String? = nil,
        outcomeParkedToken: String? = nil
    ) -> AIAuditEntry {
        AIAuditEntry(
            timestamp: Date(timeIntervalSince1970: secondsFromEpoch),
            payloadKind: payloadKind,
            destination: destination,
            modelIdentifier: AIAuditEntry.onDeviceFoundationModel,
            outcome: outcome,
            includedFields: includedFields,
            destinationParkedToken: destinationParkedToken,
            outcomeParkedToken: outcomeParkedToken
        )
    }

    /// The raw token a display value carries, or nil when it resolved to plain language.
    private func recordedToken(_ value: AIAuditDisplayValue) -> String? {
        if case .recorded(let token) = value { return token }
        return nil
    }

    // MARK: - The parked-token contract

    @Test func parkedDestinationTokenIsShownInsteadOfTheFrozenOnDeviceDefault() throws {
        // An entry written by a NEWER build, decoded by THIS one exactly as the log would decode it
        // off disk: the destination freezes to the on-device floor and the true token parks.
        let json = """
        {"id":"44444444-4444-4444-4444-444444444444",
         "timestamp":"2026-08-20T00:00:00Z",
         "payloadKind":"companion-thought",
         "destination":"quantumRelay2099",
         "outcome":"succeeded",
         "includedFields":["mood"],
         "memorySummaryCharCount":0}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(AIAuditEntry.self, from: Data(json.utf8))
        // Precondition: the freeze really did read in the privacy-worst direction.
        #expect(decoded.destination == .onDeviceFoundationModels)
        #expect(decoded.destinationParkedToken == "quantumRelay2099")

        let row = try #require(AIAuditRow.rows(from: [decoded]).first)
        #expect(recordedToken(row.destination) == "quantumRelay2099",
                "the screen rendered the frozen enum instead of the parked token")
        #expect(row.destination != .known("On-device model"),
                "an unknown future destination must never render as on-device")
        // And it must not inherit the floor's "nothing left the device" claim either.
        #expect(row.boundary == .unknown)
        #expect(row.showsRecordedToken)
    }

    @Test func parkedOutcomeTokenIsShownInsteadOfTheFrozenSucceededDefault() throws {
        let entries = [entry(outcome: .succeeded, outcomeParkedToken: "partiallyRefused")]
        let row = try #require(AIAuditRow.rows(from: entries).first)
        #expect(recordedToken(row.outcome) == "partiallyRefused")
        #expect(row.outcome != .known("Completed"),
                "an unknown future outcome must never render as a clean success")
        #expect(row.showsRecordedToken)
    }

    @Test func aKnownDestinationStillRendersPlainLanguageAndItsBoundary() throws {
        let onDevice = try #require(AIAuditRow.rows(from: [entry()]).first)
        #expect(onDevice.destination == .known("On-device model"))
        #expect(onDevice.boundary == .stayedOnDevice)
        #expect(onDevice.showsRecordedToken == false)

        let webEntries = [entry(payloadKind: "web-nutrition", destination: .webNutritionLookup)]
        let web = try #require(AIAuditRow.rows(from: webEntries).first)
        #expect(web.destination == .known("Web nutrition search"))
        #expect(web.boundary == .leftDevice, "an egressing rung must not read as on-device")
    }

    // MARK: - Ordering

    @Test func rowsAreNewestFirst() throws {
        // Fed in the log's own oldest-first order, plus one out-of-order arrival.
        let entries = [
            entry(payloadKind: "food-selection", secondsFromEpoch: 1_000),
            entry(payloadKind: "day-summary", secondsFromEpoch: 3_000),
            entry(payloadKind: "workout-adjustment", secondsFromEpoch: 2_000)
        ]
        let rows = AIAuditRow.rows(from: entries)
        #expect(rows.map(\.timestamp) == [
            Date(timeIntervalSince1970: 3_000),
            Date(timeIntervalSince1970: 2_000),
            Date(timeIntervalSince1970: 1_000)
        ])
        let newest = try #require(rows.first)
        #expect(newest.kind == .known("Day summary"))
    }

    @Test func callsRecordedInTheSameInstantKeepTheirRecordedOrder() {
        // Same timestamp on every entry: the tie-break must be deterministic (newest recorded first),
        // not whatever an unstable sort happens to produce.
        let entries = (0..<4).map { entry(payloadKind: "kind-\($0)", secondsFromEpoch: 500) }
        let kinds = AIAuditRow.rows(from: entries).map { recordedToken($0.kind) }
        #expect(kinds == ["kind-3", "kind-2", "kind-1", "kind-0"])
    }

    // MARK: - Outcomes, including the failure states

    @Test func outcomesRenderIncludingFailures() throws {
        let expected: [(AIAuditOutcome, AIAuditDisplayValue)] = [
            (.succeeded, .known("Completed")),
            (.fellBack, .known("No usable answer — Fernlet used its own logic")),
            (.refused, .known("Declined by the model")),
            (.schemaFailed, .known("Unusable answer — discarded"))
        ]
        for (outcome, display) in expected {
            let row = try #require(AIAuditRow.rows(from: [entry(outcome: outcome)]).first)
            #expect(row.outcome == display, "outcome \(outcome.rawValue) rendered as something else")
            // A failure must never be mistaken for a parked token (which carries a different note).
            #expect(row.showsRecordedToken == false)
        }
    }

    // MARK: - Kinds and fields

    @Test func unknownPayloadKindRendersVerbatimAndAnEmptyOneSaysSo() throws {
        let future = try #require(AIAuditRow.rows(from: [entry(payloadKind: "telepathy-2099")]).first)
        #expect(recordedToken(future.kind) == "telepathy-2099")
        #expect(future.showsRecordedToken)
        // `payloadKind` decodes to "" for a malformed entry; an empty headline would read as broken.
        let blank = try #require(AIAuditRow.rows(from: [entry(payloadKind: "")]).first)
        #expect(blank.kind == .known("Not recorded"))
    }

    @Test func includedFieldNamesArePassedThroughUnchanged() throws {
        // Names only — the log has never held a value, so the row has nothing else to carry.
        let entries = [entry(includedFields: ["sourceHost", "cleanedTextCharCount"])]
        let row = try #require(AIAuditRow.rows(from: entries).first)
        #expect(row.includedFields == ["sourceHost", "cleanedTextCharCount"])
    }

    // MARK: - Empty state

    @Test func noEntriesProducesNoRows() {
        // The screen's quiet "No AI calls have been made from this device." line hangs off this.
        #expect(AIAuditRow.rows(from: []).isEmpty)
    }

    // MARK: - Settings wiring

    @Test func theScreenIsReachableFromSettingsSearch() {
        let results = SettingsSearchIndex.results(for: "audit")
        #expect(results.contains { $0.route == .aiAuditLog })
        #expect(SettingsSearchIndex.results(for: "what left my device").contains { $0.route == .aiAuditLog })
    }
}
