// StoreLocalDefaults+UserDefaults.swift
// CloudKitSync
//
// `UserDefaults` IS a `StoreLocalDefaults`: its own three accessors already have the protocol's
// shape, which is what lets the default store's device-local surface simply be
// `UserDefaults.standard`.
//
// In a file of its own ON PURPOSE. The persisted-surface discovery wall
// (`PersistedSurfaceWipeBoundaryTests`) also scans receiver-less accessor calls in any file that
// declares `extension UserDefaults`, because inside one `self.` is implicit. Next to the protocol,
// the protocol's own requirement declarations (`func data(forKey defaultName:)` …) read to it as
// unlabelled defaults writes. Keep this file to the one line.

import Foundation

// `nonisolated`: this module defaults to the main actor, which would otherwise make the conformance
// main-actor-isolated — and `PersistenceController` picks its surface in a nonisolated init.
nonisolated extension UserDefaults: StoreLocalDefaults {}
