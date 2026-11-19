import CoreGraphics
import FernletDomainModel
import FernletUI
import SwiftUI
import WorldMapStore

/// Real planes over Home's map (owner 2026-11-19, the live-planes build; report §10), drawn while "Live planes nearby"
/// is on, the map is in front and the app is active. Nothing in a decoy.
///
/// - **Fetching** is ``LiveAircraftWatch``'s loop, this layer's task: the cell under the map's centre, every 30 s. The
///   task ends with the layer, so the mid-flight screen (which takes Home's map away) pauses it.
/// - **Drawing:** every plane in the feed that is in the air, each in its family's pixel design and its airline's
///   colours, at the nearest of eight headings, with a shadow further below the higher it flies. Between fetches each
///   glides along its track; with Reduce Motion it stays where it was read. No labels, except on a plane the person has
///   flown on (the same tail) and, lighter, one of a type they've flown (a few at a time).
/// - **Tap** a plane for its card (``LiveAircraftCard``). To VoiceOver the planes are one element, "12 live planes on the
///   map", whose actions open the nearest ones' cards.
/// - **Nothing is kept:** the sky lives in memory, and live planes give nothing to the passport.
struct LiveAircraftLayer: View {
    let store: FernletStore
    let viewport: MapViewport
    let size: CGSize
    /// Whether Home's map is in front and the app active.
    let isActive: Bool
    @AppStorage(WorldMapPreferences.Key.livePlanes) private var isOn = false
    @State private var watch = LiveAircraftWatch()
    @State private var images = LiveAircraftImageMemo()
    @State private var flown = LiveAircraftFlown()
    @State private var opened: LiveAircraftCardSnapshot?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale

    /// About how many points a sprite pixel takes (owner 2026-11-19, review call 3: "a little bigger").
    static let pointsPerPixel: CGFloat = 1.6
    /// The tap target round each plane, in points.
    static let tapSide: CGFloat = 44
    /// The most light "type flown" labels at once.
    static let maxTypeLabels = 3
    /// The most planes VoiceOver's element offers to open.
    static let maxSpokenActions = 8

    var body: some View {
        let shows = isOn && !store.duressSessionActive
        let cell = shows && isActive ? LiveAircraftWatch.cell(for: viewport, size: size) : nil
        ZStack(alignment: .topLeading) {
            if shows && !watch.sky.planes.isEmpty {
                TimelineView(.animation(minimumInterval: 1.0 / 15, paused: reduceMotion || !isActive)) { context in
                    sky(at: context.date)
                }
            }
        }
        .task(id: cell) {
            guard let cell else { return }
            await watch.watch(cell)
        }
        .task(id: shows) {
            guard shows else {
                watch.clear()
                return
            }
            flown = LiveAircraftFlown(flights: WorldExploreState.book(store).flights)
        }
        .sheet(item: $opened) { snapshot in
            LiveAircraftCard(snapshot: snapshot)
                .presentationDetents([.height(LiveAircraftCard.height)])
        }
    }

    /// The planes on the screen at `now`.
    @ViewBuilder
    private func sky(at now: Date) -> some View {
        let placed = place(at: now)
        ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                // Bounded: at most `LiveAircraftSky.maxPlanes` planes, twice (shadows under every plane first).
                for plane in placed {
                    guard let shadow = images.image(for: plane.sprite, shadow: true) else { continue }
                    context.opacity = plane.opacity * 0.22
                    context.draw(Image(decorative: shadow, scale: 1).interpolation(.none), in: plane.rect.offsetBy(dx: plane.shadowOffset, dy: plane.shadowOffset * 1.4))
                }
                for plane in placed {
                    guard let image = images.image(for: plane.sprite, shadow: false) else { continue }
                    context.opacity = plane.opacity
                    context.draw(Image(decorative: image, scale: 1).interpolation(.none), in: plane.rect)
                }
            }
            .frame(width: size.width, height: size.height)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            labels(placed)
            ForEach(placed) { plane in
                Color.clear
                    .frame(width: Self.tapSide, height: Self.tapSide)
                    .contentShape(Rectangle())
                    .onTapGesture { opened = LiveAircraftCardSnapshot(plane.aircraft, match: plane.match) }
                    .position(plane.point)
                    .accessibilityHidden(true)
            }
            spokenSummary(placed)
        }
    }

    /// The labels: every plane flown on, and the few nearest the centre of a type flown.
    @ViewBuilder
    private func labels(_ placed: [LiveAircraftPlaced]) -> some View {
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
        let samePlane = placed.filter { $0.match == .samePlane }
        let sameType = placed.filter { $0.match == .sameType }
            .sorted { hypot($0.point.x - centre.x, $0.point.y - centre.y) < hypot($1.point.x - centre.x, $1.point.y - centre.y) }
            .prefix(Self.maxTypeLabels)
        ForEach(samePlane) { plane in
            WorldGoldPlate(text: AddressedCopy.plain(LiveAircraftCopy.flewOnThisPlane))
                .fixedSize()
                .opacity(plane.opacity)
                .position(x: plane.point.x, y: plane.rect.maxY + 12)
        }
        ForEach(Array(sameType)) { plane in
            Text(LiveAircraftCopy.flewThisType)
                .font(.fernlet(.labelSmall))
                .foregroundStyle(WorldPalette.dim)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(WorldPalette.paper.opacity(0.85), in: Capsule())
                .fixedSize()
                .opacity(plane.opacity)
                .position(x: plane.point.x, y: plane.rect.maxY + 9)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The planes as one VoiceOver element on the plane nearest the centre, its actions opening the nearest cards.
    @ViewBuilder
    private func spokenSummary(_ placed: [LiveAircraftPlaced]) -> some View {
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
        let nearest = placed.sorted { hypot($0.point.x - centre.x, $0.point.y - centre.y) < hypot($1.point.x - centre.x, $1.point.y - centre.y) }
        if let first = nearest.first {
            Color.clear
                .frame(width: Self.tapSide, height: Self.tapSide)
                .position(first.point)
                .accessibilityElement()
                .accessibilityLabel(Text(LiveAircraftCopy.spokenCount(placed.count)))
                .accessibilityIdentifier("world.livePlanes")
                .accessibilityActions {
                    ForEach(nearest.prefix(Self.maxSpokenActions)) { plane in
                        let snapshot = LiveAircraftCardSnapshot(plane.aircraft, match: plane.match)
                        Button {
                            opened = snapshot
                        } label: {
                            Text(verbatim: snapshot.spokenName)
                        }
                    }
                }
        }
    }

    /// Points per sprite pixel on a screen of `displayScale`: ``pointsPerPixel`` snapped to whole device pixels, so every
    /// sprite pixel is the same number of device pixels and the art stays crisp (5 on a 3× screen, 3 on a 2× one).
    static func scale(displayScale: CGFloat) -> CGFloat {
        let screen = max(displayScale, 1)
        return max(1, (pointsPerPixel * screen).rounded()) / screen
    }

    /// Every showing plane placed on the screen at `now`, those well off it left out, low planes first so high ones
    /// draw over them.
    private func place(at now: Date) -> [LiveAircraftPlaced] {
        let margin: CGFloat = 40
        let bounds = CGRect(origin: .zero, size: size).insetBy(dx: -margin, dy: -margin)
        return watch.sky.showing(at: now).compactMap { plane -> LiveAircraftPlaced? in
            let point = viewport.screenPoint(for: LiveAircraftSky.position(of: plane, at: now, glides: !reduceMotion), in: size)
            guard bounds.contains(point) else { return nil }
            let family = LiveAircraftTypes.family(code: plane.typeCode, category: plane.category)
            let livery = LiveAircraftAirlines.flight(plane.callsign)?.airline.livery ?? .plain(family)
            let key = LiveAircraftSpriteKey(family: family, livery: livery, eighths: LiveAircraftSprites.eighths(for: plane.trackDegrees))
            let spriteSize = images.size(of: key), scale = Self.scale(displayScale: displayScale)
            let rect = CGRect(x: point.x - spriteSize.width * scale / 2, y: point.y - spriteSize.height * scale / 2,
                              width: spriteSize.width * scale, height: spriteSize.height * scale)
            return LiveAircraftPlaced(aircraft: plane, point: point, rect: rect, sprite: key,
                                      opacity: watch.sky.opacity(of: plane, at: now),
                                      shadowOffset: LiveAircraftPlaced.shadowOffset(feet: plane.altitudeFeet),
                                      match: flown.match(plane))
        }
        .sorted { ($0.aircraft.altitudeFeet, $0.id) < ($1.aircraft.altitudeFeet, $1.id) }
    }
}

/// One plane placed on the screen for a frame.
struct LiveAircraftPlaced: Identifiable {
    let aircraft: LiveAircraft
    /// Its centre on the screen.
    let point: CGPoint
    /// Where its sprite draws.
    let rect: CGRect
    let sprite: LiveAircraftSpriteKey
    let opacity: Double
    /// How far its shadow falls, in points.
    let shadowOffset: CGFloat
    let match: LiveAircraftFlownMatch
    var id: String { aircraft.id }

    /// The shadow's fall for a plane at `feet`: 2 pt near the ground, up to 14 pt at 40,000 ft.
    static func shadowOffset(feet: Int) -> CGFloat {
        2 + 12 * CGFloat(min(max(Double(feet), 0), 40_000) / 40_000)
    }
}

/// Which picture a plane draws with: its family, colours and heading.
nonisolated struct LiveAircraftSpriteKey: Hashable, Sendable {
    let family: LiveAircraftFamily
    let livery: LiveAircraftLivery
    let eighths: Int
}

/// The planes' pictures, made once per family, colours and heading and kept while Home's map lives (the sky draws at
/// 15 frames a second: one image per plane instead of a few hundred squares). Main actor, held by the layer.
@MainActor
final class LiveAircraftImageMemo {
    /// The most pictures kept before the memo starts again.
    static let maxImages = 512
    private var images: [LiveAircraftSpriteKey: CGImage] = [:]
    private var shadows: [LiveAircraftSpriteKey: CGImage] = [:]

    /// The sprite's size in sprite pixels.
    func size(of key: LiveAircraftSpriteKey) -> CGSize {
        let rows = LiveAircraftSprites.turnedRows[key.family]?[key.eighths] ?? []
        return CGSize(width: rows.first?.count ?? 0, height: rows.count)
    }

    /// The picture for `key`, or its all-black shadow.
    func image(for key: LiveAircraftSpriteKey, shadow: Bool) -> CGImage? {
        if let kept = shadow ? shadows[key] : images[key] { return kept }
        if images.count + shadows.count >= Self.maxImages {
            images = [:]
            shadows = [:]
        }
        let sprite = LiveAircraftSprites.sprite(key.family, livery: key.livery, eighths: key.eighths)
        let made = Self.cgImage(sprite, solid: shadow ? 0x000000 : nil)
        if shadow { shadows[key] = made } else { images[key] = made }
        return made
    }

    /// `sprite` as a picture one pixel per sprite pixel, every pixel `solid` when given.
    static func cgImage(_ sprite: WorldSprite, solid: UInt32?) -> CGImage? {
        let width = sprite.width, height = sprite.height
        guard width > 0, height > 0, width <= 96, height <= 96 else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        // Bounded: at most 96 × 96 pixels.
        for (y, row) in sprite.rows.enumerated() {
            for (x, key) in row.enumerated() where x < width {
                guard let colour = solid ?? sprite.palette[key], key != "." else { continue }
                let offset = (y * width + x) * 4
                bytes[offset] = UInt8((colour >> 16) & 0xFF)
                bytes[offset + 1] = UInt8((colour >> 8) & 0xFF)
                bytes[offset + 2] = UInt8(colour & 0xFF)
                bytes[offset + 3] = 0xFF
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

/// The small "© adsb.lol contributors" the map shows while live planes are on (ODbL attribution, beside the map where
/// nobody has to interact to see it). A tap hands adsb.lol's licence page to Safari; the app sends it nothing and holds
/// no client for it (a "not fetched" row of `NoTrackingBoundaryTests.permittedDestinations`). The notice stays as
/// written in every language; VoiceOver's label is translated.
struct LiveAircraftCredit: View {
    /// adsb.lol's privacy and licence page. A constant, checked by the host wall.
    static let licenceURL = URL(string: "https://www.adsb.lol/docs/privacy-license")

    var body: some View {
        if let url = Self.licenceURL {
            Link(destination: url) {
                Text(verbatim: LiveAircraftCopy.credit)
                    .font(.fernlet(.labelSmall))
                    .foregroundStyle(WorldPalette.dim)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(WorldPalette.paper, in: Rectangle())
            }
            .accessibilityLabel(Text(LiveAircraftCopy.creditSpoken))
            .accessibilityInputLabels([Text(verbatim: "adsb.lol")])
            .accessibilityIdentifier("world.livePlanes.credit")
        }
    }
}
