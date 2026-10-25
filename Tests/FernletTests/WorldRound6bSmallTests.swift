import Foundation
import Testing
import FernletDomainModel
@testable import Fernlet

/// The owner's form answers built in round 6b's small lane (2026-10-25): the close-up's one even veil
/// (question 27), and the rest of the lane's small changes as they land.
@MainActor
struct WorldRound6bSmallTests {

    // MARK: 27 · The close-up's veil

    /// One even veil, as drawn: 80 % over the light map, 84 % over the dark, from top to bottom (no
    /// thicker band behind the name and the footer).
    @Test func theCloseUpHasOneEvenVeil() {
        #expect(WorldCloseUpVeil.opacity(dark: false) == 0.8)
        #expect(WorldCloseUpVeil.opacity(dark: true) == 0.84)
    }
}
