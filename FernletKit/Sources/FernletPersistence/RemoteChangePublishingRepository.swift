//
//  RemoteChangePublishingRepository.swift
//  FernletPersistence
//
//  Repository-layer refinement for repositories that publish remote (iCloud) changes.
//  Lives in FernletPersistence so both the package repositories that conform to it
//  (e.g. `CoreDataFernletRepository` in CloudKitSync) and StoreCore's
//  `SnapshotSaveCoordinator` (which dynamically casts to it) can see the contract.
//

import Combine

/// Refinement of ``FernletRepository`` for conformers that can announce remote (iCloud) changes.
///
/// `CoreDataFernletRepository` (in `CloudKitSync`) is the production conformer: it forwards
/// persistent-store remote-change notifications through ``remoteChangePublisher`` so
/// `SnapshotSaveCoordinator` (in `StoreCore`) — which holds only an abstract ``FernletRepository`` —
/// can dynamically cast to this refinement and reload state when another device's write lands. Purely
/// local repositories simply don't conform; the failed cast is the "no remote changes will ever
/// arrive" signal, not an error. Declared here in ``FernletPersistence`` so both sides of the seam see
/// the contract without the coordinator needing any dependency on `CloudKitSync` — the same inversion
/// that keeps the rest of `StoreCore` backing-store agnostic. `@MainActor`: the publisher is
/// subscribed and consumed on the main actor.
@MainActor
public protocol RemoteChangePublishingRepository: FernletRepository {
    /// Fires when the backing store ingests changes written by another device; observers reload
    /// persisted state on each emission.
    var remoteChangePublisher: AnyPublisher<Void, Never> { get }
}
