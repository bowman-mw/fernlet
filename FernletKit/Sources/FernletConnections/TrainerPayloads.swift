// TrainerPayloads.swift
// FernletConnections
//
// The wire envelope for the Trainer / Nutritionist export (Phase 7): payload vocabulary of Fernlet's
// coach channel, so it lives with Fernlet's connection rules rather than in ProximityKit, which would
// carry the body as opaque sealed bytes and names no part of it. A user assembles a CURATED,
// allowlist-projected workout + nutrition bundle in the app (`TrainerExportBuilder`) and reviews exactly
// what it contains before sharing. The bundle bytes are opaque here too: the app owns the
// `Codable` shape (which by construction excludes journal text, period/cycle, intimate, photos, friends,
// location, and recipe ingredients — see `TrainerExportBuilder`).
//
// TRANSPORT SEAM (deferred): a coach is NOT a friend. When the dedicated coaching feature ships, this
// bundle will travel over the separate `fernlet-coach` trainer channel (`ProximityMode.trainer`, a
// service type its radio profile brings, `ProximityCoordinator.sendPayload(...)`) to a coach running the
// separate coaching app — never over the friend mesh. Until then the app shares the reviewed bundle as a
// file. This type + `PayloadType.workoutCompletion`'s membership in Fernlet's `payloads.sealingRequired` (so an
// unsealed send is fail-closed at `verify()`) are the wire seam that later feature will use. A
// trainer-mode coordinator refuses an inbound blob over ProximityKit's own bound,
// `ProximityCoordinator.maxTrainerModeInboundBytes`, before it decodes anything; both caps below are
// derived from that bound, so Fernlet's body always fits inside the mechanism's limit.
//
// WI-9: `public nonisolated struct … : Codable, Equatable, Sendable` — this module's
// `.defaultIsolation(MainActor.self)` would otherwise MainActor-isolate the synthesized `Codable`, a hard
// error for a receiver that decodes these untrusted transport bytes off the main actor.

import Foundation
import ProximityKit

/// Wire envelope body for the curated Trainer / Nutritionist export bundle.
///
/// The bundle bytes are opaque here — the app owns the allowlist-projected `Codable`
/// shape (see the header note) — so this type only carries, bounds, and shape-checks them. It is
/// the wire seam the future `fernlet-coach` trainer channel will use; until that ships, the app
/// shares the reviewed bundle as a file.
public nonisolated struct TrainerExportPayload: Codable, Equatable, Sendable {
    public var format = "fernlet.trainer.export"
    public var version = 1
    /// The app-encoded `TrainerExportBundle` JSON. Opaque here; bounded so a hostile peer can't ship a
    /// giant blob that the receiver would hold in memory.
    public let bundle: Data

    public init(bundle: Data) {
        self.bundle = bundle
    }

    /// Upper bound on the encoded bundle (a curated multi-month export is well under this): half of
    /// ``maxTrainerWireBytes``, derived, never hand-written. The sealed ciphertext is ≈ payload-sized
    /// and the envelope carries it base64 (×4/3) plus bounded JSON overhead, so a bundle at half the
    /// wire cap still fits under it with margin.
    public static let maxBundleBytes = maxTrainerWireBytes / 2

    /// Hard cap on a coach-session inbound WIRE blob: ProximityKit's
    /// `ProximityCoordinator.maxTrainerModeInboundBytes`, which a trainer-mode coordinator enforces
    /// BEFORE the envelope is decoded, decrypted, or inflated (Increment 10 — the hearts
    /// ordering: `isWellFormed`'s check runs after decrypt+inflate, which is the wrong layer
    /// for a denial-of-service bound). The mechanism owns the bound and Fernlet's body is sized
    /// to fit inside it, keeping a hostile blob far under `SealedPayloadFraming`'s 16 MiB inflate
    /// guard.
    public static let maxTrainerWireBytes = ProximityCoordinator.maxTrainerModeInboundBytes

    public var isWellFormed: Bool {
        format == "fernlet.trainer.export" && version == 1 && !bundle.isEmpty && bundle.count <= Self.maxBundleBytes
    }
}
