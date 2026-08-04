// ProximityCoordinatorEnums.swift
// SPM carve-up: the three pure String/Codable enums formerly nested inside ProximityCoordinator
// (Role, Mode, RangingMode) hoisted DOWN as top-level public enums so the audit/trust DTOs
// (ConnectionSessionLog, ProximityTrustedPeerRecord) can reference them without an upward edge.
// ProximityCoordinator keeps `typealias Role = ProximityRole` (etc.) so every existing
// `ProximityCoordinator.Role` / bare `Role` reference across the proximity subtree compiles
// unchanged. Codable identity is by rawValue — renaming/relocating the type does NOT change the JSON.

import Foundation

/// Which MultipeerConnectivity role this device played in a session (advertiser or browser).
///
/// Hoisted out of the app-side ProximityCoordinator so the audit/trust DTOs can name it without an
/// upward edge; the coordinator keeps a `Role` typealias to it.
public nonisolated enum ProximityRole: String, Codable, Equatable, Sendable {
    case advertiser
    case browser
}

/// The relationship class of a proximity session: trainer or friend.
///
/// Persisted on trust/audit records (``ProximityTrustedPeerRecord``, ``ConnectionSessionLog``),
/// where modes minted by newer builds park via their tolerant decodes.
public nonisolated enum ProximityMode: String, Codable, Equatable, Sendable {
    case trainer
    case friend
}

/// How peer distance was measured during a session: UWB, RSSI fallback, or not at all.
///
/// Recorded in ``ConnectionSessionLog``'s ranging info; the UWB dwell-commit is the join ritual
/// several trust flows key off.
public nonisolated enum ProximityRangingMode: String, Codable, Equatable, Sendable {
    case uwb
    case rssi
    case none
}
