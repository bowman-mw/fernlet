// MeshStorageScopes+HeartDrop.swift
// FernletSocial/HeartSharing
//
// The keychain services of ProximityKit's two sealed mesh stores, derived beside a store's heart-drop
// keychain service. ProximityKit's scopes name their production service off the host's namespace
// (`production(for:installBinding:)`) and take any other service a host hands them; Fernlet's app
// isolates a test store's mesh keys by deriving each service from the heart-drop service the store
// already isolates, and that derivation compares against the dead-drop's production service, which
// is this module's (`HeartPrekeyStore.keychainService`), so it lives here, beside it.
// `MeshSessionStoreIsolationTests` and `MeshRoutedStoreIsolationTests` pin the app's use of it and
// its behaviour, and `FernletFeatureGoldenTests` its known answers.

import ProximityKit

nonisolated extension MeshSessionStorageScope {

    /// The mesh-session keychain service that belongs beside a given heart-drop service.
    ///
    /// The app derives its scope this way rather than carrying a fourth injectable seam, and that
    /// is a deliberate reuse of an isolation axis the test walls ALREADY enforce: every test file
    /// that reaches `deleteAllData` and builds a `FernletStore` directly is already required to
    /// pass `heartDropKeychainService:` (`PhotoDirectoryIsolationTests`), so a store isolated for
    /// hearts is isolated for mesh-session state for free — and one that is not fails an existing
    /// wall rather than silently sharing this key.
    ///
    /// - Parameters:
    ///   - heartDropService: The store's heart-drop keychain service.
    ///   - namespace: The host's protocol identity, whose production seal-key service the
    ///     production heart-drop service maps to.
    /// - Returns: The namespace's `installation.keychain.meshSessionSealKey.service` when the input
    ///   is the production heart-drop service; a distinct sibling of the caller's isolated service
    ///   otherwise.
    public static func keychainService(
        besideHeartDrop heartDropService: String,
        in namespace: ProximityNamespace
    ) -> String {
        heartDropService == HeartPrekeyStore.keychainService
            ? namespace.installation.keychain.meshSessionSealKey.service
            : heartDropService + ".mesh-session"
    }
}

nonisolated extension MeshRoutedStorageScope {

    /// The routed-store keychain service that belongs beside a given heart-drop service.
    ///
    /// The app derives its scope this way rather than carrying a fourth injectable seam, and that
    /// is a deliberate reuse of an isolation axis the test walls ALREADY enforce: every test file
    /// that reaches `deleteAllData` and builds a `FernletStore` directly is already required to
    /// pass `heartDropKeychainService:` (`PhotoDirectoryIsolationTests`), so a store isolated for
    /// hearts is isolated for routed custody for free — and one that is not fails an existing wall
    /// rather than silently sharing this key.
    ///
    /// - Parameters:
    ///   - heartDropService: The store's heart-drop keychain service.
    ///   - namespace: The host's protocol identity, whose production seal-key service the
    ///     production heart-drop service maps to.
    /// - Returns: The namespace's `installation.keychain.meshRoutedSealKey.service` when the input is
    ///   the production heart-drop service; a distinct sibling of the caller's isolated service
    ///   otherwise.
    public static func keychainService(
        besideHeartDrop heartDropService: String,
        in namespace: ProximityNamespace
    ) -> String {
        heartDropService == HeartPrekeyStore.keychainService
            ? namespace.installation.keychain.meshRoutedSealKey.service
            : heartDropService + ".mesh-routed"
    }
}
