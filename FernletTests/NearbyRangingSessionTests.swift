import Testing
import Foundation
import MultipeerConnectivity
import Combine
@testable import Fernlet

@Suite(.serialized) @MainActor
struct NearbyRangingSessionTests {

    // MARK: - ProximityCommitDetector tap gate

    @Test func tapConfirmedDetectorTrueWhenSustainedClose() {
        let detector = makeTapGateDetector()
        let start = Date()
        var result = false
        // 15 samples at 10 Hz → spans 0.0 to 1.4 s; confirmed at ≥ 1.0 s mark
        for i in 0..<15 {
            result = detector.ingest(distanceMeters: 0.04, at: start.addingTimeInterval(Double(i) * 0.1))
        }
        #expect(result == true)
    }

    @Test func tapConfirmedDetectorFalseWhenBrief() {
        let detector = makeTapGateDetector()
        let start = Date()
        // 5 samples → spans only 0.4 s; window never fills a full second
        var result = false
        for i in 0..<5 {
            result = detector.ingest(distanceMeters: 0.04, at: start.addingTimeInterval(Double(i) * 0.1))
        }
        #expect(result == false)
    }

    @Test func tapConfirmedDetectorFalseWhenFar() {
        let detector = makeTapGateDetector()
        let start = Date()
        // 1.5 s of samples but all above the 5 cm threshold
        var result = false
        for i in 0..<15 {
            result = detector.ingest(distanceMeters: 0.2, at: start.addingTimeInterval(Double(i) * 0.1))
        }
        #expect(result == false)
    }

    @Test func tapConfirmedDetectorRequiresMinimumSamples() {
        let detector = makeTapGateDetector()
        let start = Date()
        // Only 2 samples within the 1-second window — below the 3-sample minimum
        _ = detector.ingest(distanceMeters: 0.04, at: start)
        let result = detector.ingest(distanceMeters: 0.04, at: start.addingTimeInterval(0.5))
        #expect(result == false)
    }

    @Test func tapConfirmedDetectorResetClearsWindow() {
        let detector = makeTapGateDetector()
        let start = Date()
        var confirmed = false
        for i in 0..<15 {
            confirmed = detector.ingest(distanceMeters: 0.04, at: start.addingTimeInterval(Double(i) * 0.1))
        }
        #expect(confirmed == true)

        detector.reset()

        // Single sample after reset — window is empty, count < minimum → false
        let result = detector.ingest(distanceMeters: 0.04, at: start.addingTimeInterval(2.0))
        #expect(result == false)
    }

    private func makeTapGateDetector() -> ProximityCommitDetector {
        ProximityCommitDetector(proximityThreshold: 0.05, dwellSeconds: 1.0, minimumSamples: 3)
    }

    @Test func tokenArchiveRoundTrip() throws {
        // NIDiscoveryToken cannot be instantiated in unit tests (requires real UWB hardware).
        // Verify the NSKeyedArchiver round-trip mechanism using MCPeerID as a stand-in
        // (also NSSecureCoding), mirroring what NIRangingSession does with discovery tokens.
        let original = MCPeerID(displayName: "TestDevice")
        let archived = try NSKeyedArchiver.archivedData(withRootObject: original, requiringSecureCoding: true)
        #expect(!archived.isEmpty)
        let restored = try NSKeyedUnarchiver.unarchivedObject(ofClass: MCPeerID.self, from: archived)
        #expect(restored?.displayName == original.displayName)
    }

    @Test func fallbackToRSSIWhenHardwareUnsupported() {
        let provider = MockRangingProvider(isHardwareSupported: false)
        var states: [RangingState] = []
        let cancellable = provider.state.sink { states.append($0) }
        defer { cancellable.cancel() }

        #expect(states.last == .fallback(rssiOnly: true))
    }
}
