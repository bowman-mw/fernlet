import FernletFoundation
import SwiftUI
import UIKit
import WidgetKit
import WorldMapStore

/// When the map widget's picture is drawn again (owner's Q36, round 6b): pure, so the rules are tested
/// as a table.
///
/// A picture is drawn when there is none yet, when a marked place or a saved line was added or removed
/// (at most once a minute), and otherwise only every ``minimumGap`` at the most: when the person has
/// moved ``moveMetres`` from where the last one was centred, or it is ``refreshAfter`` old. Each picture
/// asks Apple's map for the area around the person twice (light and dark), so the rule keeps that rare.
enum WorldWidgetMapSchedule {
    /// Never two pictures closer together than this, whatever changed.
    static let floorGap: TimeInterval = 60
    /// The usual least time between two pictures.
    static let minimumGap: TimeInterval = 300
    /// A picture this old is drawn again, even standing still.
    static let refreshAfter: TimeInterval = 3_600
    /// How far the person moves before the picture follows, in metres.
    static let moveMetres = 200.0

    /// The last picture written: where it was centred, when, and the stamp of what it could draw.
    struct Last: Equatable {
        let center: GeoPoint
        let at: Date
        let stamp: Int
    }

    /// Whether to draw a new picture now.
    static func shouldWrite(last: Last?, pictureExists: Bool, center: GeoPoint, stamp: Int, now: Date) -> Bool {
        guard let last, pictureExists else { return true }
        let elapsed = now.timeIntervalSince(last.at)
        guard elapsed >= floorGap else { return false }
        if stamp != last.stamp { return true }
        guard elapsed >= minimumGap else { return false }
        return elapsed >= refreshAfter || last.center.distance(to: center) >= moveMetres
    }
}

/// Draws the map widget's picture and hands it to the widget (owner's Q36, `b4-new-map`): the map around
/// the person (``AppleMapSnapshot``) with their marked places and saved trails (``WorldWidgetMapContent``),
/// light and dark, into ``WorldWidgetMapFile``.
///
/// **Only when the person added the map widget** (WidgetKit's list of the installed widgets): with none,
/// nothing is drawn and a picture left from before is deleted. **Only while the World Home's map is on
/// screen, following the person**, with a precise reading, not during a walk (``refresh(store:now:)``'s
/// caller, ``WorldWidgetMapRefresh``), so Apple's map is asked for no area the live map isn't already
/// showing. **Never in a decoy**, never while Delete everything runs, and a picture rendered across a wipe,
/// "Delete map history" or a decoy's start is thrown away (`WorldFogKeeper.widgetMapGeneration`).
@MainActor
final class WorldWidgetMapWriter {
    /// The last picture this writer wrote (memory only: no coordinate is kept anywhere else).
    private(set) var last: WorldWidgetMapSchedule.Last?
    private var isWriting = false
    private let file: WorldWidgetMapFile
    private let isInstalled: @MainActor () async -> Bool

    /// A writer over `file` (nil: the app group's), asking `isInstalled` whether a map widget was added.
    init(file: WorldWidgetMapFile? = nil, isInstalled: (@MainActor () async -> Bool)? = nil) {
        self.file = file ?? WorldWidgetMapFile()
        self.isInstalled = isInstalled ?? { await Self.mapWidgetIsInstalled() }
    }

    /// Draws and writes a new picture when ``WorldWidgetMapSchedule`` says so.
    func refresh(store: FernletStore, now: Date = Date()) async {
        guard !isWriting else { return }
        isWriting = true
        defer { isWriting = false }
        guard await isInstalled() else {
            removeLeftoverPicture()
            return
        }
        guard let center = Self.eligibleCenter(store, now: now) else { return }
        let stamp = store.worldWidgetMapStamp(now: now)
        guard WorldWidgetMapSchedule.shouldWrite(last: last, pictureExists: file.exists, center: center, stamp: stamp, now: now) else { return }
        let generation = store.worldFog.widgetMapGeneration
        guard let picture = await Self.render(store: store, center: center, now: now) else { return }
        // A wipe, "Delete map history" or a decoy may have begun while the map was drawn: then this picture
        // is of what was deleted, and is never written.
        guard store.worldFog.widgetMapGeneration == generation, Self.eligibleCenter(store, now: now) != nil else { return }
        guard file.write(picture) else { return }
        WorldWidgetMap.reload()
        last = WorldWidgetMapSchedule.Last(center: center, at: now, stamp: stamp)
    }

    /// Where the picture is centred now (the person, precisely), or nil when none may be drawn.
    static func eligibleCenter(_ store: FernletStore, now: Date) -> GeoPoint? {
        center(of: store.worldLocation.latest, decoy: store.duressSessionActive, wiping: store.deleteAllInProgress,
               walking: store.worldLocation.isWalking, now: now)
    }

    /// The pure rule behind ``eligibleCenter(_:now:)``: `fix`'s point when it is precise, valid and under
    /// ten minutes old, and no decoy is open, Delete everything isn't running and no walk is recording.
    static func center(of fix: WorldFix?, decoy: Bool, wiping: Bool, walking: Bool, now: Date) -> GeoPoint? {
        guard !decoy, !wiping, !walking, let fix, fix.isPrecise, fix.point.isValid,
              now.timeIntervalSince(fix.at) < 600 else { return nil }
        return fix.point
    }

    /// Both pictures of the area round `center` and the one-colour drawing, or nil when Apple's map can't be
    /// had (offline).
    private static func render(store: FernletStore, center: GeoPoint, now: Date) async -> WorldWidgetMapPicture? {
        let size = WorldWidgetMap.pictureSize, scale = WorldWidgetMap.pictureScale
        let viewport = MapViewport.around(center, heightMetres: Double(size.height) * WorldWidgetMap.metresPerPoint, size: size)
        let content = store.worldWidgetMapContent(in: viewport, now: now)
        guard let lightBase = await AppleMapSnapshot.image(of: viewport, size: size, scale: scale, dark: false),
              let darkBase = await AppleMapSnapshot.image(of: viewport, size: size, scale: scale, dark: true),
              let light = WorldWidgetMapCanvas.png(base: lightBase, viewport: viewport, content: content, dark: false, size: size, scale: scale),
              let dark = WorldWidgetMapCanvas.png(base: darkBase, viewport: viewport, content: content, dark: true, size: size, scale: scale)
        else { return nil }
        // The one-colour drawing comes from the same light map: no third request to Apple. Without it the
        // tinted and clear Home Screens show the plain ground, and the colour pictures still go.
        let mono = WorldWidgetMonoCanvas.png(base: lightBase, viewport: viewport, content: content, size: size, scale: scale)
        return WorldWidgetMapPicture(version: WorldWidgetMapPicture.currentVersion, takenAt: now, light: light, dark: dark, mono: mono)
    }

    /// The person removed the map widget: its picture goes too.
    private func removeLeftoverPicture() {
        last = nil
        guard file.exists else { return }
        if !file.delete() { FernletAuditLog.log("worldMap.widgetMap.leftoverDeleteFailed") }
    }

    /// Whether a map widget is on the Home Screen (DEBUG `widgetMap` says yes, for screenshots).
    static func mapWidgetIsInstalled() async -> Bool {
        if UITestSupport.worldHomeScenes.contains("widgetMap") { return true }
        do {
            return try await WidgetCenter.shared.currentConfigurations().contains { $0.kind == WorldWidgetMap.kind }
        } catch {
            return false
        }
    }
}

/// Keeps the map widget's picture fresh while the World Home's map is in front (round 6b): every time the
/// map comes to the front, each time the person crosses into a new ~50 m square, and every five minutes
/// meanwhile, it asks ``WorldWidgetMapWriter`` (which decides, and usually does nothing).
struct WorldWidgetMapRefresh: ViewModifier {
    var store: FernletStore
    /// Whether the map is on screen, the app active, Apple's map under it and following the person.
    let isActive: Bool
    @State private var writer = WorldWidgetMapWriter()

    /// The most beats one stretch in front runs (a day of five-minute beats).
    static let maxBeats = 288

    func body(content: Content) -> some View {
        content.task(id: Trigger(active: isActive, square: Self.square(of: store.worldLocation.latest?.point))) {
            await keepFresh()
        }
    }

    /// What restarts the beat: the map coming to the front or going, and a new square.
    struct Trigger: Equatable {
        let active: Bool
        let square: Int
    }

    /// The ~50 m square `point` falls in, as one number (0 without a reading).
    static func square(of point: GeoPoint?) -> Int {
        guard let point, point.isValid else { return 0 }
        return Int((point.latitude * 2_000).rounded()) &* 1_000_003 &+ Int((point.longitude * 2_000).rounded())
    }

    /// Asks the writer now and every few minutes while the map stays in front.
    private func keepFresh() async {
        guard isActive else { return }
        for _ in 0..<Self.maxBeats {
            await writer.refresh(store: store)
            do {
                try await Task.sleep(for: .seconds(WorldWidgetMapSchedule.minimumGap))
            } catch {
                return
            }
        }
    }
}

extension View {
    /// Keeps the map widget's picture fresh while `isActive` (``WorldWidgetMapRefresh``).
    func worldWidgetMap(store: FernletStore, isActive: Bool) -> some View {
        modifier(WorldWidgetMapRefresh(store: store, isActive: isActive))
    }
}
