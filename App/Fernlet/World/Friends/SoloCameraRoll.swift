import Foundation
import Observation
import UIKit
import FernletFoundation
import FernletScoring
import PrivateMediaStore

/// The disposable camera's rules on your own (owner, 2026-10-24; `b3-camera-solo` draft 2): ten
/// photos a local day, no Develop step, and the photos appear after the companion goes to sleep.
///
/// Pure and nonisolated, so the tests pin every boundary. "Goes to sleep" is the companion's own
/// night (`CompanionSleepWindow`, the bedtime the person set in Settings): it falls asleep at the
/// end of the wind-down, ``CompanionSleepWindow/fallsAsleepMinute``.
nonisolated enum SoloCameraRules {
    /// Photos a local day, alone.
    static let photosPerDay = 10

    /// When a shot taken at `takenAt` starts to show: the next time the companion falls asleep after
    /// the shot. A shot taken once it is already asleep waits for the NEXT night (owner, 2026-10-24,
    /// question 20), never shows at once. A window with no night (bedtime equals wake) uses the
    /// standard one, so a photo always has a night to wait for.
    ///
    /// - Parameters:
    ///   - takenAt: When the shutter fired.
    ///   - window: The person's night, as Settings has it now.
    ///   - calendar: The calendar (and time zone) the night is read in.
    static func revealsAt(takenAt: Date, window: CompanionSleepWindow, calendar: Calendar) -> Date {
        let night = window.isEmpty ? CompanionSleepWindow.standard : window
        let today = calendar.startOfDay(for: takenAt)
        // Strictly after: a shot at the very minute it falls asleep is a shot of an asleep companion.
        if let tonight = instant(minute: night.fallsAsleepMinute, of: today, calendar: calendar), tonight > takenAt {
            return tonight
        }
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: today),
              let next = instant(minute: night.fallsAsleepMinute, of: tomorrow, calendar: calendar) else {
            // Unreachable on a Gregorian calendar; a day later is the honest upper bound.
            return takenAt.addingTimeInterval(24 * 60 * 60)
        }
        return next
    }

    /// Whether a shot taken at `now` waits for tomorrow night (owner's form answer 44, 2026-10-25): the
    /// companion has already fallen asleep, so ``revealsAt(takenAt:window:calendar:)`` is its NEXT night,
    /// and the camera says "tomorrow night" instead of "tonight". In the wind-down it is not asleep yet,
    /// so tonight still holds; a window with no night uses the standard one, as the reveal does.
    ///
    /// - Parameters:
    ///   - now: The moment the camera speaks for.
    ///   - window: The person's night, as Settings has it now.
    ///   - calendar: The calendar (and time zone) the night is read in.
    static func waitsForTomorrowNight(at now: Date, window: CompanionSleepWindow, calendar: Calendar) -> Bool {
        let night = window.isEmpty ? CompanionSleepWindow.standard : window
        let clock = calendar.dateComponents([.hour, .minute], from: now)
        guard let hour = clock.hour, let minute = clock.minute else { return false }
        return night.isPastWindDown(atMinute: hour * 60 + minute)
    }

    /// ``waitsForTomorrowNight(at:window:calendar:)`` with the person's night as Settings has it now, read
    /// here (as ``SoloCameraRoll``'s `takePhoto` reads it), so the camera's view never names the emotion's
    /// preferences itself (`CompanionEmotionPrivacyTests`).
    @MainActor
    static func waitsForTomorrowNight(at now: Date, calendar: Calendar) -> Bool {
        waitsForTomorrowNight(at: now, window: CompanionEmotionPreferences.sleepWindow(), calendar: calendar)
    }

    /// Shots left on a day that has used `used` (never negative).
    static func shotsLeft(used: Int) -> Int {
        max(0, photosPerDay - max(0, used))
    }

    /// The wall-clock instant `minute` minutes after midnight on the day starting at `dayStart`.
    private static func instant(minute: Int, of dayStart: Date, calendar: Calendar) -> Date? {
        calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: dayStart)
    }
}

/// What one shot on your own came to.
enum SoloShotOutcome: Equatable {
    /// Sealed (or, in a decoy, held in memory) and counted against today's film.
    case kept
    /// Today's film is used up; nothing was kept.
    case noFilmLeft
    /// The photo could not be kept (no key, a failed write, bytes that are not a photo). No film used.
    case notKept
}

/// The disposable camera's roll on your own: today's film, the shot, and the photos that show
/// (World build; owner 2026-10-24: "I think the photos can be saved in the friend area").
///
/// A thin owner over ``SoloCameraPhotoStore`` (sealed, device-only, excluded from backup; the store's
/// doc has the custody): every shot is normalized like a session photo (downscaled and re-encoded,
/// which also drops the camera's metadata), then sealed at once, and the day's film is spent in the
/// same sealed write. ``SoloCameraRules`` decides when each photo shows.
///
/// **The decoy keeps nothing real.** While a duress decoy is up (``isDecoy``) the roll never opens
/// the sealed corpus — no read, no write, no count: its film and shots live in this object's memory
/// only, and ``setDecoy(_:)`` drops them when the decoy starts or ends.
///
/// **The read API** (``photos(visibleAt:)``, ``thumbnailData(for:)``, ``imageData(for:)``) is for the
/// Friends page once its design is approved; nothing draws these photos yet. Bytes are handed out
/// only for photos the last read showed, so a held photo cannot be drawn by id.
///
/// Concurrency: main actor (the app's default isolation), like the store that owns it.
@Observable
final class SoloCameraRoll {
    /// The most shots a decoy holds in memory (a decoy lasting days still stays bounded).
    static let maxDecoyPhotos = 30

    @ObservationIgnored private let store: SoloCameraPhotoStore
    /// Whether a duress decoy is up: nothing real is read or written.
    private(set) var isDecoy: Bool
    /// The film as last read (the decoy's own film while it is up); nil before the first shot.
    private(set) var film: SoloCameraFilm?
    /// Whether the film above can be trusted: false until a read succeeds, and while the sealed
    /// corpus cannot be read (no key yet, a locked file). The camera is off then.
    private(set) var isReadable = false
    @ObservationIgnored private var decoyPhotos: [SoloCameraPhoto] = []
    @ObservationIgnored private var decoyImages: [UUID: Data] = [:]
    /// The ids the last ``photos(visibleAt:)`` showed: the only ones whose bytes are handed out.
    @ObservationIgnored private var shownIDs: Set<UUID> = []
    /// The id of the last shot sealed into the corpus (never a decoy's), for its place
    /// (`FernletStore.keepSoloPhotoPlace`; World build step 5c).
    @ObservationIgnored private(set) var lastKeptID: UUID?
    /// Told the id of every photo deleted from the sealed corpus, so its place goes with it.
    @ObservationIgnored var onDeleted: ((UUID) -> Void)?

    /// A roll over `store`; nothing is read until ``refresh()`` or a shot.
    init(store: SoloCameraPhotoStore, isDecoy: Bool) {
        self.store = store
        self.isDecoy = isDecoy
    }

    /// Shots left today at `now`, or nil when the corpus cannot be read right now.
    func shotsLeft(at now: Date = .now) -> Int? {
        guard isReadable else { return nil }
        return SoloCameraRules.shotsLeft(used: film?.used(on: FernletDate.dayKey(for: now)) ?? 0)
    }

    /// Re-reads the day's film from the sealed index (in a decoy, the decoy's own film stands).
    func refresh() {
        guard !isDecoy else {
            isReadable = true
            return
        }
        switch store.load() {
        case .loaded(let index):
            film = index.film
            isReadable = true
        case .unrecoverable(purged: true):
            film = nil
            isReadable = true
        case .unrecoverable(purged: false), .deferred:
            isReadable = false
        }
    }

    /// Keeps one shot: normalized, then sealed with its reveal time, spending one shot of today's
    /// film in the same write (in a decoy, held in memory instead).
    ///
    /// - Parameters:
    ///   - captured: The camera's photo bytes.
    ///   - now: When the shutter fired.
    ///   - window: The companion's night; nil reads the person's setting.
    ///   - calendar: The calendar the day and the night are read in.
    func takePhoto(_ captured: Data, at now: Date = .now, window: CompanionSleepWindow? = nil,
                   calendar: Calendar = .current) -> SoloShotOutcome {
        guard let normalized = Self.normalized(captured) else { return .notKept }
        let night = window ?? CompanionEmotionPreferences.sleepWindow()
        let photo = SoloCameraPhoto(takenAt: now,
                                    revealsAt: SoloCameraRules.revealsAt(takenAt: now, window: night, calendar: calendar))
        let day = FernletDate.dayKey(for: now)
        lastKeptID = nil
        guard !isDecoy else { return keepInMemory(photo, normalized, day: day) }
        switch store.add(photo, imageData: normalized, filmDay: day, dailyLimit: SoloCameraRules.photosPerDay) {
        case .added(let index):
            film = index.film
            isReadable = true
            lastKeptID = photo.id
            return .kept
        case .noFilmLeft:
            refresh()
            return .noFilmLeft
        case .full, .unsafeImage, .notPersisted, .deferred:
            refresh()
            return .notKept
        }
    }

    /// A decoy's shot: memory only, the decoy's own film.
    private func keepInMemory(_ photo: SoloCameraPhoto, _ data: Data, day: String) -> SoloShotOutcome {
        let used = film?.used(on: day) ?? 0
        guard used < SoloCameraRules.photosPerDay else { return .noFilmLeft }
        guard decoyPhotos.count < Self.maxDecoyPhotos else { return .notKept }
        decoyPhotos.insert(photo, at: 0)
        decoyImages[photo.id] = data
        film = SoloCameraFilm(dayKey: day, used: used + 1)
        isReadable = true
        return .kept
    }

    /// The photos that show at `now`, newest first, marking the newly due ones visible in the sealed
    /// index so they stay shown. In a decoy, only the decoy's own shots.
    func photos(visibleAt now: Date = .now) -> [SoloCameraPhoto] {
        let shown: [SoloCameraPhoto]
        if isDecoy {
            shown = decoyPhotos.filter { $0.isVisible(at: now) }
        } else {
            if !store.reveal(asOf: now) {
                // The due photos still show by their reveal time; a later read marks them.
                FernletAuditLog.log("soloCamera.revealNotWritten")
            }
            guard case .loaded(let index) = store.load() else {
                shownIDs = []
                return []
            }
            shown = index.visible(at: now)
        }
        shownIDs = Set(shown.map(\.id))
        return shown
    }

    /// The photos still held at `now` (taken, not shown yet), newest first — the album's "Tonight"
    /// tile. None in a decoy (the album shows a decoy nothing).
    func heldPhotos(at now: Date = .now) -> [SoloCameraPhoto] {
        guard !isDecoy, case .loaded(let index) = store.load() else { return [] }
        return index.photos.filter { !$0.isVisible(at: now) }
    }

    /// Deletes one photo — from the sealed corpus, or a decoy's memory. Its film is not given back.
    ///
    /// - Returns: whether it is gone.
    func delete(_ id: UUID) -> Bool {
        shownIDs.remove(id)
        guard !isDecoy else {
            decoyPhotos.removeAll { $0.id == id }
            decoyImages[id] = nil
            return true
        }
        let gone = store.delete(id: id)
        if gone { onDeleted?(id) }
        return gone
    }

    /// Makes `id` the favorite (its set's cover) among `ids`, one day's set; nil clears it. Nothing in
    /// a decoy.
    ///
    /// - Returns: whether the choice was kept.
    func setFavorite(_ id: UUID?, among ids: Set<UUID>) -> Bool {
        guard !isDecoy else { return false }
        return store.setFavorite(id, among: ids)
    }

    /// A shown photo's thumbnail, or nil (held, unknown, or unreadable right now).
    func thumbnailData(for id: UUID) -> Data? {
        guard shownIDs.contains(id) else { return nil }
        guard !isDecoy else { return decoyImages[id] }
        return store.thumbnailData(for: id)
    }

    /// A shown photo's full-size bytes, or nil (held, unknown, or unreadable right now).
    func imageData(for id: UUID) -> Data? {
        guard shownIDs.contains(id) else { return nil }
        guard !isDecoy else { return decoyImages[id] }
        return store.imageData(for: id)
    }

    /// Follows the duress decoy: entering or leaving it drops every decoy shot and its film, so
    /// neither side ever sees the other's.
    func setDecoy(_ on: Bool) {
        guard on != isDecoy else { return }
        decoyPhotos = []
        decoyImages = [:]
        shownIDs = []
        film = nil
        isReadable = false
        isDecoy = on
        refresh()
    }

    /// Delete everything's leg: the whole sealed corpus (photos, thumbnails, the index and the film
    /// count) and anything held in memory, then the cached key. Runs in a decoy too — the silent
    /// wipe's purge does.
    ///
    /// - Returns: whether the corpus is gone.
    func purgeForDeleteAll() -> Bool {
        decoyPhotos = []
        decoyImages = [:]
        shownIDs = []
        film = nil
        let purged = store.purgeAll()
        store.invalidateEncryptionKeyCache()
        isReadable = purged
        return purged
    }

    /// The camera's bytes as the corpus keeps them: downscaled and re-encoded as a session photo is
    /// (`resizedForFriendSharing`, JPEG 0.82), which also leaves the camera's metadata behind. Nil
    /// when the bytes are not an image.
    static func normalized(_ captured: Data) -> Data? {
        guard let image = UIImage(data: captured) else { return nil }
        return image.resizedForFriendSharing().jpegData(compressionQuality: 0.82)
    }
}
