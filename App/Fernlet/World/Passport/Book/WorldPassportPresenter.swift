import Foundation
import Observation
import SwiftUI

/// Opens and closes Sprout's passport (World-Passport-Spec §1, §6, §9), from anywhere in the app: Home's tap or hold
/// on Sprout (page 1, rising from Sprout), the Stamp book's Passport row (`open(page: 2)`), Customize from Today
/// (page 1), the new-stamp banner (the stamp's page).
///
/// Owned by the root view as `@State` and handed down through the environment (``WorldPassportBookHost``), so
/// nothing of it is stored in the store or on disk. It holds which page the next open shows, where Sprout stands
/// (the book rises from there), and one pending new stamp: ``noteNewStamp(_:)`` makes the next open go to that
/// stamp's page once and land it there; every later open is page 1 again.
@MainActor
@Observable
final class WorldPassportPresenter {
    /// Whether the book is up (the root's full-screen cover).
    var isPresented = false
    /// The page this open asked for (1-based). When ``landing`` is set the book opens on its page instead.
    private(set) var requestedPage = 1
    /// Where Sprout stands, in the screen's coordinates: the book rises from and sinks back to it. Nil rises from
    /// the screen's centre.
    private(set) var anchor: CGPoint?
    /// The new stamp the next open lands, once.
    private(set) var pendingNewStamp: PassportStampEntry?
    /// The stamp this open lands (the chip, the thump), or nil.
    private(set) var landing: PassportStampEntry?
    /// The new stamp the root's banner shows ("New stamp: Sea of Japan. It's in Sprout's passport."), until the banner
    /// has had its window (``bannerShown()``) or the book opens.
    private(set) var bannerStamp: PassportStampEntry?
    /// The latest city the world view asked Home to show (``openCity(_:)``); each ask is a new request, so Home and
    /// the root both see it change.
    private(set) var cityRequest: PassportCityRequest?
    /// Counts the opens, so the book starts each one fresh.
    private(set) var openCount = 0
    /// Whether a close was asked for while the book is up (the book plays its closing, then ``dismiss()``).
    private(set) var isClosing = false
    /// A stand-in passport for the DEBUG screenshots (`UITestSupport+PassportBook`), never written anywhere;
    /// nil reads the person's.
    var demo: PassportBookDemo?

    /// A presenter with nothing open.
    init() {}

    /// Opens the passport on `page` (1 Sprout, 2 Your world), rising from `anchor`. The first open after
    /// ``noteNewStamp(_:)`` goes to that stamp's page instead, once.
    func open(page: Int = 1, from anchor: CGPoint? = nil) {
        self.anchor = anchor
        if let pending = pendingNewStamp {
            landing = pending
            pendingNewStamp = nil
        } else {
            landing = nil
        }
        requestedPage = max(page, 1)
        bannerStamp = nil
        isClosing = false
        openCount += 1
        withoutSystemAnimation { isPresented = true }
    }

    /// Closes the book: it plays its closing and sinks back to Sprout. Nothing to do when it isn't up.
    func close() {
        guard isPresented else { return }
        isClosing = true
    }

    /// Takes the book away at once (the book calls this when its closing has played).
    func dismiss() {
        isClosing = false
        landing = nil
        withoutSystemAnimation { isPresented = false }
    }

    /// A new stamp landed (a first visit or a new trip): the next open goes to its page, shows "New stamp · X"
    /// and lands it. A later stamp replaces an earlier one not yet seen.
    /// The root's banner shows it meanwhile (``bannerStamp``).
    func noteNewStamp(_ entry: PassportStampEntry) {
        pendingNewStamp = entry
        bannerStamp = entry
    }

    /// The banner had its window (or was tapped): it goes; the next open still lands the stamp.
    func bannerShown() {
        bannerStamp = nil
    }

    /// The world view's city tap (`WorldYourWorldPage.onOpenCity`): the book closes and Home's camera goes to the
    /// city `token`, where the city view draws; the root closes any panel over Home.
    func openCity(_ token: String) {
        cityRequest = PassportCityRequest(token: token, serial: (cityRequest?.serial ?? 0) &+ 1)
        close()
    }

    /// The page this open starts on in `book`: the landing stamp's page, else the requested page, clamped.
    func startPage(in book: PassportBookModel) -> Int {
        if let landing, let page = book.pageNumber(of: landing) { return page }
        return book.clamped(requestedPage)
    }

    /// Runs `change` without the system's slide (the book draws its own rise and swing).
    private func withoutSystemAnimation(_ change: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, change)
    }
}

/// One ask from the world view to show a city on Home: the city's token, and which ask it is.
nonisolated struct PassportCityRequest: Equatable, Sendable {
    let token: String
    let serial: Int
}

/// A stand-in passport the DEBUG screenshots open (`UITestSupport+PassportBook`): its stamps, whether it shows as
/// a decoy session's, and the world map's demo content. Held in memory only, never written.
struct PassportBookDemo {
    let entries: [PassportStampEntry]
    var isDecoy = false
    /// The world preview's and world view's content (nil: the person's, from the store).
    var world: WorldViewContent?
    /// Whether it opens with the contents list up (`ps-turn`).
    var opensContents = false
    /// The A to Z view it opens in (`ps-continent`).
    var detail: PassportIndexDetail?
}
