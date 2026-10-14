// ProximityMode+SessionMode.swift
// FernletConnections
//
// Fernlet's one conversion from the session mode ProximityKit's coordinator runs under to the mode
// Fernlet persists. The coordinator takes and reports its own `ProximitySessionMode`; Fernlet keeps
// FernletDomainModel's `ProximityMode` on the records it persists, the trust vault's
// `ProximityTrustedPeerRecord` and the app's `ConnectionSessionLog`, both in the synced snapshot. The
// vault's `trust(_:mode:)` and the app's `ConnectionInspector` convert here and nowhere else. The two
// enums spell the same frozen raw values, `trainer` and `friend`, which
// `ProximityVocabularyGoldenTests` holds both to, so a converted mode persists the bytes it always did.

import FernletDomainModel
import ProximityKit

nonisolated extension ProximityMode {

    /// The persisted mode of the same name as the session mode a coordinator ran under, case for
    /// case. An exhaustive switch, so a mode ProximityKit adds fails to compile here instead of being
    /// persisted as something else.
    ///
    /// `nonisolated` against this module's `defaultIsolation(MainActor.self)`, like the value types
    /// on both sides of it.
    ///
    /// - Parameter mode: The session mode the coordinator ran under.
    public nonisolated init(_ mode: ProximitySessionMode) {
        switch mode {
        case .trainer: self = .trainer
        case .friend: self = .friend
        }
    }
}
