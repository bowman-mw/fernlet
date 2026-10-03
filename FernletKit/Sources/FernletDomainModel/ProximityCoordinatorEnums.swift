// ProximityCoordinatorEnums.swift
// SPM carve-up: the session's mode, a pure String/Codable enum formerly nested inside
// ProximityCoordinator, as a top-level public enum here so the audit/trust DTOs
// (ConnectionSessionLog, ProximityTrustedPeerRecord) can reference it without an upward edge.
// ProximityCoordinator keeps `typealias Mode = ProximityMode` so every existing
// `ProximityCoordinator.Mode` / bare `Mode` reference across the proximity subtree compiles
// unchanged. The session's role and ranging mode are ProximityKit's own (`ProximityRole`,
// `ProximityRangingMode`); ConnectionSessionLog keeps nested copies with the same raw values.
// Codable identity is by rawValue — renaming/relocating the type does NOT change the JSON.

import Foundation

/// The relationship class of a proximity session: trainer or friend.
///
/// Persisted on trust/audit records (``ProximityTrustedPeerRecord``, ``ConnectionSessionLog``),
/// where modes minted by newer builds park via their tolerant decodes.
public nonisolated enum ProximityMode: String, Codable, Equatable, Sendable {
    case trainer
    case friend
}
