import SwiftUI
import WorldMapStore

/// The map seam: anything that can draw a north-up, flat base map under Fernlet's own layers.
///
/// Phase 1 has ``AppleMutedBaseMap`` (MapKit, muted, no points of interest) and ``PlainBaseMap`` (no
/// tiles at all: the offline look until phase 2). Phase 2 adds a MapLibre conformer and nothing else
/// changes: the fog, trails, companion and pins only ever see the `MapViewport` a base map reports, and
/// plain `GeoPoint`s. This file and its conformers are the only places that know which map is
/// underneath; only `AppleMutedBaseMap.swift` imports MapKit (`MapAndLocationConfinementBoundaryTests`).
protocol WorldBaseMap {
    associatedtype Body: View

    /// Whether the base map draws its own provider credit (Apple's map draws its "Maps" logo and
    /// "Legal" link itself, inside the bottom safe area it is given), so Fernlet must keep a clear
    /// patch for it.
    var drawsOwnCredit: Bool { get }

    /// The base map's view. It follows `camera`, writes the person's pans back into it, and calls
    /// `onViewport` with the visible rectangle every time the view moves.
    func makeBody(camera: Binding<WorldCamera>, darkStyle: Bool, bottomInset: CGFloat,
                  onViewport: @escaping (MapViewport) -> Void) -> Body
}

/// Which base map draws under the layers.
///
/// A frozen token (never shown): the display text for each lives in the views that offer a choice.
nonisolated enum BaseMapKind: String, CaseIterable, Identifiable, Sendable {
    case appleMuted
    case plain

    var id: String { rawValue }
}

/// Picks the base map for a ``BaseMapKind``: the one switch over concrete map types.
struct BaseMapLayer: View {
    let kind: BaseMapKind
    @Binding var camera: WorldCamera
    let darkStyle: Bool
    let bottomInset: CGFloat
    let onViewport: (MapViewport) -> Void

    var body: some View {
        switch kind {
        case .appleMuted:
            AppleMutedBaseMap().makeBody(camera: $camera, darkStyle: darkStyle, bottomInset: bottomInset,
                                         onViewport: onViewport)
        case .plain:
            PlainBaseMap().makeBody(camera: $camera, darkStyle: darkStyle, bottomInset: bottomInset,
                                    onViewport: onViewport)
        }
    }
}
