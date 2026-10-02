// ProximityNamespaceTestBindings.swift
// FernletTests
//
// ProximityKit plan step A0.2.3 (Docs/Plan-FernletCoach-ProximityKit-2026-10-01.md §4 A0.2): the one
// place the test target gets back the call shapes A0.2 takes out of ProximityKit. ProximityKit offers
// no namespace default, so every API that used to spell Fernlet's bytes for itself now takes the
// host's `ProximityNamespace`. The suites were written against the old shapes; rather than rewrite
// every construction in every suite, each old shape comes back here once, passing Fernlet's value.
//
// THE RULE. A binding restores a call SHAPE, never a value: it passes `ProximityNamespace.fernlet`,
// exactly the value FernletConnections ships and the app hands ProximityKit, so a suite that goes
// through one sees the bytes it always saw, and nothing here may pass anything else or compute a
// label, a row or a name of its own. A test that PINS a value does not lean on a binding: it names
// `.fernlet` explicitly (`IdentityService(namespace: .fernlet)`), so what it pins is visibly
// Fernlet's and still reads correctly once a binding is retired. Later A0.2 commits add their
// bindings to this file, each beside the API it restores.

import FernletConnections
import ProximityKit

// MARK: - IdentityService (A0.2.3)

/// The two `IdentityService` initializers the suites were written against, restored over
/// `init(namespace:keychainService:)` with Fernlet's namespace (plan step A0.2.3).
///
/// A binding restores a call shape, never a value; a test that pins a value names `.fernlet`
/// explicitly instead of calling one of these. Both inherit the class's main-actor isolation, as the
/// initializers they replace had.
extension IdentityService {

    /// `IdentityService(namespace: .fernlet)`: this device's identity on Fernlet's identity service,
    /// the identity the retired argument-less initializer built.
    convenience init() {
        self.init(namespace: .fernlet)
    }

    /// `IdentityService(namespace: .fernlet, keychainService:)`: an identity on a keychain service of
    /// the test's own, the identity the retired `init(keychainService:)` built.
    ///
    /// - Parameter keychainService: The test's own service, usually a throwaway one.
    convenience init(keychainService: String) {
        self.init(namespace: .fernlet, keychainService: keychainService)
    }
}
