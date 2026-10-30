import CoreGraphics
import Foundation
import Testing
import WorldMapStore
@testable import Fernlet

/// Home's hook into Sprout's passport (round 7, World-Passport-Spec §1, §4, §6; World-Exploration-Spec §2): a tap
/// or hold on Sprout opens page 1 (the close-up and "hold for Customize" retired), Customize from Today opens page 1,
/// a new stamp's banner and its landing, the world view's city tap moving Home's camera (held from the ten seconds'
/// re-follow until the person moves the map), and a landmark's name plate stepping below Sprout's feet.
@MainActor
struct WorldHomeHookTests {
    private static let date = DateComponents(calendar: .current, year: 2026, month: 10, day: 24, hour: 10).date ?? .distantPast

    // MARK: New stamps

    /// A new stamp from Home's discovery reader goes to the passport: the banner shows it, the next open lands it on
    /// its page and takes the banner away; the banner's window ending keeps the landing.
    @Test func aNewStampShowsTheBannerAndLandsOnTheNextOpen() {
        let presenter = WorldPassportPresenter()
        let stamp = PassportStamp(kind: .sea, token: "Q27092", date: Self.date, trip: 1)
        WorldHomePassportHook.forward(stamp, to: presenter, isDecoy: false)
        let entry = PassportStampEntry(stamp: stamp)
        #expect(presenter.bannerStamp == entry && presenter.pendingNewStamp == entry)
        presenter.bannerShown()
        #expect(presenter.bannerStamp == nil && presenter.pendingNewStamp == entry, "the banner going keeps the landing")
        WorldHomePassportHook.forward(stamp, to: presenter, isDecoy: false)
        presenter.open()
        #expect(presenter.landing == entry && presenter.bannerStamp == nil, "opening the book takes the banner away")
    }

    /// A decoy hears no stamps: no banner, no landing.
    @Test func aDecoyGetsNoBanner() {
        let presenter = WorldPassportPresenter()
        WorldHomePassportHook.forward(PassportStamp(kind: .country, token: "JP", date: Self.date, trip: 1), to: presenter, isDecoy: true)
        #expect(presenter.bannerStamp == nil && presenter.pendingNewStamp == nil)
    }

    /// The banner's words and its stamp's size.
    @Test func theBannerSaysWhereTheStampIs() {
        #expect(String(localized: PassportNewStampCopy.title("Sea of Japan")) == "New stamp: Sea of Japan")
        #expect(String(localized: PassportNewStampCopy.detail(companion: "Sprout")) == "It's in Sprout's passport.")
        #expect(String(localized: PassportNewStampCopy.announcement("Sea of Japan", on: "24 October 2026", companion: "Sprout"))
                == "New stamp, Sea of Japan, 24 October 2026. It's in Sprout's passport.")
        for allOceans in [false, true] {
            let side = CGFloat(PassportStampArt.special(allOceans: allOceans).count)
            #expect(abs(side * PassportNewStampCopy.artScale(for: .special(allOceans: allOceans)) - 44) < 0.01)
        }
        #expect(56 * PassportNewStampCopy.artScale(for: .country("JP")) <= 48)
    }

    // MARK: The world view's city

    /// Each city tap is a new request (the same city twice too) and closes the open book.
    @Test func aCityTapClosesTheBookAndAsksHome() {
        let presenter = WorldPassportPresenter()
        presenter.open(page: 2)
        presenter.openCity("Q6106")
        #expect(presenter.cityRequest?.token == "Q6106" && presenter.isClosing)
        let first = presenter.cityRequest
        presenter.openCity("Q6106")
        #expect(presenter.cityRequest != first, "a second tap on the same city is a new request")
    }

    /// The visit holds while the map still shows the city (MapKit's own settling allowed), not once the person
    /// moves the map, and never while following.
    @Test func aCityVisitHoldsUntilTheMapMoves() {
        let city = GeoPoint(45.5152, -122.6784)
        let visit = WorldCamera(center: city, distance: WorldHomePassportHook.cityDistance, follows: false)
        #expect(WorldHomePassportHook.isStillVisiting(visit, camera: visit))
        var settled = visit
        settled.center = city.offset(east: 20, north: 0)
        #expect(WorldHomePassportHook.isStillVisiting(visit, camera: settled))
        var panned = visit
        panned.center = city.offset(east: 600, north: 0)
        #expect(!WorldHomePassportHook.isStillVisiting(visit, camera: panned))
        var following = visit
        following.follows = true
        #expect(!WorldHomePassportHook.isStillVisiting(visit, camera: following))
        #expect(!WorldHomePassportHook.isStillVisiting(nil, camera: visit))
        #expect(WorldCamera.distanceRange.contains(WorldHomePassportHook.cityDistance))
        #expect(WorldHomePassportHook.cityDistance < 2_400, "under the step where city markers replace the city view")
    }

    // MARK: The landmark's plate and Sprout

    /// Sprout standing on a landmark covers its plate, so the plate moves below Sprout's feet, clear of Sprout
    /// and of the bubble above; a landmark away from Sprout keeps its plate under its art.
    @Test func aCoveredPlateStepsBelowSproutsFeet() {
        let feet = CGPoint(x: 200, y: 500)
        let name = "Laurelhurst Park"
        #expect(WorldLandmarkPlateRule.sproutCovers(plate: name, at: CGPoint(x: 205, y: 498), feet: feet))
        #expect(!WorldLandmarkPlateRule.sproutCovers(plate: name, at: CGPoint(x: 200, y: 300), feet: feet))
        #expect(!WorldLandmarkPlateRule.sproutCovers(plate: name, at: CGPoint(x: 40, y: 500), feet: feet))
        let centre = WorldLandmarkPlateRule.belowFeet(feet, landmark: CGPoint(x: 205, y: 498), size: CGSize(width: 402, height: 874))
        let moved = CGRect(x: centre.x - 50, y: centre.y - WorldLandmarkPlateRule.plateHeight / 2, width: 100,
                           height: WorldLandmarkPlateRule.plateHeight)
        #expect(!moved.intersects(WorldLandmarkPlateRule.sproutRect(feet: feet)), "the moved plate clears Sprout")
        #expect(moved.minY > feet.y, "below the feet, so never under the bubble above Sprout")
    }

    // MARK: The retired close-up (source pins)

    /// Tap and hold on Home's Sprout both open the passport from where Sprout stands; the close-up, the customize
    /// sheet and the map's own petting are gone (page 1's photo pets).
    @Test func homesSproutOpensThePassport() throws {
        let companion = try RepoRoot.source("App/Fernlet/World/Home/WorldMapCompanion.swift")
        #expect(companion.contains(".onTapGesture { activate() }"))
        #expect(companion.contains("FernletFeedback.system.play(.held)\n                activate()"))
        #expect(companion.contains("onOpenPassport(spriteCentre)"))
        #expect(!companion.contains("worldCompanionCloseUp") && !companion.contains("Edit your companion"))
        let home = try RepoRoot.source("App/Fernlet/World/Home/WorldMapHome.swift")
        #expect(home.contains("passport?.open(page: 1, from: anchor)"))
        #expect(!home.contains("CompanionCustomizationSheet"), "hold for Customize is retired on Home")
    }

    /// Customize from Today opens the passport on page 1 (§4 "Other ways in").
    @Test func customizeFromTodayOpensPageOne() throws {
        let today = try RepoRoot.source("App/Fernlet/HomeView.swift")
        #expect(today.contains("TodayCompanionCard(store: store, isActive: isActive) {\n            if let passport { passport.open(page: 1) }"))
    }

    /// Page 1 reports its top, so the book's swipe down closes only from there.
    @Test func pageOneReportsItsTop() throws {
        let book = try RepoRoot.source("App/Fernlet/World/Passport/Book/PassportBookScreen.swift")
        #expect(book.contains("isStudioDraftDirty: $isStudioDraftDirty, onTop: { pageOnTop = $0 })"))
        let page = try RepoRoot.source("App/Fernlet/World/Passport/Sprout/PassportSproutPage.swift")
        #expect(page.contains("onTop(top)"))
    }
}
