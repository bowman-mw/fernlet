// FernletAppTestBindings.swift
// FernletTests
//
// ProximityKit plan step A0.4 (Docs/Plan-FernletCoach-ProximityKit-2026-10-01.md §4 A0.4): the one
// place the test target gets back the call shapes that need the app's own types to restore. Fernlet's
// sealed-backup escrow is the app's (`SealedBackupEscrowKey`, the identity's provisioning participant),
// so the identity the suites were written against, Fernlet's identity with its escrow, is built here,
// and `ProximityNamespaceTestBindings.swift` keeps ProximityKit's shapes alone and never imports the
// app.
//
// THE RULE, the same one that file states. A binding restores a call SHAPE, never a value: it passes
// `ProximityNamespace.fernlet`, exactly the value FernletConnections ships and the app hands
// ProximityKit, and Fernlet's custody, a fresh `SealedBackupEscrowKey`, exactly what every identity the
// app builds carries (`IdentityService.fernletApp(keychainService:)`), so a suite that goes through one
// sees the bytes and the escrow it always saw, and nothing here may pass anything else or compute a
// label, a row or a name of its own. A test that PINS a value does not lean on a binding: it names
// `.fernlet` explicitly, or the app's factory, so what it pins is visibly Fernlet's.

import FernletConnections
import ProximityKit
@testable import Fernlet

// MARK: - IdentityService (A0.2.3, with the escrow since A0.4)

/// The two `IdentityService` initializers the suites were written against, restored over
/// `init(namespace:keychainService:provisioningParticipant:)` with Fernlet's namespace and Fernlet's
/// custody (plan steps A0.2.3 and A0.4).
///
/// A binding restores a call shape, never a value; a test that pins a value names `.fernlet` or the
/// app's factory explicitly instead of calling one of these. Both inherit the class's main-actor
/// isolation, as the initializers they replace had.
extension IdentityService {

    /// `IdentityService(namespace: .fernlet, provisioningParticipant: SealedBackupEscrowKey())`: this
    /// device's identity on Fernlet's identity service with its sealed-backup escrow, the identity the
    /// retired argument-less initializer built.
    convenience init() {
        self.init(namespace: .fernlet, provisioningParticipant: SealedBackupEscrowKey())
    }

    /// `IdentityService(namespace: .fernlet, keychainService:, provisioningParticipant:
    /// SealedBackupEscrowKey())`: an identity on a keychain service of the test's own with its
    /// sealed-backup escrow, the identity the retired `init(keychainService:)` built.
    ///
    /// - Parameter keychainService: The test's own service, usually a throwaway one.
    convenience init(keychainService: String) {
        self.init(namespace: .fernlet, keychainService: keychainService,
                  provisioningParticipant: SealedBackupEscrowKey())
    }
}
