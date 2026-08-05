// CoreDataModelBuilding.swift
// FernletFoundation
//
// Layer-0 helper for the programmatic Core Data model builders. Shared by the
// synced store (`PersistenceController` in CloudKitSync) and the sealed store
// (`PrivatePersistenceController` in PrivateStoreCore) so the two attribute
// factories cannot drift apart. Pure in-memory `NSAttributeDescription`
// construction — it names no entity, no sealed or synced type, and touches no
// storage, so it can live below the S3 wall and be reused by both modules.

import CoreData
import Foundation

/// Namespace for the shared pieces of the programmatic Core Data model builders.
///
/// Both persistence controllers assemble their `NSManagedObjectModel` in code (no
/// `.xcdatamodeld`): the synced store's `PersistenceController` (CloudKitSync) and the sealed
/// store's `PrivatePersistenceController` (PrivateStoreCore). Each previously carried a private,
/// byte-identical copy of the attribute factory; it lives here — same Layer-0 posture as
/// ``BackupExclusion`` — so the two model builders stay identical instead of drifting apart.
/// Pure mechanism: it constructs in-memory descriptions only and names no sealed or synced
/// entity, which is what lets modules on both sides of the S3 wall reach it. `package` access —
/// only in-package model builders need it, so it stays out of the app-facing public API. A
/// caseless enum used purely as a namespace.
package enum CoreDataModelBuilding {
    /// Builds one optional attribute description, optionally flagged for external binary storage
    /// (used by the sealed store's ciphertext columns) and/or given a default value (used by the
    /// synced store's macro columns). `nonisolated`: pure in-memory construction with no shared
    /// state, callable from the nonisolated model builders in both persistence controllers.
    package nonisolated static func makeAttribute(
        _ name: String,
        type: NSAttributeType,
        defaultValue: Any? = nil,
        allowsExternalBinaryDataStorage: Bool = false
    ) -> NSAttributeDescription {
        let attribute = NSAttributeDescription()
        attribute.name = name
        attribute.attributeType = type
        attribute.isOptional = true
        attribute.defaultValue = defaultValue
        attribute.allowsExternalBinaryDataStorage = allowsExternalBinaryDataStorage
        return attribute
    }
}
