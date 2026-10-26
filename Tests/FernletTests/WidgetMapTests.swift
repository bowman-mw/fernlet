import FernletDomainModel
import Foundation
import Testing
import WorldMapStore
@testable import Fernlet

/// The map widget (owner's Q36, `b4-new-map`, round 6b): its picture never reaches a backup, is locked away
/// with the phone, goes with every wipe, "Delete map history" and a decoy's start, carries only marked places
/// and saved trails (never history), and the two processes agree on its format.
@MainActor
struct WidgetMapTests {
    nonisolated private static let here = GeoPoint(45.5205, -122.6255)
    nonisolated private static let now = Date(timeIntervalSince1970: 2_000_000_000)

    /// A picture the size rules accept.
    static func picture(at date: Date = now) -> WorldWidgetMapPicture {
        WorldWidgetMapPicture(version: WorldWidgetMapPicture.currentVersion, takenAt: date,
                              light: Data(repeating: 1, count: 64), dark: Data(repeating: 2, count: 64))
    }

    /// A picture file in a folder of its own.
    static func file() -> WorldWidgetMapFile {
        WorldWidgetMapFile(directory: uniqueAppGroupDirectory())
    }

    /// Whether the file at `url` carries the backup exclusion.
    static func isExcludedFromBackup(_ url: URL) throws -> Bool {
        var fresh = url
        fresh.removeAllCachedResourceValues()
        return try fresh.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true
    }

    // MARK: The file

    /// Never in a backup: the flag is set on every write, so an atomic rewrite (which replaces the file and
    /// drops it) can't let a copy slip into one.
    @Test func thePictureIsExcludedFromBackupAfterEveryWrite() throws {
        let file = Self.file()
        #expect(file.write(Self.picture()))
        #expect(try Self.isExcludedFromBackup(file.fileURL))
        var cleared = URLResourceValues()
        cleared.isExcludedFromBackup = false
        var url = file.fileURL
        try url.setResourceValues(cleared)
        #expect(try Self.isExcludedFromBackup(file.fileURL) == false)
        #expect(file.write(Self.picture(at: Self.now.addingTimeInterval(60))))
        #expect(try Self.isExcludedFromBackup(file.fileURL), "the second write re-sets the flag")
        #expect(file.read() == Self.picture(at: Self.now.addingTimeInterval(60)))
    }

    /// Locked away with the phone: the picture is written with complete file protection (the simulator
    /// doesn't enforce classes, so the write's own option is pinned).
    @Test func thePictureIsWrittenWithCompleteProtection() throws {
        let source = try RepoRoot.source("App/Fernlet/World/Widget/WorldWidgetMapFile.swift")
        #expect(source.contains("try data.write(to: url, options: [.atomic, .completeFileProtection])"))
        #expect(!source.contains("completeFileProtectionUntilFirstUserAuthentication"))
    }

    /// Only a well-formed picture is written; a missing file deletes as gone.
    @Test func onlyAWellFormedPictureIsWritten() {
        let file = Self.file()
        var wrongVersion = Self.picture()
        wrongVersion.version = 2
        #expect(!file.write(wrongVersion))
        var empty = Self.picture()
        empty.dark = Data()
        #expect(!file.write(empty))
        var huge = Self.picture()
        huge.light = Data(count: WorldWidgetMap.maxBytes)
        #expect(!file.write(huge))
        #expect(!file.exists)
        #expect(file.delete(), "nothing to delete is gone already")
    }

    // MARK: The wipes and the decoy

    /// Every wipe, the recovery lock and "Delete map history" reach `WorldFogKeeper.clearAll()`: it takes the
    /// picture with the history, reloads the widget and moves the generation.
    @Test func theWipeDeletesThePictureAndReloads() {
        let vault = WorldMapVault.ephemeral()
        let keeper = WorldFogKeeper(vault: vault)
        keeper.widgetMap = Self.file()
        var reloads = 0
        keeper.widgetMapReload = { reloads += 1 }
        #expect(keeper.widgetMap.write(Self.picture()))
        let generation = keeper.widgetMapGeneration
        #expect(keeper.clearAll())
        #expect(!keeper.widgetMap.exists)
        #expect(reloads == 1)
        #expect(keeper.widgetMapGeneration != generation)
    }

    /// A decoy's map widget has no map: entering one deletes the picture and reloads; leaving one doesn't.
    @Test func aDecoyReplacesThePictureWithNone() {
        let vault = WorldMapVault.ephemeral()
        defer { _ = vault.clearAll() }
        let keeper = WorldFogKeeper(vault: vault)
        keeper.widgetMap = Self.file()
        var reloads = 0
        keeper.widgetMapReload = { reloads += 1 }
        #expect(keeper.widgetMap.write(Self.picture()))
        keeper.setDecoy(true)
        #expect(!keeper.widgetMap.exists)
        #expect(reloads == 1)
        keeper.setDecoy(false)
        #expect(reloads == 1, "the real session's next map draws a new one")
    }

    /// Through the real store: "Delete map history", Delete everything's reset and the decoy flag.
    @Test func theStoresFunnelsDeleteThePicture() {
        let store = makeTestStore()
        let file = Self.file()
        store.worldFog.widgetMap = file
        store.worldFog.widgetMapReload = {}
        #expect(file.write(Self.picture()))
        #expect(store.deleteWorldMapHistory())
        #expect(!file.exists, "Delete map history")
        #expect(file.write(Self.picture()))
        _ = store.resetAll()
        #expect(!file.exists, "Delete everything and the silent wipe")
        #expect(file.write(Self.picture()))
        store.duressSessionActive = true
        #expect(!file.exists, "a decoy")
        store.duressSessionActive = false
    }

    // MARK: When a picture is drawn

    /// The schedule: none yet, then a changed place or line (after a minute), then a move of 200 m or an
    /// hour, never closer than five minutes otherwise.
    @Test func theScheduleKeepsPicturesRare() {
        let last = WorldWidgetMapSchedule.Last(center: Self.here, at: Self.now, stamp: 7)
        let soon = Self.now.addingTimeInterval(30), later = Self.now.addingTimeInterval(120)
        let much = Self.now.addingTimeInterval(400), hour = Self.now.addingTimeInterval(3_700)
        let far = Self.here.offset(east: 250, north: 0), near = Self.here.offset(east: 50, north: 0)
        func write(_ last: WorldWidgetMapSchedule.Last?, exists: Bool = true, at center: GeoPoint, stamp: Int = 7, _ now: Date) -> Bool {
            WorldWidgetMapSchedule.shouldWrite(last: last, pictureExists: exists, center: center, stamp: stamp, now: now)
        }
        #expect(write(nil, at: Self.here, Self.now), "none yet")
        #expect(write(last, exists: false, at: Self.here, soon), "the picture was deleted")
        #expect(!write(last, at: Self.here, stamp: 8, soon), "never twice in a minute")
        #expect(write(last, at: Self.here, stamp: 8, later), "a place or a line changed")
        #expect(!write(last, at: far, later), "a move waits five minutes")
        #expect(write(last, at: far, much), "then follows the person")
        #expect(!write(last, at: near, much), "a short move doesn't")
        #expect(write(last, at: near, hour), "an hour-old picture is drawn again")
    }

    /// Only a fresh, precise reading, and never in a decoy, during Delete everything or a walk.
    @Test func onlyAFreshPreciseReadingOutsideADecoyIsDrawn() {
        let fix = WorldFix(point: Self.here, accuracy: 10, at: Self.now, isPrecise: true)
        let center = { (fix: WorldFix?, decoy: Bool, wiping: Bool, walking: Bool, now: Date) in
            WorldWidgetMapWriter.center(of: fix, decoy: decoy, wiping: wiping, walking: walking, now: now)
        }
        #expect(center(fix, false, false, false, Self.now) == Self.here)
        #expect(center(fix, true, false, false, Self.now) == nil, "a decoy")
        #expect(center(fix, false, true, false, Self.now) == nil, "Delete everything")
        #expect(center(fix, false, false, true, Self.now) == nil, "a walk")
        #expect(center(nil, false, false, false, Self.now) == nil, "no reading")
        #expect(center(WorldFix(point: Self.here, accuracy: 10, at: Self.now, isPrecise: false), false, false, false, Self.now) == nil,
                "approximate location")
        #expect(center(fix, false, false, false, Self.now.addingTimeInterval(700)) == nil, "a stale reading")
    }

    /// The person removed the map widget: its picture goes; with no reading nothing new is drawn.
    @Test func aRemovedWidgetsPictureGoes() async {
        let store = makeTestStore()
        let file = Self.file()
        #expect(file.write(Self.picture()))
        let removed = WorldWidgetMapWriter(file: file, isInstalled: { false })
        await removed.refresh(store: store, now: Self.now)
        #expect(!file.exists)
        let installed = WorldWidgetMapWriter(file: file, isInstalled: { true })
        await installed.refresh(store: store, now: Self.now)
        #expect(!file.exists, "no reading this session: nothing is drawn")
    }

    // MARK: What the picture draws

    /// Marked places and saved trails only: a home in the picture is drawn and moves the stamp; a decoy
    /// draws nothing and stamps nothing.
    @Test func thePictureDrawsMarkedPlacesAndNothingInADecoy() {
        let store = makeTestStore()
        let viewport = MapViewport.around(Self.here, heightMetres: 420, size: WorldWidgetMap.pictureSize)
        let before = store.worldWidgetMapStamp(now: Self.now)
        #expect(store.worldWidgetMapContent(in: viewport, now: Self.now) == .empty)
        let home = HomePlace(kind: .home, label: "Home", point: Self.here.offset(east: 40, north: 30))
        #expect(store.saveWorldHome(home))
        let content = store.worldWidgetMapContent(in: viewport, now: Self.now)
        #expect(content.homes.map(\.id) == [home.id])
        #expect(content.places.allSatisfy { $0.photos == nil && $0.name.isEmpty }, "no photos, no names")
        #expect(store.worldWidgetMapStamp(now: Self.now) != before)
        let elsewhere = MapViewport.around(Self.here.offset(east: 5_000, north: 0), heightMetres: 420, size: WorldWidgetMap.pictureSize)
        #expect(store.worldWidgetMapContent(in: elsewhere, now: Self.now).homes.isEmpty, "only what is in the picture")
        store.duressSessionActive = true
        #expect(store.worldWidgetMapContent(in: viewport, now: Self.now) == .empty)
        #expect(store.worldWidgetMapStamp(now: Self.now) == 0)
        store.duressSessionActive = false
    }

    /// A trail is thinned for the picture, kept only when it crosses it, and at most 400 points.
    @Test func aTrailIsThinnedAndKeptOnlyWhenItCrossesThePicture() {
        let viewport = MapViewport.around(Self.here, heightMetres: 420, size: WorldWidgetMap.pictureSize)
        let line = (0..<2_000).map { Self.here.offset(east: Double($0) * 0.2, north: 0) }
        let drawn = WorldWidgetMapContent.drawable(line, in: viewport, size: WorldWidgetMap.pictureSize)
        #expect((drawn?.count ?? 0) >= 2 && (drawn?.count ?? 0) <= WorldWidgetMapContent.maxTrailPoints)
        #expect(drawn?.first == line.first && drawn?.last == line.last)
        let away = line.map { $0.offset(east: 9_000, north: 0) }
        #expect(WorldWidgetMapContent.drawable(away, in: viewport, size: WorldWidgetMap.pictureSize) == nil)
    }

    // MARK: The two processes

    /// The widget reads what the app writes: the same kind, file name and property-list keys, and the map
    /// widget is `.privacySensitive()` and reloads only while its picture opens.
    @Test func theWidgetAndTheAppAgree() throws {
        let widget = try RepoRoot.source("App/FernletWidgets/WidgetMapPicture.swift")
        let views = try RepoRoot.source("App/FernletWidgets/MapWidgetViews.swift")
        let bundle = try RepoRoot.source("App/FernletWidgets/FernletWidgetsBundle.swift")
        let intent = try RepoRoot.source("App/FernletWidgets/WaterPlusOneIntent.swift")
        #expect(bundle.contains("static let map = \"\(WorldWidgetMap.kind)\""))
        #expect(bundle.contains("FernletMapWidget()"))
        #expect(widget.contains("static let fileName = \"\(WorldWidgetMap.fileName)\""))
        for field in ["var version: Int", "var takenAt: Date", "var light: Data", "var dark: Data"] {
            #expect(widget.contains(field), "the widget's twin lost \(field)")
        }
        #expect(views.contains(".privacySensitive()"))
        #expect(intent.contains("if WidgetMapPictureStore().mayReload"))
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let plist = try PropertyListSerialization.propertyList(from: encoder.encode(Self.picture()), format: nil)
        #expect(Set((plist as? [String: Any])?.keys.map { $0 } ?? []) == ["version", "takenAt", "light", "dark"])
        #expect(WidgetSnapshotMirror.mapWidgetKind == WorldWidgetMap.kind)
    }

    /// The snapshot's macro targets for the plate's bars are the store's own, in grams.
    @Test func theSnapshotsMacroTargetsAreTheDays() {
        let store = makeTestStore()
        let targets = store.widgetMacroTargets()
        #expect(targets.protein == Double(store.nutritionTargets.protein))
        #expect(targets.carbs == Double(store.nutritionTargets.carbs))
        #expect(targets.fat == Double(store.nutritionTargets.fat))
    }

    /// The store publishes the day's macro targets with every snapshot.
    @Test func theStorePublishesTheMacroTargets() {
        let store = makeTestStore()
        #expect(store.currentWidgetSnapshot().macroTargets == store.widgetMacroTargets())
    }

    /// A store's fog keeper deletes the picture in that store's own app-group folder, so a test store's
    /// wipes never reach the test host's real group folder.
    @Test func theKeepersPictureIsTheStoresOwn() {
        let directory = uniqueAppGroupDirectory()
        let store = makeTestStore(appGroupDirectory: directory)
        #expect(store.worldFog.widgetMap.fileURL == WorldWidgetMapFile(directory: directory).fileURL)
    }
}
