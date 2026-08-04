//
//  CloudKitSchemaDeploy.swift
//  CloudKitSync
//
//  The launch-argument seam for the DEBUG-only CloudKit schema deploy.
//
//  Pushing the Core Data model to CloudKit's server-side schema (development, then
//  promoted to production in the console) is a one-shot, developer-run operation — see
//  Docs/CloudKit-Schema-Deploy.md for the full ritual. The actual
//  `NSPersistentCloudKitContainer.initializeCloudKitSchema(options:)` call lives in
//  `PersistenceController` and is wrapped in `#if DEBUG`, so it is compiled out of any
//  Release build entirely.
//
//  This file holds only the pure, side-effect-free argument-parsing seam so it can be
//  unit tested without CloudKit, a store, or an iCloud account.
//

import Foundation

/// Namespace for the CloudKit schema-deploy launch flag.
///
/// The deploy path is a **development tool only**. `isRequested(arguments:)` is pure and
/// testable; the caller that reads `ProcessInfo` and performs the schema push is gated by
/// `#if DEBUG` in ``PersistenceController``, so the deploy cannot be triggered in Release.
public enum CloudKitSchemaDeploy {
    /// Launch argument that requests a one-shot CloudKit schema initialization.
    /// Pass it in the Xcode scheme (Run ▸ Arguments ▸ Arguments Passed On Launch) or via
    /// `xcrun simctl launch … <bundleID> INITIALIZE_CLOUDKIT_SCHEMA`.
    public nonisolated static let launchArgument = "INITIALIZE_CLOUDKIT_SCHEMA"

    /// Whether the given process argument list requests a schema deploy.
    ///
    /// Pure: no `ProcessInfo`, no CloudKit, no store — safe to unit test off the main actor.
    public nonisolated static func isRequested(arguments: [String]) -> Bool {
        arguments.contains(launchArgument)
    }
}
