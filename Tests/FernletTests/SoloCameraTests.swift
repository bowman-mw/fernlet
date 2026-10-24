import CryptoKit
import Foundation
import ImageIO
import Testing
import UIKit
import UniformTypeIdentifiers
import FernletScoring
@testable import Fernlet
@testable import FernletCrypto
@testable import PrivateMediaStore

/// The disposable camera on your own (World build, lane friends-solo; owner 2026-10-24: "I think the
/// photos can be saved in the friend area" — ten photos a day, no Develop step, the photos appear
/// after the companion sleeps): the sealed device-only corpus, the day's film, the reveal at the
/// companion's sleep, the decoy that keeps nothing, and the wipes.
@MainActor
@Suite(.serialized)
struct SoloCameraTests {

    // MARK: Fixtures

    /// The local Gregorian calendar the film's day key is read in (`FernletDate` uses the device's
    /// time zone), so a fixture date and the film agree on which day it is.
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    /// The standard night: sleepy at 22:30, asleep from 23:00, awake at 07:00.
    private static let night = CompanionSleepWindow(bedtimeMinute: 22 * 60 + 30, wakeMinute: 7 * 60)

    /// 2026-10-`day` at `hour`:`minute`, local.
    private static func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute)) ?? .distantPast
    }

    private static func scratch() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("SoloCameraTests-\(UUID().uuidString)", isDirectory: true)
    }

    private static func remove(_ url: URL) {
        do { try FileManager.default.removeItem(at: url) } catch { /* already gone */ }
    }

    /// A small real JPEG, as the camera would hand over.
    private static func jpeg() throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 48), format: format).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        }
        return try #require(image.jpegData(compressionQuality: 0.8))
    }

    private static func store(_ directory: URL, key: SymmetricKey) -> SoloCameraPhotoStore {
        SoloCameraPhotoStore(directory: directory, keyProvider: InMemoryPrivateMediaKeyProvider(key: key))
    }

    private static func roll(_ directory: URL, key: SymmetricKey, decoy: Bool = false) -> SoloCameraRoll {
        let roll = SoloCameraRoll(store: store(directory, key: key), isDecoy: decoy)
        roll.refresh()
        return roll
    }

    private func shoot(_ roll: SoloCameraRoll, at date: Date) throws -> SoloShotOutcome {
        roll.takePhoto(try Self.jpeg(), at: date, window: Self.night, calendar: Self.calendar)
    }

    private func loadedIndex(_ store: SoloCameraPhotoStore) throws -> SoloCameraIndex {
        guard case .loaded(let index) = store.load() else {
            Issue.record("the solo index did not load")
            throw CancellationError()
        }
        return index
    }

    /// Every file under `directory` with its bytes, for "nothing was written" checks.
    private static func snapshot(_ directory: URL) -> [String: Data] {
        guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else { return [:] }
        var files: [String: Data] = [:]
        for case let url as URL in walker {
            guard let data = try? Data(contentsOf: url) else { continue }
            files[url.lastPathComponent] = data
        }
        return files
    }

    // MARK: Sealed, device-only

    /// A shot is sealed the moment it is taken: the bytes and the index on disk are ciphertext, they
    /// open back under the key, and the folder is out of the device backup.
    @Test func aShotIsSealedTheMomentItIsTakenAndOpensBack() throws {
        let directory = Self.scratch()
        defer { Self.remove(directory) }
        let key = SymmetricKey(size: .bits256)
        #expect(try shoot(Self.roll(directory, key: key), at: Self.at(24, 14)) == .kept)

        let index = try loadedIndex(Self.store(directory, key: key))
        let photo = try #require(index.photos.first)
        #expect(index.photos.count == 1)
        #expect(photo.revealedAt == nil)
        let onDisk = try Data(contentsOf: directory.appendingPathComponent("Photos/\(photo.id.uuidString).jpg"))
        #expect(!onDisk.starts(with: [0xFF, 0xD8]), "the photo on disk is sealed, never a JPEG")
        let sealedIndex = try Data(contentsOf: directory.appendingPathComponent("SoloCameraIndex.sealed"))
        #expect(sealedIndex.range(of: Data("takenAt".utf8)) == nil, "the index on disk is sealed")

        let opened = try #require(Self.store(directory, key: key).imageData(for: photo.id))
        #expect(opened.starts(with: [0xFF, 0xD8]))
        #expect(UIImage(data: opened) != nil)
        #expect(Self.store(directory, key: key).thumbnailData(for: photo.id) != nil)
        let values = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true, "the solo corpus never reaches a device backup")
    }

    /// Under another key nothing opens, and a corpus that can never open again goes (how the duress
    /// wipe's crypto-erase ends: the row is swept, a fresh key is minted, the next read purges).
    @Test func aForeignKeyOpensNothingAndTheDeadCorpusGoes() throws {
        let directory = Self.scratch()
        defer { Self.remove(directory) }
        #expect(try shoot(Self.roll(directory, key: SymmetricKey(size: .bits256)), at: Self.at(24, 14)) == .kept)

        let fresh = SymmetricKey(size: .bits256)
        #expect(Self.store(directory, key: fresh).load() == .unrecoverable(purged: true))
        #expect(!FileManager.default.fileExists(atPath: directory.path), "the unopenable corpus is removed whole")
        let roll = Self.roll(directory, key: fresh)
        #expect(roll.shotsLeft(at: Self.at(24, 15)) == SoloCameraRules.photosPerDay)
        #expect(try shoot(roll, at: Self.at(24, 15)) == .kept, "the camera works again under the new key")
    }

    /// The camera's metadata (a location among it) never reaches the corpus: a shot is re-encoded.
    @Test func aShotLeavesTheCamerasMetadataBehind() throws {
        let image = try #require(UIImage(data: try Self.jpeg())?.cgImage)
        let tagged = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(tagged, UTType.jpeg.identifier as CFString, 1, nil))
        let gps: [CFString: Any] = [kCGImagePropertyGPSLatitude: 45.52, kCGImagePropertyGPSLatitudeRef: "N",
                                    kCGImagePropertyGPSLongitude: 122.62, kCGImagePropertyGPSLongitudeRef: "W"]
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyGPSDictionary: gps] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        let source = try #require(CGImageSourceCreateWithData(tagged as CFData, nil))
        let before = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        #expect(before?[kCGImagePropertyGPSDictionary] != nil, "precondition: the fixture carries a location")

        let normalized = try #require(SoloCameraRoll.normalized(tagged as Data))
        let kept = try #require(CGImageSourceCreateWithData(normalized as CFData, nil))
        let after = CGImageSourceCopyPropertiesAtIndex(kept, 0, nil) as? [CFString: Any]
        #expect(after?[kCGImagePropertyGPSDictionary] == nil, "no location reaches the solo corpus")
    }

    // MARK: Ten a day

    /// Ten shots a local day, counted down; the eleventh keeps nothing; a new day brings new film; a
    /// second roll over the same corpus agrees, because the count is sealed on disk.
    @Test func theCameraCountsTenADayAndResetsEachDay() throws {
        let directory = Self.scratch()
        defer { Self.remove(directory) }
        let key = SymmetricKey(size: .bits256)
        let roll = Self.roll(directory, key: key)
        #expect(roll.shotsLeft(at: Self.at(24, 9)) == 10)
        for shot in 0..<10 {
            #expect(try shoot(roll, at: Self.at(24, 9, shot)) == .kept)
            #expect(roll.shotsLeft(at: Self.at(24, 9, shot)) == 9 - shot)
        }
        #expect(try shoot(roll, at: Self.at(24, 12)) == .noFilmLeft)
        #expect(roll.shotsLeft(at: Self.at(24, 23, 59)) == 0)
        #expect(try loadedIndex(Self.store(directory, key: key)).photos.count == 10, "the eleventh kept nothing")

        #expect(roll.shotsLeft(at: Self.at(25, 0, 1)) == 10, "a new local day, a new film")
        #expect(try shoot(roll, at: Self.at(25, 8)) == .kept)
        let again = Self.roll(directory, key: key)
        #expect(again.shotsLeft(at: Self.at(25, 9)) == 9)
        #expect(SoloCameraRules.shotsLeft(used: 14) == 0 && SoloCameraRules.shotsLeft(used: -3) == 10)
    }

    /// Deleting a photo never gives its film back, as on a real disposable camera.
    @Test func deletingAPhotoNeverGivesItsFilmBack() throws {
        let directory = Self.scratch()
        defer { Self.remove(directory) }
        let key = SymmetricKey(size: .bits256)
        let roll = Self.roll(directory, key: key)
        #expect(try shoot(roll, at: Self.at(24, 10)) == .kept)
        #expect(try shoot(roll, at: Self.at(24, 11)) == .kept)
        let store = Self.store(directory, key: key)
        let first = try #require(try loadedIndex(store).photos.last)
        #expect(store.delete(id: first.id))
        #expect(try loadedIndex(store).photos.count == 1)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("Photos/\(first.id.uuidString).jpg").path))
        roll.refresh()
        #expect(roll.shotsLeft(at: Self.at(24, 12)) == 8)
    }

    /// The corpus is bounded: past the cap a shot is refused, never an eviction.
    @Test func aFullCorpusRefusesRatherThanEvicts() throws {
        let directory = Self.scratch()
        defer { Self.remove(directory) }
        let key = SymmetricKey(size: .bits256)
        let provider = InMemoryPrivateMediaKeyProvider(key: key)
        let taken = Self.at(1, 12)
        let full = SoloCameraIndex(photos: (0..<SoloCameraPhotoStore.maxPhotos).map { _ in
            SoloCameraPhoto(takenAt: taken, revealsAt: taken)
        }, film: nil)
        let sealed = try #require(provider.gcmSeal(try JSONEncoder().encode(full),
                                                   purpose: FernletCryptoPurpose.AEAD.privateSoloCameraIndexV1))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try sealed.write(to: directory.appendingPathComponent(SoloCameraPhotoStore.indexFileName))

        let store = Self.store(directory, key: key)
        let shot = SoloCameraPhoto(takenAt: Self.at(24, 9), revealsAt: Self.at(24, 23))
        let normalized = try #require(SoloCameraRoll.normalized(try Self.jpeg()))
        #expect(store.add(shot, imageData: normalized, filmDay: "2026-10-24", dailyLimit: 10) == .full)
        #expect(try loadedIndex(store).photos.count == SoloCameraPhotoStore.maxPhotos)
    }

    // MARK: Shown after the companion sleeps

    /// When a shot shows: the first time the companion falls asleep after it (bedtime plus the
    /// wind-down), at once when it is already asleep, and the standard night when none is set.
    @Test func aShotShowsTheFirstTimeTheCompanionFallsAsleepAfterIt() {
        let rules = { (date: Date, window: CompanionSleepWindow) in
            SoloCameraRules.revealsAt(takenAt: date, window: window, calendar: Self.calendar)
        }
        #expect(rules(Self.at(24, 14), Self.night) == Self.at(24, 23), "an afternoon shot shows tonight")
        #expect(rules(Self.at(24, 22, 45), Self.night) == Self.at(24, 23), "the wind-down is not asleep yet")
        #expect(rules(Self.at(24, 23, 30), Self.night) == Self.at(24, 23, 30), "asleep already: it shows")
        #expect(rules(Self.at(25, 2), Self.night) == Self.at(25, 2), "after midnight, still asleep")
        #expect(rules(Self.at(25, 7, 30), Self.night) == Self.at(25, 23), "awake again: tonight's sleep")
        let empty = CompanionSleepWindow(bedtimeMinute: 9 * 60, wakeMinute: 9 * 60)
        #expect(rules(Self.at(24, 14), empty) == Self.at(24, 23), "no night set: the standard one")
        let late = CompanionSleepWindow(bedtimeMinute: 30, wakeMinute: 8 * 60)
        #expect(rules(Self.at(24, 23), late) == Self.at(25, 1), "a bedtime after midnight: the next 01:00")
    }

    /// A shot is held — not listed, no bytes handed out — until the companion sleeps; then it shows,
    /// is marked visible in the sealed index, and stays shown if the clock goes back.
    @Test func aShotIsHeldUntilTheCompanionSleepsThenShows() throws {
        let directory = Self.scratch()
        defer { Self.remove(directory) }
        let key = SymmetricKey(size: .bits256)
        let roll = Self.roll(directory, key: key)
        #expect(try shoot(roll, at: Self.at(24, 14)) == .kept)
        let id = try #require(try loadedIndex(Self.store(directory, key: key)).photos.first?.id)

        #expect(roll.photos(visibleAt: Self.at(24, 22, 59)).isEmpty, "held until the companion sleeps")
        #expect(roll.imageData(for: id) == nil && roll.thumbnailData(for: id) == nil, "a held photo is never drawn")

        #expect(roll.photos(visibleAt: Self.at(24, 23)).map(\.id) == [id])
        #expect(roll.imageData(for: id) != nil && roll.thumbnailData(for: id) != nil)
        #expect(try loadedIndex(Self.store(directory, key: key)).photos.first?.revealedAt == Self.at(24, 23),
                "marked visible in the sealed index")
        #expect(roll.photos(visibleAt: Self.at(24, 15)).map(\.id) == [id], "a clock set back keeps it shown")
    }

    // MARK: The decoy

    /// A decoy takes no real photo and sees none: its film is its own, its shots live in memory and
    /// write nothing, and they vanish when the decoy ends.
    @Test func aDecoyKeepsNothingAndSeesNothingReal() throws {
        let directory = Self.scratch()
        defer { Self.remove(directory) }
        let key = SymmetricKey(size: .bits256)
        #expect(try shoot(Self.roll(directory, key: key), at: Self.at(24, 9)) == .kept)
        let realID = try #require(try loadedIndex(Self.store(directory, key: key)).photos.first?.id)

        let decoy = Self.roll(directory, key: key, decoy: true)
        #expect(decoy.shotsLeft(at: Self.at(24, 10)) == 10, "the decoy's film is its own")
        #expect(decoy.photos(visibleAt: Self.at(25, 1)).isEmpty, "the decoy sees no real photo")
        #expect(decoy.imageData(for: realID) == nil)
        let before = Self.snapshot(directory)
        #expect(try shoot(decoy, at: Self.at(24, 10)) == .kept)
        #expect(decoy.shotsLeft(at: Self.at(24, 10)) == 9)
        #expect(Self.snapshot(directory) == before, "a decoy shot writes nothing")
        #expect(decoy.photos(visibleAt: Self.at(25, 1)).count == 1, "its own shot, in memory only")

        decoy.setDecoy(false)
        #expect(decoy.photos(visibleAt: Self.at(25, 1)).map(\.id) == [realID], "the decoy's shot is gone")
        #expect(decoy.shotsLeft(at: Self.at(24, 11)) == 9, "and the real film was never touched")
    }

    /// A decoy on a phone that never shot alone creates nothing on disk at all.
    @Test func aDecoyOnAFreshPhoneCreatesNothing() throws {
        let directory = Self.scratch()
        defer { Self.remove(directory) }
        let decoy = Self.roll(directory, key: SymmetricKey(size: .bits256), decoy: true)
        #expect(try shoot(decoy, at: Self.at(24, 9)) == .kept)
        _ = decoy.photos(visibleAt: Self.at(25, 1))
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    // MARK: The wipes

    /// Delete everything's leg on a real store (the solo key's real keychain row): the corpus and its
    /// film go, and the camera starts over with a full film.
    @Test func deleteEverythingsLegClearsTheCorpus() throws {
        let store = makeTestStore()
        defer { Self.remove(store.soloCameraDirectory) }
        let roll = store.soloCameraRoll()
        roll.refresh()
        #expect(roll.takePhoto(try Self.jpeg(), at: .now, window: Self.night, calendar: Self.calendar) == .kept)
        #expect(FileManager.default.fileExists(atPath: store.soloCameraDirectory.path))

        #expect(store.purgeSoloCameraForDeleteAll())
        #expect(!FileManager.default.fileExists(atPath: store.soloCameraDirectory.path))
        let after = store.soloCameraRoll()
        after.refresh()
        #expect(after.shotsLeft() == SoloCameraRules.photosPerDay)
        #expect(store.soloPhotos(visibleAt: .distantFuture).isEmpty)
    }

    /// The silent wipe's purge runs while the decoy is on screen, and still empties the real corpus.
    @Test func theWipeRunsFromInsideADecoyToo() throws {
        let directory = Self.scratch()
        defer { Self.remove(directory) }
        let key = SymmetricKey(size: .bits256)
        #expect(try shoot(Self.roll(directory, key: key), at: Self.at(24, 9)) == .kept)
        #expect(Self.roll(directory, key: key, decoy: true).purgeForDeleteAll())
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    /// The whole Delete everything funnel. Off until the integrator adds the leg to
    /// `deletePhotoCorpora` (`FernletStore.swift` is one writer's; lane friends-solo ledger, Need 1).
    @Test
    func deleteEverythingClearsTheSoloCorpus() async throws {
        let store = makeTestStore()
        defer { Self.remove(store.soloCameraDirectory) }
        let roll = store.soloCameraRoll()
        roll.refresh()
        #expect(roll.takePhoto(try Self.jpeg(), at: .now, window: Self.night, calendar: Self.calendar) == .kept)
        _ = await store.deleteAllData(includingHealthKitSamples: false)
        #expect(!FileManager.default.fileExists(atPath: store.soloCameraDirectory.path))
    }

    // MARK: Walls

    /// The frozen tokens: the folder, its files, the key row and the three sealed domains. Renaming
    /// any of them strands every solo photo behind a name nothing reads.
    @Test func theSoloCorpusNamesAreFrozen() {
        #expect(SoloCameraPhotoStore.directoryName == "SoloCameraPhotos")
        #expect(SoloCameraPhotoStore.photosDirectoryName == "Photos")
        #expect(SoloCameraPhotoStore.thumbnailsDirectoryName == "Thumbnails")
        #expect(SoloCameraPhotoStore.indexFileName == "SoloCameraIndex.sealed")
        #expect(KeychainPrivateMediaKeyProvider.soloCameraAccount == "com.fernlet.private-media.soloCameraContentKey")
        #expect(KeychainPrivateMediaKeyProvider.soloCameraAccount.hasPrefix(KeychainPrivateMediaKeyProvider.service))
        #expect(FernletCryptoPurpose.AEAD.privateSoloCameraPhotoImageV1.rawValue
                == "fernlet.private-media.solo-camera-photo.image.aead.v1")
        #expect(FernletCryptoPurpose.AEAD.privateSoloCameraPhotoThumbnailV1.rawValue
                == "fernlet.private-media.solo-camera-photo.thumbnail.aead.v1")
        #expect(FernletCryptoPurpose.AEAD.privateSoloCameraIndexV1.rawValue
                == "fernlet.private-media.solo-camera-photo.index.aead.v1")
    }

    /// Each store's corpus sits under its own proximity root, outside the own-photo layout (which is
    /// escrowed and backed up) — so a test store that wipes never reaches another's photos.
    @Test func theSoloCorpusLivesUnderTheStoresOwnRootOutsideTheOwnPhotos() {
        let store = makeTestStore()
        #expect(store.soloCameraDirectory.lastPathComponent == SoloCameraPhotoStore.directoryName)
        #expect(store.soloCameraDirectory.deletingLastPathComponent().standardizedFileURL
                == store.proximitySupportRoot.standardizedFileURL)
        let own = OwnPhotoCorpusLayout.sealedLocations(in: store.photoDocumentsDirectory)
        #expect(!(own.directories + own.files).contains { $0.path.contains(SoloCameraPhotoStore.directoryName) })
        #expect(makeTestStore().soloCameraDirectory != store.soloCameraDirectory)
    }

    /// The film count and the photos never touch `UserDefaults` (or iCloud's key-value store): the
    /// count lives in the sealed index, so there is no plaintext key for a wipe wall to chase.
    @Test func theSoloCameraWritesNoDefaults() throws {
        for path in ["App/Fernlet/World/Friends/SoloCameraRoll.swift", "App/Fernlet/FernletStore+SoloCamera.swift",
                     "FernletKit/Sources/PrivateMediaStore/SoloCameraPhotoStore.swift"] {
            let code = try RepoRoot.source(path).components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            for banned in ["UserDefaults", "@AppStorage", "NSUbiquitousKeyValueStore", "CKRecord", "appGroup"] {
                #expect(!code.contains(banned), "\(path) names \(banned)")
            }
        }
    }
}
