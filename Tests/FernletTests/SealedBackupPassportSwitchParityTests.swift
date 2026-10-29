import Foundation
import Testing
import CloudKitSync
import FernletFoundation
@testable import Fernlet

/// The passport's Sealed backup switch behaves exactly like the journal's (owner, 2026-10-29): it shows or
/// hides wherever the journal's does, a decoy shows neither one's status rows, and both rows follow the
/// same states. A decoy never backs anything up (`SealedBackupWorldPassportTests` holds the export half).
@MainActor
struct SealedBackupPassportSwitchParityTests {
    /// Both payloads' switches on, with sync.
    nonisolated static let bothOn = StoragePreferences(
        iCloudSyncEnabled: true, sealedBackupJournalEnabled: true, sealedBackupPassportEnabled: true
    )

    /// The two row states move together: waiting while unresolved, nothing in a decoy, catch-up once
    /// resolved with an upload owed.
    @Test func theRowStatesMoveTogetherAndADecoyShowsNeither() {
        let store = makeTestStore()
        store.sealedBackupRestoreHold = SealedBackupRestoreHold(
            defaults: UserDefaults(suiteName: "fernlet.tests.passportParityHold.\(UUID().uuidString)") ?? .standard
        )
        store.sealedBackupBookkeeping = SealedBackupBookkeeping(
            defaults: UserDefaults(suiteName: "fernlet.tests.passportParity.\(UUID().uuidString)") ?? .standard,
            legacyLatch: { _ in false }
        )
        store.sealedBackupPreferencesProvider = { Self.bothOn }
        #expect(store.journalBackupRowState == .waitingForRestore)
        #expect(store.passportBackupRowState == store.journalBackupRowState, "unresolved: both wait")
        store.duressSessionActive = true
        #expect(store.journalBackupRowState == .none && store.passportBackupRowState == .none, "a decoy shows neither")
        store.duressSessionActive = false
        for payload in [SealedBackupPayloadType.journalNarratives, .worldPassport] {
            store.sealedBackupBookkeeping.markRestoreResolved(payload)
            store.recordSealedBackupReuploadDeferred(true, payloadType: payload)
        }
        #expect(store.journalBackupRowState == .catchUp)
        #expect(store.passportBackupRowState == store.journalBackupRowState, "resolved and owed: both catch up")
    }

    /// The two switches sit together in Privacy & data under the same conditions: the passport's toggle
    /// follows the journal's directly (comments only between them), so it shows or hides wherever the
    /// journal's does, decoy or not.
    @Test func thePassportSwitchSitsBesideTheJournalsUnderTheSameConditions() throws {
        let source = try RepoRoot.source("App/Fernlet/PrivacyDataSettingsView.swift")
        let lines = source.components(separatedBy: "\n")
        let journal = try #require(lines.firstIndex { $0.contains("Toggle(\"Sealed backup for journal entries\"") })
        let passport = try #require(lines.firstIndex { $0.contains("Toggle(isOn: sealedPassportBinding)") })
        #expect(passport > journal)
        let between = lines[(journal + 1)..<passport].map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(between.allSatisfy { $0.isEmpty || $0.hasPrefix("//") }, "nothing but comments between the two")
        let indent = { (line: String) in line.prefix { $0 == " " }.count }
        #expect(indent(lines[journal]) == indent(lines[passport]), "the same nesting, so the same conditions")
    }
}
