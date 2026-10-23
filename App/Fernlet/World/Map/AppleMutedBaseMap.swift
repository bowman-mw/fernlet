import MapKit
import SwiftUI
import WorldMapStore

/// Phase 1's base map: Apple's map, muted, with every point of interest hidden.
///
/// **The only file in the app that imports MapKit** (`MapAndLocationConfinementBoundaryTests`). MapKit
/// fetches Apple's map tiles for the visible area; that is the whole of what Apple receives
/// (`Docs/No-Tracking-Wall.md` §4a, "Apple Maps (MapKit)"). Fernlet's fog, trails, pins and location
/// are drawn on top by Fernlet and never handed to MapKit.
///
/// MapKit draws its own "Maps" logo and "Legal" link inside the safe area, so the bottom inset lifts
/// them clear of the item bar and they stay visible (MapKit terms). Pitch and rotation are off, so the
/// map stays north-up and flat and Fernlet's layers can place themselves from the visible `MKMapRect`
/// alone.
struct AppleMutedBaseMap: WorldBaseMap {
    var drawsOwnCredit: Bool { true }

    func makeBody(camera: Binding<WorldCamera>, darkStyle: Bool, bottomInset: CGFloat,
                  onViewport: @escaping (MapViewport) -> Void) -> some View {
        AppleMutedMapView(camera: camera, darkStyle: darkStyle, bottomInset: bottomInset, onViewport: onViewport)
    }
}

/// The SwiftUI `Map` behind ``AppleMutedBaseMap``.
private struct AppleMutedMapView: View {
    @Binding var camera: WorldCamera
    let darkStyle: Bool
    let bottomInset: CGFloat
    let onViewport: (MapViewport) -> Void
    @State private var position: MapCameraPosition = .automatic

    var body: some View {
        Map(position: $position,
            bounds: MapCameraBounds(minimumDistance: WorldCamera.distanceRange.lowerBound,
                                    maximumDistance: WorldCamera.distanceRange.upperBound),
            interactionModes: [.pan, .zoom])
            .mapStyle(.standard(emphasis: .muted, pointsOfInterest: .excludingAll))
            .environment(\.colorScheme, darkStyle ? .dark : .light)
            .safeAreaPadding(.bottom, bottomInset)
            .onMapCameraChange(frequency: .continuous) { context in
                onViewport(Self.viewport(of: context.rect))
                guard position.positionedByUser else { return }
                let centre = context.camera.centerCoordinate
                camera.center = GeoPoint(centre.latitude, centre.longitude)
                camera.distance = context.camera.distance
                camera.follows = false
            }
            .onAppear { position = Self.position(for: camera) }
            .onChange(of: camera.revision) {
                withAnimation(.linear(duration: 0.12)) { position = Self.position(for: camera) }
            }
    }

    /// MapKit's camera for Fernlet's camera: north-up, flat.
    private static func position(for camera: WorldCamera) -> MapCameraPosition {
        let centre = CLLocationCoordinate2D(latitude: camera.center.latitude, longitude: camera.center.longitude)
        return .camera(MapCamera(centerCoordinate: centre, distance: camera.distance, heading: 0, pitch: 0))
    }

    /// The visible map rect in normalised Web Mercator (MapKit's map points over the world's size).
    private static func viewport(of rect: MKMapRect) -> MapViewport {
        let world = MKMapSize.world
        guard world.width > 0, world.height > 0 else { return MapViewport(minX: 0, minY: 0, width: 0, height: 0) }
        return MapViewport(minX: rect.origin.x / world.width, minY: rect.origin.y / world.height,
                           width: rect.size.width / world.width, height: rect.size.height / world.height)
    }
}
