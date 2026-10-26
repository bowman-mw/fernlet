import CryptoKit
import Foundation
import Testing
import UIKit
import FernletScoring
@testable import Fernlet
@testable import PrivateMediaStore

/// The solo camera's photos in the Friends album (lane friends-solo; `b4-mem-solo-waiting`,
/// `b4-mem-solo-revealed`, `b4-mem-solo-open`, approved 2026-10-24): the "Tonight" count of held
/// shots, the "Just you" sets newest first, delete and favorite, search, the decoy, and the map's
/// photo corner staying shared-only.
@MainActor
@Suite(.serialized)
struct SoloAlbumTests {

    // MARK: Fixtures

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    /// Asleep from 23:00 (bedtime 22:30, then the wind-down), awake at 07:00.
    private static let night = CompanionSleepWindow(bedtimeMinute: 22 * 60 + 30, wakeMinute: 7 * 60)

    private static func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute)) ?? .distantPast
    }

    private static func scratch() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("SoloAlbumTests-\(UUID().uuidString)", isDirectory: true)
    }

    private static func remove(_ url: URL) {
        do { try FileManager.default.removeItem(at: url) } catch { /* already gone */ }
    }

    private static func jpeg() throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 60, height: 75), format: format).image { context in
            UIColor.systemGreen.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 60, height: 75))
        }
        return try #require(image.jpegData(compressionQuality: 0.8))
    }

    private static func roll(_ directory: URL, key: SymmetricKey, decoy: Bool = false) -> SoloCameraRoll {
        let roll = SoloCameraRoll(store: SoloCameraPhotoStore(directory: directory,
                                                              keyProvider: InMemoryPrivateMediaKeyProvider(key: key)),
                                  isDecoy: decoy)
        roll.refresh()
        return roll
    }

    private func shoot(_ roll: SoloCameraRoll, at date: Date) throws {
        #expect(roll.takePhoto(try Self.jpeg(), at: date, window: Self.night, calendar: Self.calendar) == .kept)
    }

    /// A stand-in hangout post: an id and when it happened.
    private struct Post: Identifiable {
        let id = UUID()
        let date: Date
    }

    // MARK: Waiting

    /// Before bedtime the album counts today's held shots ("Tonight · 3 photos") and shows no set; the
    /// count says when the next one is due; after the companion falls asleep they are one set.
    @Test func theTonightTileCountsTodaysHeldShots() throws {
        let directory = Self.scratch()
        defer { Self.remove(directory) }
        let roll = Self.roll(directory, key: SymmetricKey(size: .bits256))
        try shoot(roll, at: Self.at(24, 10))
        try shoot(roll, at: Self.at(24, 11))
        try shoot(roll, at: Self.at(24, 12))

        let album = SoloAlbumModel()
        album.refresh(roll: roll, now: Self.at(24, 13))
        #expect(album.heldCount == 3)
        #expect(album.sets.isEmpty, "nothing shows before the companion sleeps")
        #expect(album.nextRevealAt == Self.at(24, 23))
        #expect(!album.isEmpty)

        album.refresh(roll: roll, now: Self.at(24, 23))
        #expect(album.heldCount == 0)
        #expect(album.nextRevealAt == nil)
        #expect(album.sets.map(\.photos.count) == [3], "the day's shots become one set")
    }

    // MARK: Revealed, newest first

    /// Each day is a set; sets come newest first, photos within a set newest first, the newest is the
    /// cover; and the sets slot in among the hangouts by date, the hangouts keeping their order.
    @Test func theSetsShowNewestFirstAmongTheHangouts() throws {
        let directory = Self.scratch()
        defer { Self.remove(directory) }
        let roll = Self.roll(directory, key: SymmetricKey(size: .bits256))
        try shoot(roll, at: Self.at(23, 10))
        try shoot(roll, at: Self.at(23, 11))
        try shoot(roll, at: Self.at(24, 9))
        let album = SoloAlbumModel()
        album.refresh(roll: roll, now: Self.at(25, 0))

        #expect(album.sets.map(\.id) == ["solo-2026-10-24", "solo-2026-10-23"])
        let older = try #require(album.sets.last)
        #expect(older.photos.map(\.takenAt) == [Self.at(23, 11), Self.at(23, 10)])
        #expect(older.cover.takenAt == Self.at(23, 11) && older.isCarousel)

        let posts = [Post(date: Self.at(24, 12)), Post(date: Self.at(23, 12)), Post(date: Self.at(22, 12))]
        let entries = SoloAlbum.merged(posts: posts, date: \.date, sets: album.sets)
        #expect(entries.map(\.id) == ["post-\(posts[0].id.uuidString)", "solo-2026-10-24",
                                      "post-\(posts[1].id.uuidString)", "solo-2026-10-23",
                                      "post-\(posts[2].id.uuidString)"])
        #expect(SoloAlbum.merged(posts: [Post](), date: \.date, sets: album.sets).map(\.id)
                == ["solo-2026-10-24", "solo-2026-10-23"])
    }

    // MARK: Delete and favorite

    /// Delete removes the sealed photo and its files, an emptied set goes, and no film comes back.
    @Test func deleteRemovesTheSealedPhoto() throws {
        let directory = Self.scratch()
        defer { Self.remove(directory) }
        let roll = Self.roll(directory, key: SymmetricKey(size: .bits256))
        try shoot(roll, at: Self.at(24, 10))
        try shoot(roll, at: Self.at(24, 11))
        let album = SoloAlbumModel()
        album.refresh(roll: roll, now: Self.at(24, 23, 30))
        let set = try #require(album.sets.first)
        let first = try #require(set.photos.first)

        #expect(album.delete(first.id, now: Self.at(24, 23, 30)))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("Photos/\(first.id.uuidString).jpg").path))
        #expect(album.sets.first?.photos.count == 1)
        #expect(album.imageData(for: first.id) == nil)
        let last = try #require(album.sets.first?.photos.first)
        #expect(album.delete(last.id, now: Self.at(24, 23, 30)))
        #expect(album.sets.isEmpty && album.isEmpty, "the emptied set is gone")
        #expect(roll.shotsLeft(at: Self.at(24, 23, 40)) == 8, "deleting never gives film back")
    }

    /// Favorite makes a photo its set's cover, sealed in the index; tapping it again clears it.
    @Test func aFavoriteBecomesTheCoverAndClears() throws {
        let directory = Self.scratch()
        defer { Self.remove(directory) }
        let key = SymmetricKey(size: .bits256)
        let roll = Self.roll(directory, key: key)
        try shoot(roll, at: Self.at(24, 10))
        try shoot(roll, at: Self.at(24, 11))
        let album = SoloAlbumModel()
        album.refresh(roll: roll, now: Self.at(25, 1))
        let set = try #require(album.sets.first)
        let older = try #require(set.photos.last)

        #expect(album.toggleFavorite(older.id, in: set, now: Self.at(25, 1)))
        #expect(album.sets.first?.cover.id == older.id)
        let fresh = SoloAlbumModel()
        fresh.refresh(roll: Self.roll(directory, key: key), now: Self.at(25, 2))
        #expect(fresh.sets.first?.cover.id == older.id, "the favorite is sealed, not remembered in memory")

        let marked = try #require(album.sets.first)
        #expect(album.toggleFavorite(older.id, in: marked, now: Self.at(25, 1)))
        #expect(album.sets.first?.cover.id == marked.photos.first?.id, "cleared: the newest is the cover again")
    }

    // MARK: Search and the decoy

    /// Search finds the sets by "Just you", the way it finds a session by its name.
    @Test func searchFindsJustYou() {
        #expect(SoloAlbum.matches(""))
        #expect(SoloAlbum.matches("  "))
        #expect(SoloAlbum.matches("just"))
        #expect(SoloAlbum.matches("Just you"))
        #expect(SoloAlbum.matches("YOU"))
        #expect(!SoloAlbum.matches("Sam"))
        #expect(!SoloAlbum.matches("picnic"))
    }

    /// A decoy shows none of it: no set, no count — not the real photos, and not its own shots.
    @Test func aDecoyShowsNoneOfIt() throws {
        let directory = Self.scratch()
        defer { Self.remove(directory) }
        let key = SymmetricKey(size: .bits256)
        try shoot(Self.roll(directory, key: key), at: Self.at(23, 10))
        try shoot(Self.roll(directory, key: key), at: Self.at(24, 22))
        let album = SoloAlbumModel()
        album.refresh(roll: Self.roll(directory, key: key), now: Self.at(24, 22, 30))
        #expect(album.sets.count == 1 && album.heldCount == 1, "precondition: the real album has both")

        album.refresh(roll: nil, now: Self.at(24, 22, 30))
        #expect(album.isEmpty && album.nextRevealAt == nil, "the page passes no roll in a decoy")
        let decoy = Self.roll(directory, key: key, decoy: true)
        try shoot(decoy, at: Self.at(24, 22, 40))
        album.refresh(roll: decoy, now: Self.at(25, 1))
        #expect(album.isEmpty, "a decoy roll shows nothing either")
        #expect(album.thumbnailData(for: UUID()) == nil)
    }

    // MARK: The map's photo corner

    /// The map's photo corner stays shared-only: it reads the friends' wall and nothing of the solo
    /// camera, so a solo photo never reaches the map.
    @Test func thePhotoCornerStaysSharedOnly() throws {
        let corner = try RepoRoot.source("App/Fernlet/World/Home/WorldPhotoPrints.swift")
        for token in ["SoloCamera", "soloPhotos", "SoloAlbum", "soloCamera"] {
            #expect(!corner.contains(token), "the photo corner names \(token)")
        }
        #expect(corner.contains("meshFeatures.photos"), "it reads the friends' wall")
    }
}
