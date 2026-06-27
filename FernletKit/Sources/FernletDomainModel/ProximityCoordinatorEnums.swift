// ProximityCoordinatorEnums.swift
// SPM carve-up: the three pure String/Codable enums formerly nested inside ProximityCoordinator
// (Role, Mode, RangingMode) hoisted DOWN as top-level public enums so the audit/trust DTOs
// (ConnectionSessionLog, ProximityTrustedPeerRecord) can reference them without an upward edge.
// ProximityCoordinator keeps `typealias Role = ProximityRole` (etc.) so every existing
// `ProximityCoordinator.Role` / bare `Role` reference across the proximity subtree compiles
// unchanged. Codable identity is by rawValue — renaming/relocating the type does NOT change the JSON.

import Foundation

public nonisolated enum ProximityRole: String, Codable, Equatable, Sendable {
    case advertiser
    case browser
}

public nonisolated enum ProximityMode: String, Codable, Equatable, Sendable {
    case trainer
    case friend
}

public nonisolated enum ProximityRangingMode: String, Codable, Equatable, Sendable {
    case uwb
    case rssi
    case none
}
