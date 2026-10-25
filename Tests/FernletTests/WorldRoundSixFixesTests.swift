import Foundation
import Testing
import FernletDomainModel
import WorldMapStore
@testable import Fernlet

/// Round 6's smaller fixes (lane "fixes"): the photo prints' one-read cache (W-04), a print opening its
/// photo (`ref-wall-photo`), Log intimacy's two-half date and time (`ref-int-date`, `ref-int-time`), and
/// the run start (`ref-run-first`, `ref-run-again`): Walk or run together, told apart by the GPS pace.
@MainActor
struct WorldRoundSixFixesTests {

    // MARK: W-04 · the prints read each thumbnail once

    /// A wall reads only the photos its cache doesn't hold, each once, and never more than four.
    @Test func thePrintsReadOnlyWhatTheyLack() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID(), e = UUID()
        #expect(WorldPhotoPrints.idsToRead(wanted: [a, b, nil, c], cached: []) == [a, b, c])
        #expect(WorldPhotoPrints.idsToRead(wanted: [a, b, nil, c], cached: [a, c]) == [b])
        #expect(WorldPhotoPrints.idsToRead(wanted: [a, a, b, b], cached: []) == [a, b], "a photo twice is read once")
        #expect(WorldPhotoPrints.idsToRead(wanted: [a, b, c, d, e], cached: []) == [a, b, c, d], "four prints at most")
        #expect(WorldPhotoPrints.idsToRead(wanted: [nil, nil, nil, nil], cached: []).isEmpty, "an empty wall reads nothing")
    }

    /// The prints read nothing in `body`: the thumbnail read sits in the load task alone, behind the
    /// protected-data check, and the cache is the only place a print's image comes from.
    @Test func thePrintsNeverDecodeInBody() throws {
        let source = try RepoRoot.source("App/Fernlet/World/Home/WorldPhotoPrints.swift")
        #expect(source.components(separatedBy: "thumbnailData(forPhotoID:").count == 2, "one read site")
        #expect(source.contains("guard UIApplication.shared.isProtectedDataAvailable else { return }"))
        #expect(source.contains(".task(id: LoadKey("))
        #expect(source.contains("byPreparingForDisplay()"), "decoded off the main actor")
        #expect(!source.contains("Image(uiImage: UIImage(data:"), "no decode while drawing")
    }

    // MARK: ref-wall-photo · a print opens its photo

    /// A print goes by its hangout's name, else by the friend who took it.
    @Test func aPrintIsNamedForItsHangoutElseItsFriend() {
        let session = FriendPhotoSessionMetadata(id: UUID(), meshID: nil, meshName: " Picnic ", startedAt: .now, participants: [])
        let inHangout = FriendPhotoPayload(imageData: Data([1]), senderName: "Sam", session: session)
        let alone = FriendPhotoPayload(imageData: Data([1]), senderName: "Sam")
        let unnamed = FriendPhotoPayload(imageData: Data([1]), senderName: "Rae",
                                         session: FriendPhotoSessionMetadata(id: UUID(), meshID: nil, meshName: "  ", startedAt: .now, participants: []))
        #expect(WorldPhotoPrints.name(of: inHangout) == "Picnic")
        #expect(WorldPhotoPrints.name(of: alone) == "Sam")
        #expect(WorldPhotoPrints.name(of: unnamed) == "Rae")
        #expect(WorldPhotoPrints.spokenTitle(of: inHangout).hasPrefix("Photo from Picnic, "))
    }

    /// The route a print hands Home is the photo itself; the album presents it, never pushes it.
    @Test func aWallPhotoIsARouteTheAlbumPresents() throws {
        let id = UUID()
        #expect(FriendsRoute.wallPhoto(id) == .wallPhoto(id))
        #expect(FriendsRoute.closingShop([.wallPhoto(id)]) == [.wallPhoto(id)])
        let album = try RepoRoot.source("App/Fernlet/ConnectView.swift")
        #expect(album.contains("if case .wallPhoto(let photoID) = route"), "the album takes it as a cover, not a page")
        #expect(album.contains("initialPhotoID: feedOpenedFromWall"), "the carousel opens at that photo")
        #expect(album.contains("onBack: feedOpenedFromWall == nil ? nil"), "‹ Album only when the wall opened it")
    }

    // MARK: ref-int-date + ref-int-time · Log intimacy's date and time

    /// Picking a day keeps the time; picking a time keeps the day; nothing lands in the future.
    @Test func theTwoHalvesMergeAndNeverGoPastNow() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        func at(_ day: Int, _ hour: Int, _ minute: Int) throws -> Date {
            try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute)))
        }
        let now = try at(23, 21, 40)
        // The calendar picks the 20th: the time stays 9:40 PM.
        #expect(PrivateDateTimeButton.merged(day: try at(20, 0, 0), time: now, latest: now, calendar: calendar) == (try at(20, 21, 40)))
        // The wheels pick 7:15 AM: the day stays the 23rd.
        #expect(PrivateDateTimeButton.merged(day: now, time: try at(1, 7, 15), latest: now, calendar: calendar) == (try at(23, 7, 15)))
        // Today at 11 PM is later than now: it stops at now.
        #expect(PrivateDateTimeButton.merged(day: now, time: try at(23, 23, 0), latest: now, calendar: calendar) == now)
        // Seconds drop.
        let withSeconds = try at(23, 8, 5).addingTimeInterval(37)
        #expect(PrivateDateTimeButton.merged(day: withSeconds, time: withSeconds, latest: now, calendar: calendar) == (try at(23, 8, 5)))
    }

    /// The sheet's Date and time is the framed two-half button, and its save still sends `eventDate`
    /// to Apple Health.
    @Test func logIntimacyUsesTheTwoHalfButton() throws {
        let sheet = try RepoRoot.source("App/Fernlet/LogIntimacySheet.swift")
        #expect(sheet.contains("PrivateDateTimeButton(date: $eventDate"))
        #expect(sheet.contains("date: eventDate,"), "Apple Health gets the picked date and time")
        #expect(!sheet.contains(".datePickerStyle(.compact)"))
    }

    // MARK: ref-run-first + ref-run-again · Walk or run together

    /// The card says walk or run, everywhere the row appears; a saved run route keeps "Run it again" first.
    @Test func theCardOffersWalkOrRunTogether() {
        let anywhere = WorldQuickStart.card(for: WorldQuickStartContext(canWalk: true))
        #expect(anywhere?.heading == .walk && anywhere?.options == [.walkTogether])
        #expect(WorldQuickStartCopy.heading(.walk) == "Go for a walk or run")
        #expect(WorldQuickStartCopy.note(.nothingSaved)
                == "Nothing saved here yet. It shows up once you've trained, run, hiked or eaten here a few times.")
        #expect(WorldQuickStartCopy.title(.walkTogether) == "Walk or run together")
        #expect(WorldQuickStartCopy.detail(.walkTogether) == "Precise location for this walk or run only")
        let route = WorldQuickStartContext.SavedLine(metres: 3_200, walks: 8, kind: .run)
        let again = WorldQuickStart.card(for: WorldQuickStartContext(canWalk: true, savedLine: route))
        #expect(again?.options == [.runSavedLine(metres: 3_200), .walkTogether])
        #expect(WorldQuickStart.glyph(for: WorldQuickStartContext(canWalk: true)) == .walk, "a first run keeps the pair, no label")
        let routeGlyph = WorldQuickStart.glyph(for: WorldQuickStartContext(canWalk: true, savedLine: route))
        #expect(WorldQuickStartLabel.label(for: routeGlyph) == .run, "the Run label still slides out at a saved route")
    }

    /// A moving pace of 2.2 m/s or more is a run; slower, or too little to go on, a walk.
    @Test func thePaceTellsAWalkFromARun() {
        #expect(WorldWalkRecorder.paceKind(metres: 1_000, seconds: 400) == .run, "2.5 m/s")
        #expect(WorldWalkRecorder.paceKind(metres: 1_000, seconds: 455) == .run, "2.2 m/s")
        #expect(WorldWalkRecorder.paceKind(metres: 1_000, seconds: 600) == .walk, "1.7 m/s, a brisk walk")
        #expect(WorldWalkRecorder.paceKind(metres: 140, seconds: 50) == .walk, "too little to say")
        #expect(WorldWalkRecorder.paceKind(metres: 0, seconds: 0) == .walk)
    }

    /// Walk or run together counts only the moving steps: a run with a long stop is still a run, and
    /// a saved walk again stays a walk whatever the pace.
    @Test func theRecorderTimesOnlyTheMovingSteps() throws {
        let recorder = WorldWalkRecorder()
        #expect(try Self.stopAndGo(recorder, decides: true).kind == .run, "the stop doesn't slow the pace")
        #expect(try Self.stopAndGo(recorder, decides: false).kind == .walk, "a saved walk again stays a walk")
        #expect(recorder.movingSeconds == 0 && !recorder.decidesByPace, "finish resets the pace")
    }

    /// 600 m at 3 m/s, a reading a second, five minutes standing at a light, then 300 m more.
    private static func stopAndGo(_ recorder: WorldWalkRecorder, decides: Bool) throws -> WorldWalkRecorder.Walk {
        let origin = GeoPoint(45.5205, -122.6255), start = Date(timeIntervalSince1970: 2_000_000_000)
        recorder.start(at: start, decidesByPace: decides)
        for second in 0...200 {
            recorder.record(WorldFix(point: origin.offset(east: Double(second) * 3, north: 0), accuracy: 5,
                                     at: start.addingTimeInterval(Double(second)), isPrecise: true))
        }
        for second in 0...100 {
            recorder.record(WorldFix(point: origin.offset(east: 600 + Double(second) * 3, north: 0), accuracy: 5,
                                     at: start.addingTimeInterval(500 + Double(second)), isPrecise: true))
        }
        return try #require(recorder.finish(at: start.addingTimeInterval(620)))
    }

    /// A pace-decided run is logged as a run, and its line is saved under "Save new routes".
    @Test func aWalkOrRunTogetherAtARunningPaceLogsARun() throws {
        let store = makeTestStore()
        let defaults = try #require(UserDefaults(suiteName: "WorldRoundSixFixesTests.\(UUID().uuidString)"))
        let start = Date()
        store.startWorldWalk(at: start, decidesByPace: true)
        for second in 0...300 {
            store.worldWalk.record(WorldFix(point: GeoPoint(45.5205, -122.6255).offset(east: Double(second) * 2.6, north: 0),
                                            accuracy: 5, at: start.addingTimeInterval(Double(second)), isPrecise: true))
        }
        let logged = try #require(store.endWorldWalk(at: start.addingTimeInterval(305), defaults: defaults))
        #expect(logged.kind == .run)
        let workout = try #require(store.day.workouts.first { $0.id == logged.id })
        #expect(workout.activityType == .running && workout.name == "Running")
        #expect(store.worldRoute(for: workout.id)?.isEmpty == false, "a run saves its line")
        #expect(store.removeWorkout(id: workout.id, date: store.todayKey))
    }

    /// Move can put a pace that guessed wrong right: the default name follows the activity, a name of
    /// the person's own stays.
    @Test func moveSwitchesAWalkToARun() {
        #expect(EditWorkoutSheet.savedName("Walking", from: .walking, to: .running) == "Running")
        #expect(EditWorkoutSheet.savedName("Running", from: .running, to: .walking) == "Walking")
        #expect(EditWorkoutSheet.savedName("Park loop", from: .walking, to: .running) == "Park loop")
        #expect(EditWorkoutSheet.savedName("Walking", from: .walking, to: .walking) == "Walking")
        #expect(EditWorkoutSheet.walkOrRun == [.walking, .running])
    }
}
