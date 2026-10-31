import FernletDomainModel
import FernletUI
import SwiftUI

/// Home in the air (World-Airports-Spec §6.2, screen 8, approved at draft 6): while the flight gate says the person is
/// flying (``WorldFlightKeeper/isFlying``), Home is the approved location-off Home (``WorldOffMapHome``, `b1-home-denied`
/// draft 4) in place of the map: the date, the name and the photos on top, the open scene, the status plate below; no map,
/// no fog and no blue button. The scene is sky all the way down, with no grass, and holds ``WorldFlyingScene``.
///
/// Nothing in a decoy (§11): a decoy keeps the map where the person last was, as a flight with no readings does.
/// DEBUG `FERNLET_UI_TEST_AIRPORT=flying` stands the gate's flying state in (``UITestSupport/airportHomeState(now:)``).
struct WorldFlyingHome: View {
    var store: FernletStore
    let date: Date
    let onOpen: (WorldPanel) -> Void
    /// A print on the photo wall: its photo in the Album, or the Album (nil).
    let onOpenPrint: (FriendsRoute?) -> Void
    /// The opt-in body-signal reading for Sprout's feeling, as Home reads it.
    var bodySignal: CompanionBodySignal?
    /// Whether Home is on screen; off, the breath, the clouds and the bubble rest.
    var isActive: Bool
    /// The map's night: Sprout winds down at the window too.
    var isNight: Bool

    /// Whether Home shows the plane: the gate says flying, outside a decoy.
    static func shows(_ store: FernletStore) -> Bool {
        store.worldLocation.flights.isFlying && !store.duressSessionActive
    }

    var body: some View {
        WorldOffMapHome(store: store, date: date, status: WorldStatus.current(store: store, date: date), onOpen: onOpen,
                        onOpenPrint: onOpenPrint, inTheAir: true) {
            WorldFlyingScene(store: store, bodySignal: bodySignal, isActive: isActive, isNight: isNight)
        }
    }
}

/// The scene in the air (draft 6): Sprout's bubble over a close-up of a 737's tube (``WorldFlyingTube``), Sprout's face
/// pressed to its window (``WorldFlyingWindow``) under the glass's shine and breath mist, two clouds drifting past
/// (``WorldFlyingCloudLayer``).
///
/// **Accessibility:** one image, "Sprout, flying, its face pressed to the plane's window" (§6.2), the bubble's line as
/// its custom content; the plane's parts and the clouds are decoration.
struct WorldFlyingScene: View {
    var store: FernletStore
    var bodySignal: CompanionBodySignal?
    var isActive: Bool
    var isNight: Bool
    @State private var isLineVisible = false
    /// Which of Sprout's lines is up: the first, then the others in turn each time the bubble comes up again.
    @State private var turn = 0
    /// The line the bubble takes when it next comes up.
    @State private var next = 0
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = WorldFlyingLayout(large: dynamicTypeSize.isAccessibilitySize)
        let line = WorldFlyingHomeCopy.line(turn: turn)
        VStack(spacing: 0) {
            WorldSpeechBubble(text: line)
                .frame(width: 236)
                .opacity(isLineVisible ? 1 : 0)
                .padding(.leading, WorldFlyingLayout.sproutX - 118)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 14)
                .zIndex(1)
            tube(layout)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: WorldFlyingHomeCopy.scene(companion: WorldRecenterCopy.companionName(store))))
        .accessibilityAddTraits(.isImage)
        .accessibilityCustomContent("Thought", Text(verbatim: line))
        .task(id: isActive) { await sayLine() }
    }

    /// The tube with Sprout's window and the glass over it, the clouds flying above and below.
    private func tube(_ layout: WorldFlyingLayout) -> some View {
        ZStack(alignment: .topLeading) {
            WorldFlyingTube(layout: layout)
            WorldFlyingWindow(store: store, layout: layout, bodySignal: bodySignal, isActive: isActive, isNight: isNight)
                .offset(x: layout.glass(centre: WorldFlyingLayout.sproutX).minX, y: layout.glassTop)
            WorldFlyingGlassOver(layout: layout)
        }
        .frame(height: layout.tubeHeight)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .top) { WorldFlyingCloudLayer(layout: layout, isActive: isActive) }
        .padding(.bottom, layout.lowerCloudDrop + WorldFlyingClouds.size.height)
    }

    /// Sprout's line each time Home comes to the front, for Home's arrival window (as the location-off Home's
    /// companion says its own); a later arrival takes the next line.
    private func sayLine() async {
        guard isActive else {
            isLineVisible = false
            return
        }
        turn = next
        next = (next + 1) % WorldFlyingHomeCopy.lineCount
        withAnimation(.easeInOut(duration: 0.22)) { isLineVisible = true }
        // DEBUG screenshots (`hold`) keep the line up; the scene list is empty in release builds.
        guard !UITestSupport.worldHomeScenes.contains("hold") else { return }
        do {
            try await Task.sleep(for: FernletDismissalWindow.system.window(standard: .seconds(6),
                                                                           assistive: FernletDismissalWindow.assistiveNoticeWindow))
        } catch {
            return
        }
        withAnimation(.easeInOut(duration: 0.35)) { isLineVisible = false }
    }
}

/// The plane's colours (draft 6, Sprout's own plane's): fixed, as the plane is the same plane in Dark Mode; the clouds
/// follow Dark Mode.
nonisolated enum WorldFlyingPalette {
    static let skin = WorldPalette.rgb(0xF4F0E6)
    static let highlight = WorldPalette.rgb(0xFFFFFF)
    static let highlightShade = WorldPalette.rgb(0xE6E0D3)
    static let belly = WorldPalette.rgb(0xDCD5C6)
    static let bellyLow = WorldPalette.rgb(0xC9C1B0)
    static let seam = WorldPalette.rgb(0xD6CFC0)
    static let ink = WorldPalette.rgb(WorldSprite.ink)
    static let frame = WorldPalette.rgb(0xB7BEC4)
    static let glass = WorldPalette.rgb(0x55697B)
    static let cheatLine = WorldPalette.rgb(0xC8553D)
    static let pinstripe = WorldPalette.rgb(0xF2C14E)
    static let cloud = WorldPalette.adaptive(light: 0xFFFFFF, dark: 0xC9D3DA)
    static let cloudShade = WorldPalette.adaptive(light: 0xDCE8EF, dark: 0x9FAAB3)
}

/// The 737's tube across the scene: cream skin with a white top highlight and a darker belly, ink edges, faint panel
/// seams, the red cheat line with its yellow pinstripe, and each window's grey frame (the glass, too, but Sprout's,
/// which ``WorldFlyingWindow`` draws). Decoration.
struct WorldFlyingTube: View {
    let layout: WorldFlyingLayout

    var body: some View {
        Canvas { context, size in
            let w = size.width, h = layout.tubeHeight
            let bands: [(CGRect, Color)] = [
                (CGRect(x: 0, y: 0, width: w, height: h), WorldFlyingPalette.skin),
                (CGRect(x: 0, y: 0, width: w, height: 10), WorldFlyingPalette.highlight),
                (CGRect(x: 0, y: 10, width: w, height: 6), WorldFlyingPalette.highlightShade),
                (CGRect(x: 0, y: h - 40, width: w, height: 40), WorldFlyingPalette.belly),
                (CGRect(x: 0, y: h - 14, width: w, height: 14), WorldFlyingPalette.bellyLow),
                (CGRect(x: 0, y: 0, width: w, height: WorldFlyingLayout.edge), WorldFlyingPalette.ink),
                (CGRect(x: 0, y: h - WorldFlyingLayout.edge, width: w, height: WorldFlyingLayout.edge), WorldFlyingPalette.ink),
                (layout.cheatLine(width: w), WorldFlyingPalette.cheatLine),
                (layout.pinstripe(width: w), WorldFlyingPalette.pinstripe),
            ]
            // Bounded: the nine bands above.
            for (rect, colour) in bands { context.fill(Path(rect), with: .color(colour)) }
            // Bounded: at most `WorldFlyingLayout.maxWindows` seams.
            for x in layout.seams(width: w) {
                let seam = CGRect(x: x, y: WorldFlyingLayout.edge, width: 2, height: h - 2 * WorldFlyingLayout.edge)
                context.fill(Path(seam), with: .color(WorldFlyingPalette.seam))
            }
            // Bounded: at most `WorldFlyingLayout.maxWindows` windows.
            for centre in layout.windowCentres(width: w) {
                let frame = Path(roundedRect: layout.frame(centre: centre), cornerRadius: WorldFlyingLayout.frameCorner)
                context.fill(frame, with: .color(WorldFlyingPalette.frame))
                context.stroke(frame, with: .color(WorldFlyingPalette.ink), lineWidth: WorldFlyingLayout.edge)
                guard centre != WorldFlyingLayout.sproutX else { continue }
                context.fill(Path(roundedRect: layout.glass(centre: centre), cornerRadius: WorldFlyingLayout.glassCorner),
                             with: .color(WorldFlyingPalette.glass))
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

/// Sprout's window: the dark glass with Sprout at its regular size pressed to it, staring out, clipped by the glass.
struct WorldFlyingWindow: View {
    var store: FernletStore
    let layout: WorldFlyingLayout
    var bodySignal: CompanionBodySignal?
    var isActive: Bool
    var isNight: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            ZStack(alignment: .topLeading) {
                WorldFlyingPalette.glass
                WorldCompanionSprite(now: WorldCompanionLook.current(store: store, at: context.date, night: .map,
                                                                     bodySignal: bodySignal, mapNight: isNight),
                                     isActive: isActive, pixelScale: layout.pixelScale)
                    .offset(x: layout.spriteOrigin.x, y: layout.spriteOrigin.y)
            }
            .frame(width: layout.glassSize.width, height: layout.glassSize.height, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: WorldFlyingLayout.glassCorner))
        }
        .accessibilityHidden(true)
    }
}

/// Over the glass: each window's faint diagonal shine, and the little white breath mist on Sprout's at mouth height.
struct WorldFlyingGlassOver: View {
    let layout: WorldFlyingLayout

    var body: some View {
        Canvas { context, size in
            // Bounded: at most `WorldFlyingLayout.maxWindows` windows.
            for centre in layout.windowCentres(width: size.width) {
                var pane = context
                pane.clip(to: Path(roundedRect: layout.glass(centre: centre), cornerRadius: WorldFlyingLayout.glassCorner))
                var shine = Path()
                shine.addLines(layout.shine(centre: centre))
                shine.closeSubpath()
                pane.fill(shine, with: .color(.white.opacity(0.16)))
            }
            let glass = layout.glass(centre: WorldFlyingLayout.sproutX)
            let mist = CGRect(x: glass.minX + layout.mistCentre.x - layout.mistRadii.width,
                              y: glass.minY + layout.mistCentre.y - layout.mistRadii.height,
                              width: layout.mistRadii.width * 2, height: layout.mistRadii.height * 2)
            context.fill(Path(ellipseIn: mist), with: .color(.white.opacity(0.32)))
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

/// The two small pixel clouds (``WorldFlyingClouds``): one above the tube and one below it, drifting slowly past;
/// Reduce Motion, or Home off screen, holds them where they are. Decoration.
struct WorldFlyingCloudLayer: View {
    let layout: WorldFlyingLayout
    var isActive: Bool
    /// When the clouds stood at their places.
    @State private var start = Date()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let cloud = WorldFlyingClouds.size
        TimelineView(.animation(minimumInterval: 0.1, paused: reduceMotion || !isActive)) { timeline in
            let elapsed = reduceMotion ? 0 : timeline.date.timeIntervalSince(start)
            Canvas { context, size in
                let upper = CGPoint(x: WorldFlyingClouds.x(start: WorldFlyingClouds.upperX, elapsed: elapsed, width: size.width), y: 0)
                let lower = CGPoint(x: WorldFlyingClouds.x(start: WorldFlyingClouds.lowerX, elapsed: elapsed, width: size.width),
                                    y: layout.upperCloudLift + layout.tubeHeight + layout.lowerCloudDrop)
                Self.draw(at: upper, in: &context)
                Self.draw(at: lower, in: &context)
            }
        }
        .frame(height: layout.upperCloudLift + layout.tubeHeight + layout.lowerCloudDrop + cloud.height)
        .offset(y: -layout.upperCloudLift)
        .opacity(0.92)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    /// One cloud with its top-left corner at `origin`, a hard-edged square per pixel.
    private static func draw(at origin: CGPoint, in context: inout GraphicsContext) {
        let scale = WorldFlyingClouds.scale
        // Bounded: the cloud's five rows of sixteen.
        for (y, row) in WorldFlyingClouds.rows.enumerated() {
            for (x, key) in row.enumerated() where key != "." {
                let rect = CGRect(x: origin.x + CGFloat(x) * scale, y: origin.y + CGFloat(y) * scale, width: scale, height: scale)
                context.fill(Path(rect), with: .color(key == "c" ? WorldFlyingPalette.cloudShade : WorldFlyingPalette.cloud))
            }
        }
    }
}
