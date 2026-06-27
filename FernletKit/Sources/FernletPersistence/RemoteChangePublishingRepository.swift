//
//  RemoteChangePublishingRepository.swift
//  FernletPersistence
//
//  Repository-layer refinement for repositories that publish remote (iCloud) changes.
//  Lives in FernletPersistence so both the package repositories that conform to it
//  (e.g. `CoreDataFernletRepository` in CloudKitSync) and the app's
//  `SnapshotSaveCoordinator` (which dynamically casts to it) can see the contract.
//

import Combine

@MainActor
public protocol RemoteChangePublishingRepository: FernletRepository {
    var remoteChangePublisher: AnyPublisher<Void, Never> { get }
}
