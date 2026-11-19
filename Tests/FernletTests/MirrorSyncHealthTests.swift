import CloudKit
import CoreData
import Foundation
import Testing
@testable import CloudKitSync
import FernletFoundation

/// The mirror's export and import failures, sorted and folded (release review 2026-11-18, F2).
///
/// Before these, nothing observed `NSPersistentCloudKitContainer.eventChangedNotification`, so a
/// Production schema that lacked a field refused every export while the switch read "on". An
/// `NSPersistentCloudKitContainer.Event` cannot be built in a test, so the suite drives the pure
/// classifier and fold, and the controller's `noteMirrorEvent` seam the observer calls.
@MainActor
@Suite(.serialized)
struct MirrorSyncHealthTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func cloud(_ code: CKError.Code, userInfo: [String: Any] = [:]) -> NSError {
        NSError(domain: CKErrorDomain, code: code.rawValue, userInfo: userInfo)
    }

    /// What a Production schema without `CD_deviceKey` answers: a partial failure whose refused
    /// record says "invalid arguments" and whose batch-mates say "batch request failed".
    private func schemaRefusal() -> NSError {
        let zone = CKRecordZone.ID(zoneName: "com.apple.coredata.cloudkit.zone", ownerName: CKCurrentUserDefaultName)
        let perItem: [AnyHashable: any Error] = [
            CKRecord.ID(recordName: "day", zoneID: zone): cloud(.invalidArguments),
            CKRecord.ID(recordName: "blob", zoneID: zone): cloud(.batchRequestFailed)
        ]
        return cloud(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: perItem])
    }

    @Test func transientCloudKitErrorsAreTransient() {
        let codes: [CKError.Code] = [
            .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited, .zoneBusy,
            .notAuthenticated, .accountTemporarilyUnavailable, .operationCancelled, .serverResponseLost,
            .changeTokenExpired, .serverRecordChanged, .batchRequestFailed
        ]
        for code in codes {
            #expect(MirrorSyncErrorClassifier.classify(cloud(code)).kind == .transient, "\(code.rawValue)")
        }
    }

    @Test func aRefusalThatWillRepeatIsLasting() {
        let codes: [CKError.Code] = [
            .invalidArguments, .unknownItem, .serverRejectedRequest, .permissionFailure, .quotaExceeded,
            .badContainer, .missingEntitlement, .constraintViolation
        ]
        for code in codes {
            #expect(MirrorSyncErrorClassifier.classify(cloud(code)).kind == .lasting, "\(code.rawValue)")
        }
    }

    @Test func aPartialFailureIsJudgedByItsRefusedRecord() {
        let verdict = MirrorSyncErrorClassifier.classify(schemaRefusal())
        #expect(verdict.kind == .lasting)
        #expect(verdict.code == "CKErrorDomain.\(CKError.Code.invalidArguments.rawValue)")

        let zone = CKRecordZone.ID(zoneName: "zone", ownerName: CKCurrentUserDefaultName)
        let busy: [AnyHashable: any Error] = [CKRecord.ID(recordName: "a", zoneID: zone): cloud(.zoneBusy)]
        let partial = cloud(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: busy])
        #expect(MirrorSyncErrorClassifier.classify(partial).kind == .transient)
    }

    @Test func aRefusalWrappedByCoreDataIsStillFound() {
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: 134_406, userInfo: [NSUnderlyingErrorKey: schemaRefusal()])
        #expect(MirrorSyncErrorClassifier.classify(wrapped).kind == .lasting)
        // Core Data's own "no account" error holds no CloudKit refusal: nothing to warn about.
        let noAccount = NSError(domain: NSCocoaErrorDomain, code: 134_400)
        let verdict = MirrorSyncErrorClassifier.classify(noAccount)
        #expect(verdict.kind == .transient)
        #expect(verdict.code == "NSCocoaErrorDomain.134400")
    }

    @Test func aLastingExportFailureStandsUntilAnExportSucceeds() {
        var health = MirrorSyncHealth()
        #expect(health.record(.exporting, error: nil, at: now) == .healthy)
        #expect(health.lastingIssue == nil)

        let code = "CKErrorDomain.\(CKError.Code.invalidArguments.rawValue)"
        #expect(health.record(.exporting, error: schemaRefusal(), at: now) == .lastingFailure(code: code))
        #expect(health.lastingIssue == MirrorSyncIssue(activity: .exporting, code: code, since: now))

        // A later refusal keeps the first one's date; a network blip and a clean import clear nothing.
        _ = health.record(.exporting, error: schemaRefusal(), at: now.addingTimeInterval(60))
        _ = health.record(.exporting, error: cloud(.networkUnavailable), at: now.addingTimeInterval(90))
        #expect(health.record(.importing, error: nil, at: now.addingTimeInterval(120)) == .healthy)
        #expect(health.lastingIssue?.since == now)

        #expect(health.record(.exporting, error: nil, at: now.addingTimeInterval(180)) == .recovered)
        #expect(health.lastingIssue == nil)
    }

    @Test func aTransientFailureAloneNeverRaisesAnIssue() {
        var health = MirrorSyncHealth()
        let change = health.record(.exporting, error: cloud(.networkFailure), at: now)
        #expect(change == .transientFailure(code: "CKErrorDomain.\(CKError.Code.networkFailure.rawValue)"))
        #expect(health.lastingIssue == nil)
    }

    @Test func theControllerAuditsAndPublishesARefusedExport() {
        let audit = MirrorAuditCapture()
        audit.install()
        defer { audit.uninstall() }
        let controller = PersistenceController(inMemory: true)
        #expect(controller.mirrorSyncHealth.lastingIssue == nil)

        controller.noteMirrorEvent(.exporting, error: cloud(.networkUnavailable), at: now)
        #expect(controller.mirrorSyncHealth.lastingIssue == nil)
        controller.noteMirrorEvent(.exporting, error: schemaRefusal(), at: now)
        #expect(controller.mirrorSyncHealth.lastingIssue?.activity == .exporting)
        controller.noteMirrorEvent(.exporting, error: nil, at: now)
        #expect(controller.mirrorSyncHealth.lastingIssue == nil)

        let mine = audit.events.filter { $0.event.hasPrefix("cloudkit.mirror.") }
        #expect(mine.map(\.event) == ["cloudkit.mirror.failed", "cloudkit.mirror.failed", "cloudkit.mirror.recovered"])
        #expect(mine.map { $0.context["kind"] } == ["transient", "lasting", nil])
        #expect(mine[1].context["activity"] == "export")
        #expect(mine[1].context["code"] == "CKErrorDomain.\(CKError.Code.invalidArguments.rawValue)")
    }

    @Test func aStandingRefusalShowsWhereThePageSaidNothing() {
        #expect(MultiDeviceSyncWarning.classify(
            iCloudAccountPresent: true, syncEnabled: true, otherDeviceHasData: true, iCloudRefusedChanges: true
        ) == .iCloudRefusedChanges)
        #expect(MultiDeviceSyncWarning.classify(
            iCloudAccountPresent: true, syncEnabled: true, otherDeviceHasData: false, iCloudRefusedChanges: false
        ) == nil)
        // With sync off or no account the older, more specific warnings still win.
        #expect(MultiDeviceSyncWarning.classify(
            iCloudAccountPresent: true, syncEnabled: false, otherDeviceHasData: false, iCloudRefusedChanges: true
        ) == .syncOffWithAccount)
        #expect(MultiDeviceSyncWarning.classify(
            iCloudAccountPresent: false, syncEnabled: true, otherDeviceHasData: false, iCloudRefusedChanges: true
        ) == .syncOnWithoutAccount)
        #expect(!MultiDeviceSyncWarning.iCloudRefusedChanges.message.isEmpty)
    }
}

/// Collects audit events for one test.
private final class MirrorAuditCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [(event: String, context: [String: String])] = []
    private var token: UUID?

    var events: [(event: String, context: [String: String])] {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    func install() {
        token = FernletAuditLog.addCaptureHandler { [weak self] event, context in
            guard let self else { return }
            self.lock.lock()
            self.stored.append((event, context))
            self.lock.unlock()
        }
    }

    func uninstall() {
        if let token { FernletAuditLog.removeCaptureHandler(token) }
        token = nil
    }
}
