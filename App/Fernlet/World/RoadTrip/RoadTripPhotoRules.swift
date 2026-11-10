import FernletSocial
import Foundation
import PrivateMediaStore
import WorldMapStore

/// Where a road trip photo was taken (World-RoadTrip-Spec §2.7, `rt-photos`, owner-approved 2026-11-10: "Its place
/// comes from the trip's road at that time"): the trip's timed line at the photo's capture time. Pure.
///
/// - **Between two points** (``place(at:on:)``): the line's last point at or before the time and its first at or
///   after it. Within ``maxGap`` of each other, the place is between them in proportion to the time (a car at
///   speed covers the 25 m spacing in about a second, so this is metres off at most).
/// - **A long gap** (more than ``maxGap``, five minutes, between the two points): nobody's phone heard the road
///   then (a tunnel, a phone off, the mapper changing), so where the car was is not known, and the photo gets no
///   place, unless the two points are within ``stillRadius`` of each other: the car stood still (a stop, which is
///   when most trip photos are taken; the line keeps no point until it moves 25 m), and the photo is placed there.
/// - **Off the line's ends:** no place yet. A photo taken after the last point waits for the road after it: this
///   phone's own line as it grows, or the next catch-up's (``FernletStore/resolveRoadTripPhotoPlaces(in:)``).
/// - **At once** (``placeNow(fix:takenAt:)``): this iPhone maps, so its own reading at the shutter is the road's
///   position then, when it is precise, within 50 m and fresh (``WorldPhotoPlaceRules``).
///
/// A trip photo's place may be anywhere on the trip's road: the solo photos' everyday-places rule
/// (`PlaceClassifier.photoMayKeepPlace`) is not asked.
nonisolated enum RoadTripPhotoPlacing {
    /// The longest time between two points a photo is placed between, in seconds.
    static let maxGap: TimeInterval = 5 * 60
    /// Two points across a longer gap this close (metres) mean the car stood still.
    static let stillRadius = 100.0
    /// The most halving steps the search takes (2¹⁷ is past the line's 100,000 points).
    private static let maxSearchSteps = 24

    /// The place on `points` (a trip's line, oldest first, time never running backwards) at `time`; nil when the
    /// time is off the line's ends or across a long gap the car moved in.
    static func place(at time: Date, on points: [RoadTripPoint]) -> GeoPoint? {
        let line = points.prefix(RoadTripLine.maxPoints)
        guard let first = line.first, let last = line.last, time >= first.at, time <= last.at else { return nil }
        var low = line.startIndex, high = line.endIndex - 1
        // R2: bounded by the halving steps the line's bound needs.
        for _ in 0..<maxSearchSteps where low < high {
            let middle = low + (high - low) / 2
            if line[middle].at < time { low = middle + 1 } else { high = middle }
        }
        let after = line[low]
        guard after.at != time else { return after.point }
        guard low > line.startIndex else { return nil }
        return between(line[low - 1], after, at: time)
    }

    /// The place between `before` and `after` at `time` (which lies between them), by the gap rule.
    static func between(_ before: RoadTripPoint, _ after: RoadTripPoint, at time: Date) -> GeoPoint? {
        let span = after.at.timeIntervalSince(before.at)
        guard span > 0 else { return before.point }
        guard span <= maxGap else {
            return before.point.distance(to: after.point) <= stillRadius ? before.point : nil
        }
        guard abs(after.point.longitude - before.point.longitude) <= 180 else { return nil }
        let fraction = min(max(time.timeIntervalSince(before.at) / span, 0), 1)
        let point = GeoPoint(before.point.latitude + (after.point.latitude - before.point.latitude) * fraction,
                             before.point.longitude + (after.point.longitude - before.point.longitude) * fraction)
        return point.isValid ? point : nil
    }

    /// The place of a photo taken at `takenAt` on the iPhone that maps, from its own reading `fix`: the reading's
    /// point when it may place a photo (precise, within 50 m, fresh); nil otherwise.
    static func placeNow(fix: WorldFix?, takenAt: Date) -> GeoPoint? {
        guard let fix, WorldPhotoPlaceRules.isGoodEnough(fix, at: takenAt) else { return nil }
        return fix.point
    }
}

/// Which trip photos go to whom, and which are kept (World-RoadTrip-Spec §2.6-§2.7, owner-approved 2026-11-10). Pure.
///
/// - **The roll** (`rt-photos`: "up to 30 per person"): ``perMember`` a person a trip, so ``perTrip`` a trip.
/// - **What a member is sent** (``owed(_:to:in:held:now:)``): only this iPhone's own photos (a friend's photo is the
///   friend's: never passed on), not hidden, taken while the member was on the trip by proof of presence (at or
///   after their first presence as this iPhone knows it: the start when they were there, else the first catch-up
///   it shared with them) and not after now, that they don't already hold.
/// - **What this iPhone keeps** (``accepts(takenAt:in:now:)``): a photo taken from the trip's start and this
///   iPhone's own first presence up to now and a friend's clock running a little ahead, as the road is accepted.
nonisolated enum RoadTripPhotoRules {
    /// The most photos one person takes on one trip.
    static let perMember = RoadTripPayload.maxPhotosPerMember
    /// The most photos one trip has on this iPhone.
    static let perTrip = perMember * RoadTrip.maxMembers

    /// This iPhone's photos of `trip` (among `photos`) that `member` is sent at a catch-up `now`, oldest first, at
    /// most ``perMember``: its own, shown, taken while they were there and not among `held` (their ids).
    static func owed(_ photos: [RoadTripPhoto], to member: String, in trip: RoadTrip, held: Set<UUID>,
                     now: Date) -> [RoadTripPhoto] {
        guard member != trip.selfID, trip.memberIDs.contains(member),
              let first = RoadTripPresence.presence(of: member, in: trip).first else { return [] }
        let owed = photos.prefix(RoadTripPhotoStore.maxPhotos).filter {
            $0.tripID == trip.id && $0.authorID == trip.selfID && $0.isShown && $0.takenAt >= first
                && $0.takenAt <= now && !held.contains($0.sourceID)
        }
        return Array(owed.sorted { $0.takenAt < $1.takenAt }.prefix(perMember))
    }

    /// Whether a friend's photo of `trip` taken at `takenAt` is kept at `now`.
    static func accepts(takenAt: Date, in trip: RoadTrip, now: Date) -> Bool {
        guard let window = RoadTripPresence.acceptWindow(in: trip, now: now) else { return false }
        return takenAt >= max(window.from, trip.startedAt) && takenAt <= window.through
    }

    /// A photo's bytes as this iPhone keeps them: within the photo corpora's byte cap and pixel bounds (checked
    /// before anything decodes them), then downscaled and re-encoded as a solo shot is, which leaves the camera's
    /// metadata behind; nil when they are not a safe image.
    @MainActor
    static func normalized(_ bytes: Data) -> Data? {
        guard bytes.count <= PrivateMediaStore.maxIncomingPhotoBytes, PrivateMediaStore.isWithinSafePixelBounds(bytes) else { return nil }
        return SoloCameraRoll.normalized(bytes)
    }
}
