import SwiftUI

/// Fernlet's own camera for the world map: where it looks and how far up it is.
///
/// The camera belongs to Fernlet, not to the base map: a base map follows it, and reports back
/// when the person pans or zooms. `revision` goes up only when Fernlet moves the camera itself
/// (following the companion, recentring), so a base map can tell a request from an echo.
nonisolated struct WorldCamera: Equatable, Sendable {
    var center: GeoPoint
    /// Camera height in metres (MapKit's camera distance; the plain map scales it to the same zoom).
    var distance: Double
    /// Bumped by every programmatic move.
    var revision = 0
    /// Whether the camera keeps the companion in view; a pan by the person turns it off.
    var follows = true
}

/// The map seam: anything that can draw a north-up, flat base map under Fernlet's layers.
///
/// Phase 1 has ``AppleMutedBaseMap`` (MapKit, muted, no points of interest) and ``PlainBaseMap``
/// (no tiles at all: the offline look until phase 2). Phase 2 adds a MapLibre conformer and
/// nothing else changes: the fog, trails, companion and markers only ever see the
/// ``MapViewport`` a base map reports, and plain ``GeoPoint``s. This file and its conformers are
/// the only places that may know which map is underneath; only `AppleMutedBaseMap.swift` imports MapKit.
protocol WorldBaseMap {
    associatedtype Body: View

    /// The credit the base map must keep visible, or nil when it draws its own (Apple's map draws
    /// "Apple Maps" and "Legal" itself, inside the bottom safe area it is given).
    var creditText: String? { get }

    /// The base map's view. It follows `camera`, writes the person's pans back into it, and calls
    /// `onViewport` with the visible rectangle every time the view moves.
    func makeBody(camera: Binding<WorldCamera>, darkStyle: Bool, bottomInset: CGFloat,
                  onViewport: @escaping (MapViewport) -> Void) -> Body
}

/// Which base map the shell draws (a fixture control).
nonisolated enum BaseMapKind: String, CaseIterable, Identifiable, Sendable {
    case appleMuted, plain

    var id: String { rawValue }

    /// The fixture control's label.
    var label: String {
        switch self {
        case .appleMuted: "Apple Maps, muted (phase 1)"
        case .plain: "No map: offline look"
        }
    }
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
            AppleMutedBaseMap().makeBody(camera: $camera, darkStyle: darkStyle, bottomInset: bottomInset, onViewport: onViewport)
        case .plain:
            PlainBaseMap().makeBody(camera: $camera, darkStyle: darkStyle, bottomInset: bottomInset, onViewport: onViewport)
        }
    }
}
