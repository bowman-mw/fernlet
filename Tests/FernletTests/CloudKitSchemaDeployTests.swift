import Foundation
import Testing
import CloudKitSync

/// STEP 0c — the CloudKit schema-deploy launch-argument seam.
///
/// The actual `initializeCloudKitSchema` push can't run against real CloudKit in a unit test,
/// so these pin the only pure, testable part: the launch-argument parsing that decides whether a
/// deploy was requested. The push itself is gated by `#if DEBUG` in `PersistenceController`, so it
/// cannot be reached in a Release build — see Docs/CloudKit-Schema-Deploy.md.
struct CloudKitSchemaDeployTests {

    @Test func requestedWhenArgumentPresent() {
        #expect(CloudKitSchemaDeploy.isRequested(arguments: ["/path/to/Fernlet", "INITIALIZE_CLOUDKIT_SCHEMA"]))
    }

    @Test func requestedWhenArgumentIsOnlyEntry() {
        #expect(CloudKitSchemaDeploy.isRequested(arguments: ["INITIALIZE_CLOUDKIT_SCHEMA"]))
    }

    @Test func notRequestedWhenArgumentAbsent() {
        #expect(!CloudKitSchemaDeploy.isRequested(arguments: ["/path/to/Fernlet", "-completeOnboarding"]))
    }

    @Test func notRequestedForEmptyArguments() {
        #expect(!CloudKitSchemaDeploy.isRequested(arguments: []))
    }

    @Test func matchIsExactNotSubstring() {
        // A leading dash or different casing must NOT trigger the deploy — the flag is matched
        // exactly, so a typo silently no-ops rather than pushing a schema by accident.
        #expect(!CloudKitSchemaDeploy.isRequested(arguments: ["-INITIALIZE_CLOUDKIT_SCHEMA"]))
        #expect(!CloudKitSchemaDeploy.isRequested(arguments: ["initialize_cloudkit_schema"]))
        #expect(!CloudKitSchemaDeploy.isRequested(arguments: ["INITIALIZE_CLOUDKIT_SCHEMA_NOW"]))
    }

    @Test func launchArgumentTokenIsStable() {
        // The doc and the Xcode scheme reference this literal; guard against an accidental rename.
        #expect(CloudKitSchemaDeploy.launchArgument == "INITIALIZE_CLOUDKIT_SCHEMA")
    }
}

// MARK: - G9-2: the recovery-escrow record type is in the deploy ledger

extension CloudKitSchemaDeployTests {
    /// `RecoveryEscrowRecord` is hand-rolled, so Production gets it only when the owner promotes it;
    /// the ledger names the type and every field the decoder requires, so the promotion is complete.
    @Test func theRecoveryEscrowRecordTypeIsInTheDeployLedger() throws {
        let doc = try String(contentsOf: RepoRoot.url.appendingPathComponent("Docs/CloudKit-Schema-Deploy.md"), encoding: .utf8)
        let row = try #require(doc.split(separator: "\n").first { $0.hasPrefix("| `RecoveryEscrowRecord`") })
        for field in ["recoveryPublicKey", "escrowPublicKeyHash", "encapsulatedKey", "ciphertext", "codeMadeAt", "formatVersion"] {
            #expect(row.contains("`\(field)`"), "the ledger row must name \(field)")
        }
        #expect(row.contains("queryable"))
    }
}
