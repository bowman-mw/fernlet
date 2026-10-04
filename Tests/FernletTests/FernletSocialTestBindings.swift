// FernletSocialTestBindings.swift
// FernletTests
//
// ProximityKit plan step A0.4 (Docs/Plan-FernletCoach-ProximityKit-2026-10-01.md §4 A0.4): the one
// place the test target gets back the call shapes of the types that left ProximityKit for
// FernletSocial. Those types kept their names and their APIs when they moved, but an old shape the
// suites were written against, restored for them while the type was still ProximityKit's, follows
// the type here, so `ProximityNamespaceTestBindings.swift` keeps ProximityKit's shapes alone and
// never imports FernletSocial.
//
// THE RULE, the same one that file states. A binding restores a call SHAPE, never a value: it passes
// `ProximityNamespace.fernlet`, exactly the value FernletConnections ships and the app hands
// ProximityKit, so a suite that goes through one sees the bytes it always saw, and nothing here may
// pass anything else or compute a label, a row or a name of its own. A test that PINS a value does
// not lean on a binding: it names `.fernlet` explicitly, so what it pins is visibly Fernlet's.

import FernletConnections
@testable import FernletSocial

// MARK: - Presentation strings (A0.3.2)
//
// The hearts copy's first name takes the namespace whose mesh instance-name prefix it hides, last;
// its old shape comes back here with `.fernlet`.

/// The hearts copy's first name in the shape the suites were written against (plan step A0.3.2).
extension PresenceManager {

    /// `firstName(of:in: .fernlet)`. `nonisolated`, as the function it restores is.
    nonisolated static func firstName(of displayName: String) -> String {
        firstName(of: displayName, in: .fernlet)
    }
}
