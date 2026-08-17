import Testing
import CoreGraphics
@testable import Fernlet

/// Geometry tests for the wind-driven Dynamic Island viewfinder (`IslandViewfinderMetrics`).
/// Pure value type — no UI, no AVFoundation. `@MainActor` because the type lives in the
/// main-actor-default app target, so its `Equatable` conformance is main-actor isolated.
@MainActor
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

    @Test func islandOpenHousingWrapsTheIsland() {
        // Item 8: on a Dynamic Island device the OPEN housing top reaches the screen edge so the
        // island pill rides inside its top band — it must NOT clear the inset like a detached card.
        let m = metrics(topInset: 59)
        #expect(m.deviceClass == .island)
        let topEdge = m.openCenterY - m.openSize.height / 2
        #expect(topEdge < m.topInset)
        #expect(topEdge >= 0)
    }

    @Test func notchOpenViewfinderClearsTheInset() {
        // On notch / flat devices (no island to merge with) the open window keeps the detached
        // floating-card look: it sits entirely below the top inset.
        for inset in [CGFloat(47), 20] {
            let m = metrics(topInset: inset)
            #expect(m.deviceClass != .island)
            let topEdge = m.openCenterY - m.openSize.height / 2
            #expect(topEdge > m.topInset)
        }
    }

    // MARK: - Preview glass

    @Test func glassFrameSitsInsideTheHousing() {
        // The preview glass is fully inset within the housing shell at every openness.
        let m = metrics()
        for openness in [0.4, 0.7, 1.0] {
            let housing = m.frame(openness: openness)
            let glass = m.glassFrame(openness: openness)
            #expect(glass.size.width <= housing.size.width)
            #expect(glass.size.height <= housing.size.height)
            let housingTop = housing.centerY - housing.size.height / 2
            let housingBottom = housing.centerY + housing.size.height / 2
            let glassTop = glass.centerY - glass.size.height / 2
            let glassBottom = glass.centerY + glass.size.height / 2
            #expect(glassTop >= housingTop)
            #expect(glassBottom <= housingBottom)
        }
    }

    @Test func islandGlassClearsTheIslandBand() {
        // The open preview glass sits below the island band on an island device, and the status LED
        // rides between the island band and the glass.
        let m = metrics(topInset: 59)
        let glass = m.glassFrame(openness: 1)
        let glassTop = glass.centerY - glass.size.height / 2
        #expect(glassTop > m.topInset)
        let islandBottom = m.closedCenterY + m.closedSize.height / 2
        let led = m.ledCenterY(openness: 1)
        #expect(led > islandBottom)
        #expect(led < glassTop)
    }

    @Test func previewOpacityFadesInWithOpenness() {
        let m = metrics()
        #expect(m.previewOpacity(openness: 0) == 0)
        #expect(m.previewOpacity(openness: 0.3) == 0)
        #expect(m.previewOpacity(openness: 1) == 1)
        #expect(m.previewOpacity(openness: 0.6) > 0)
        #expect(m.previewOpacity(openness: 0.6) < 1)
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
