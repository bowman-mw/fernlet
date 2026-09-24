// StoreLocalDefaults.swift
// CloudKitSync
//
// The device-local, never-synced key/value surface a synced store keeps its own small bookkeeping
// in — today, the two append-only ledgers' PENDING RESET BOUNDARIES (tracker §3.6, 2026-09-24).
//
// Why it hangs off `PersistenceController` rather than being `UserDefaults.standard` everywhere:
// the bookkeeping has to be scoped EXACTLY like the store it describes. Under the test runner every
// suite shares one process, and a boundary written by one test store's "Delete everything" and read
// by another's load would void that store's coins — the shared-disk-root flake family, arriving by a
// new route. So the default on-disk store (the one the app runs on) gets `UserDefaults.standard`,
// where the persisted-surface discovery wall can see its literal keys, and every in-memory or
// explicit-URL controller — previews and tests — gets a private in-memory stand-in whose lifetime is
// the controller's. Two repositories over ONE controller share it, which is exactly how a test
// simulates "the process died and relaunched over the same store".

import Foundation
import os
import FernletFoundation

/// The device-local, never-synced key/value surface a synced store keeps its own bookkeeping in,
/// scoped exactly like the store (see the file header).
///
/// Exactly `UserDefaults`' own three accessors, so the default store's surface can simply BE
/// `UserDefaults.standard`. Callers pass their key as a LITERAL at the call site (the
/// persisted-surface discovery wall's house rule: no generic defaults setter), and every key
/// written through it carries a disposition row in `PersistedSurfaceWipeBoundaryTests`.
public nonisolated protocol StoreLocalDefaults: AnyObject {
    /// The data stored under `defaultName`, or nil.
    func data(forKey defaultName: String) -> Data?
    /// Stores `value` under `defaultName` (the in-memory stand-in keeps `Data` only — the one type
    /// any caller writes).
    func set(_ value: Any?, forKey defaultName: String)
    /// Removes whatever is stored under `defaultName`.
    func removeObject(forKey defaultName: String)
}

/// The per-controller stand-in for `UserDefaults` that every in-memory or explicit-URL
/// ``PersistenceController`` carries, so a preview or test store never writes production defaults
/// and never reads another store's bookkeeping.
///
/// Lives exactly as long as its controller. The one lock-guarded dictionary is the whole state, and
/// the lock and the state are one immutable `let`, so the type is `Sendable` without an unchecked
/// annotation.
public nonisolated final class InMemoryStoreLocalDefaults: StoreLocalDefaults, Sendable {
    private let values = OSAllocatedUnfairLock<[String: Data]>(initialState: [:])

    /// An empty surface.
    public init() {}

    public func data(forKey defaultName: String) -> Data? {
        values.withLock { $0[defaultName] }
    }

    public func set(_ value: Any?, forKey defaultName: String) {
        // Only `Data` is ever written through this surface; narrowing first also keeps the
        // non-`Sendable` `Any` out of the lock's `@Sendable` closure.
        let data = value as? Data
        values.withLock { $0[defaultName] = data }
    }

    public func removeObject(forKey defaultName: String) {
        values.withLock { $0[defaultName] = nil }
    }
}

/// The encoding both ledger repositories use for their pending reset boundaries in the store's
/// ``StoreLocalDefaults`` — one implementation, so the two cannot drift, while each repository
/// keeps its own LITERAL key at its own call sites.
///
/// A sidecar that will not decode reads as EMPTY and is audited: there is nothing left to retry,
/// and the rows it would have protected were already deleted by the wipe that wrote it.
nonisolated enum PendingResetBoundaryCoding {
    /// The markers encoded in `data` (empty for absent or undecodable data).
    static func decode<Entry: Decodable>(_ data: Data?, as type: Entry.Type, store: String) -> [Entry] {
        guard let data else { return [] }
        do {
            return try RowPayloadCoders.makeDecoder().decode([Entry].self, from: data)
        } catch {
            PersistenceFailureAudit.record("rowStore.pendingResetBoundary.decodeFailed",
                                           error: error, context: ["store": store])
            return []
        }
    }

    /// `markers` encoded for the sidecar, or nil (audited) when they would not encode.
    static func encode<Entry: Encodable>(_ markers: [Entry], store: String) -> Data? {
        do {
            return try RowPayloadCoders.makeEncoder().encode(markers)
        } catch {
            PersistenceFailureAudit.record("rowStore.pendingResetBoundary.encodeFailed",
                                           error: error, context: ["store": store])
            return nil
        }
    }
}
