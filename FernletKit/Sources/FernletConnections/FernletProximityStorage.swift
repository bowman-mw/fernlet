// FernletProximityStorage.swift
// FernletConnections
//
// ProximityKit plan step A0.6.6 (Docs/Plan-FernletCoach-ProximityKit-2026-10-01.md §4 A0.6, "The storage
// directory always comes from the host"): where the Fernlet app keeps its proximity files. ProximityKit
// computes no directory, so every host states its root (`ProximityHost.proximitySupportDirectory`), and
// this is Fernlet's, beside `ProximityNamespace.fernlet`, whose installation names the folder. Both the
// app and FernletSocial see this module, and FernletSocial's production heart-drop scope reads the same
// root, so it lives here rather than in the app.

import Foundation
import ProximityKit

/// Where the Fernlet app keeps its proximity files on this device: `.fernlet`'s folder under the app
/// container's Application Support, `Application Support/Fernlet`, the path they have always used.
///
/// The app's production store, its crypto-format census and FernletSocial's production heart-drop
/// scope read ``productionDirectory``; tests pass roots of their own. Computed on every read, as
/// before, from the same expression ProximityKit evaluated for Fernlet until plan step A0.6.6 (its
/// namespace's default directory, which no longer exists), so the bytes of every path are unchanged:
/// `URL.applicationSupportDirectory` with the folder name `Fernlet` appended as a directory.
/// `FernletFeatureGoldenTests`' group 30 holds it, and each site that reads it, to that path.
///
/// `nonisolated` against this module's `defaultIsolation(MainActor.self)`: a location, read by the
/// store's initializers, by FernletSocial's nonisolated heart-drop scope and by the nonisolated census.
public nonisolated enum FernletProximityStorage {

    /// `Application Support/Fernlet`: `ProximityNamespace.fernlet`'s installation folder under the
    /// app container's Application Support, a directory URL. Reads no file system and creates
    /// nothing.
    public static var productionDirectory: URL {
        ProximityNamespace.fernlet.installation.storage.directory(under: .applicationSupportDirectory)
    }
}
