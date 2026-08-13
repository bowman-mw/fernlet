// PendingNarrativeStorageScope.swift
// Fernlet
//
// The on-disk + keychain identity of one PendingNarrativeBuffer, carried as a single value so the
// two halves can never be isolated independently.

import Foundation

/// The storage identity of one ``PendingNarrativeBuffer``: the directory holding its sealed file
/// AND the keychain service holding the key that seals it, as one inseparable value.
///
/// One value rather than two parameters, for the reason `HeartDropStorageScope` established: the
/// buffer is sealed, so isolating only the file path is strictly worse than isolating nothing —
/// a buffer given a private directory but the shared key service still loses its key to whatever
/// sweeps that service, and its file then survives as ciphertext nothing can open (every
/// `append`/`drainAll` throws until a `purge`). Whoever scopes the file scopes the key with it.
///
/// Unit tests are why this exists at all: XCTest and Swift Testing suites run in parallel inside
/// one process, `FernletLockService.reset()` purges the buffer file, and on a process-wide
/// identity any resetting test destroys the buffered notes of every concurrently-running one.
/// Production always uses ``production``; tests build a throwaway scope per test
/// (`uniqueNarrativeBufferScope()` in the test helpers).
public nonisolated struct PendingNarrativeStorageScope: Sendable, Equatable {
    /// Directory holding the sealed `pending-narratives.bin` buffer file.
    public let directory: URL
    /// Keychain service holding the 256-bit buffer key (accounts `com.fernlet.buffer.key.v2`,
    /// plus the legacy service-less `com.fernlet.buffer.key` it was migrated from).
    public let keychainService: String

    /// Creates a scope from its two halves. Test-only in spirit — production code should reach
    /// for ``production`` so the shipped identity has exactly one spelling.
    public init(directory: URL, keychainService: String) {
        self.directory = directory
        self.keychainService = keychainService
    }

    /// The shipped keychain service, `com.fernlet.narrative-buffer` — named so the legacy-key
    /// migration in ``PendingNarrativeBuffer`` can recognize the production scope (the legacy
    /// service-less row is production's migration source; a scoped test buffer must never consume
    /// it). Documented in `Docs/PrivacyWipeCoverage.md` as a deliberate delete-all survivor.
    public static let productionKeychainService = "com.fernlet.narrative-buffer"

    /// The shipped scope: `Application Support/Fernlet` + `com.fernlet.narrative-buffer`, i.e.
    /// exactly the path and service the buffer has always used. Nothing installed is migrated by
    /// the seam that made this injectable.
    public static var production: PendingNarrativeStorageScope {
        PendingNarrativeStorageScope(
            directory: FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first!
                .appendingPathComponent("Fernlet", isDirectory: true),
            keychainService: productionKeychainService
        )
    }
}
