// DestructiveConfirmationTests.swift
// FernletTests
//
// WS-5 (Docs/Sealed-Backup-Escrow-Recovery-FollowUp-2026-06-28.md): the reusable destructive-action
// confirmation. The core guarantee the type provides is that the mutation is DEFERRED — it lives in
// `perform` and runs only when the caller (the shared `.destructiveConfirmation` modifier) invokes it on
// confirm — so a destructive toggle can't mutate without a warning having been shown first.

import Foundation
import Testing
import FernletFoundation
@testable import Fernlet

@MainActor
struct DestructiveConfirmationTests {

    @Test func mutationIsDeferredUntilPerform() async {
        let serviceID = "com.fernlet.destructive.test.\(UUID().uuidString)"
        defer { KeychainItem.delete(for: .storagePreferences, service: serviceID) }
        let prefs = StoragePreferencesStore(keychainService: serviceID)
        prefs.update { $0.localBackupExcludedFromiOSBackup = false }

        let action = DestructiveConfirmation(
            title: "Exclude Fernlet data from device backups?",
            message: "…",
            confirmLabel: "Exclude",
            auditEvent: "privacy.localBackup.excludeConfirmed"
        ) {
            prefs.update { $0.localBackupExcludedFromiOSBackup = true }
        }

        // Building the action mutates NOTHING — the warning hasn't been confirmed yet.
        #expect(prefs.preferences.localBackupExcludedFromiOSBackup == false)

        // Only invoking perform (what the modifier does on the destructive confirm) commits the change.
        await action.perform()
        #expect(prefs.preferences.localBackupExcludedFromiOSBackup == true)
    }

    @Test func fieldsArePreserved() {
        let action = DestructiveConfirmation(
            title: "Turn off encrypted period backup?",
            message: "This permanently deletes your encrypted period backup from iCloud.",
            confirmLabel: "Turn off",
            auditEvent: "privacy.sealedBackup.periodDisableConfirmed"
        ) {}

        #expect(action.title == "Turn off encrypted period backup?")
        #expect(action.message.contains("permanently deletes"))
        #expect(action.confirmLabel == "Turn off")
        #expect(action.auditEvent == "privacy.sealedBackup.periodDisableConfirmed")
    }

    @Test func auditEventDefaultsToNil() {
        let action = DestructiveConfirmation(title: "t", message: "m", confirmLabel: "c") {}
        #expect(action.auditEvent == nil)
    }
}
