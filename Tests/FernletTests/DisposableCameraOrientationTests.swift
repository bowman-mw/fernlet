import Testing
import CoreGraphics
@testable import Fernlet

/// Rotation-stability tests for `DisposableCameraOrientation.resolveLandscape` — the hysteresis that keeps
/// a rotation's transient near-square frame from flipping the layout orientation twice.
@Suite struct DisposableCameraOrientationTests {

    @Test func clearlyLandscapeAndPortraitResolveDirectly() {
        #expect(DisposableCameraOrientation.resolveLandscape(current: false, size: CGSize(width: 852, height: 393)))
        #expect(!DisposableCameraOrientation.resolveLandscape(current: true, size: CGSize(width: 393, height: 852)))
    }

    @Test func nearSquareHoldsCurrentOrientation() {
        // Inside the [0.95, 1.05] dead-band the current orientation is preserved either way, so a
        // rotation animation passing through square geometry cannot toggle the layout.
        let square = CGSize(width: 400, height: 400)
        #expect(DisposableCameraOrientation.resolveLandscape(current: true, size: square))   // stays landscape
        #expect(!DisposableCameraOrientation.resolveLandscape(current: false, size: square)) // stays portrait

        let nearWide = CGSize(width: 412, height: 400) // ratio ≈ 1.03, inside the band
        #expect(DisposableCameraOrientation.resolveLandscape(current: true, size: nearWide))
        #expect(!DisposableCameraOrientation.resolveLandscape(current: false, size: nearWide))
    }

    @Test func flipsOnlyAfterClearingTheDeadBand() {
        // From portrait, must become clearly wide (ratio > 1.05) to flip to landscape.
        #expect(!DisposableCameraOrientation.resolveLandscape(current: false, size: CGSize(width: 420, height: 400))) // 1.05, not >
        #expect(DisposableCameraOrientation.resolveLandscape(current: false, size: CGSize(width: 440, height: 400)))  // 1.10

        // From landscape, must become clearly tall (ratio ≤ 0.95) to flip to portrait.
        #expect(DisposableCameraOrientation.resolveLandscape(current: true, size: CGSize(width: 385, height: 400)))   // 0.9625, still >0.95
        #expect(!DisposableCameraOrientation.resolveLandscape(current: true, size: CGSize(width: 360, height: 400)))  // 0.90
    }

    @Test func zeroHeightDoesNotCrash() {
        // Defensive: a degenerate frame during teardown must not divide by zero.
        _ = DisposableCameraOrientation.resolveLandscape(current: false, size: CGSize(width: 100, height: 0))
    }
}
