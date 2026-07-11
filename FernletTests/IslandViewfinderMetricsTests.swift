import Testing
import CoreGraphics
@testable import Fernlet

/// Geometry tests for the wind-driven Dynamic Island viewfinder (`IslandViewfinderMetrics`).
/// Pure value type — no UI, no AVFoundation.
@Suite struct IslandViewfinderMetricsTests {

    private func metrics(topInset: CGFloat = 59, width: CGFloat = 393) -> IslandViewfinderMetrics {
        IslandViewfinderMetrics(topInset: topInset, screenWidth: width)
    }

    // MARK: - Device classification

    @Test func classify_dynamicIslandInset() {
        #expect(IslandViewfinderMetrics.classify(topInset: 59) == .island)
        #expect(IslandViewfinderMetrics.classify(topInset: 55) == .island)
    }

    @Test func classify_notchInset() {
        #expect(IslandViewfinderMetrics.classify(topInset: 54) == .notch)
        #expect(IslandViewfinderMetrics.classify(topInset: 47) == .notch)
        #expect(IslandViewfinderMetrics.classify(topInset: 30) == .notch)
    }

    @Test func classify_flatInset() {
        #expect(IslandViewfinderMetrics.classify(topInset: 29) == .flat)
        #expect(IslandViewfinderMetrics.classify(topInset: 20) == .flat)
        #expect(IslandViewfinderMetrics.classify(topInset: 0) == .flat)
    }

    // MARK: - Frame endpoints

    @Test func frameAtZero_isClosedIslandAnchor() {
        let m = metrics()
        let f = m.frame(openness: 0)
        #expect(f.size == m.closedSize)
        #expect(f.cornerRadius == m.closedCornerRadius)
        #expect(f.centerY == m.closedCenterY)
    }

    @Test func frameAtOne_isOpenViewfinder() {
        let m = metrics()
        let f = m.frame(openness: 1)
        #expect(f.size == m.openSize)
        #expect(f.cornerRadius == m.openCornerRadius)
        #expect(f.centerY == m.openCenterY)
    }

    // MARK: - Interpolation

    @Test func frameGrowsAndDescendsMonotonically() {
        let m = metrics()
        let mid = m.frame(openness: 0.5)
        #expect(mid.size.height > m.closedSize.height)
        #expect(mid.size.height < m.openSize.height)
        #expect(mid.centerY > m.closedCenterY)
        #expect(mid.centerY < m.openCenterY)
    }

    @Test func opennessIsClamped() {
        let m = metrics()
        #expect(m.frame(openness: -1) == m.frame(openness: 0))
        #expect(m.frame(openness: 2) == m.frame(openness: 1))
    }

    // MARK: - Layout invariants

    @Test func islandAnchorSitsInsideTheTopInset() {
        // The closed anchor centers inside the top safe-area band, so it reads as the island itself.
        let m = metrics()
        #expect(m.closedCenterY > 0)
        #expect(m.closedCenterY < m.topInset)
    }

    @Test func openViewfinderClearsTheInset() {
        // The fully-open window sits entirely below the island band.
        let m = metrics()
        let topEdge = m.openCenterY - m.openSize.height / 2
        #expect(topEdge > m.topInset)
    }

    @Test func centerXIsHalfWidth() {
        #expect(metrics(width: 393).centerX == 393.0 / 2)
    }

    @Test func flatDeviceStillProducesUsableOpenWindow() {
        // A home-button phone / iPad (small inset) still gets a sane, growing window.
        let m = metrics(topInset: 20, width: 393)
        #expect(m.deviceClass == .flat)
        #expect(m.openSize.height > m.closedSize.height)
        #expect(m.frame(openness: 1).centerY > m.frame(openness: 0).centerY)
    }
}
