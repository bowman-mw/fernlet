import Foundation
import NearbyInteraction
import Combine
import simd

// MARK: - RangingDistance

enum RangingDistance: Equatable {
    case unknown
    case meters(Double, direction: simd_float3?)

    static func == (lhs: RangingDistance, rhs: RangingDistance) -> Bool {
        switch (lhs, rhs) {
        case (.unknown, .unknown): return true
        case (.meters(let d1, let dir1), .meters(let d2, let dir2)):
            return d1 == d2 && dir1 == dir2
        default: return false
        }
    }
}

// MARK: - RangingState

enum RangingState: Equatable {
    case idle
    case running
    case invalidated(reason: String)
    case fallback(rssiOnly: Bool)
}

// MARK: - RangingProvider

@MainActor
protocol RangingProvider: AnyObject {
    var distance: AnyPublisher<RangingDistance, Never> { get }
    var state: AnyPublisher<RangingState, Never> { get }
    var isHardwareSupported: Bool { get }

    func start(with peerToken: Data) async throws
    func stop() async
    func myDiscoveryToken() async throws -> Data
}

// MARK: - TapConfirmedDetector

final class TapConfirmedDetector {
    private var window: [(timestamp: Date, distance: Double)] = []
    private let proximityThreshold = 0.05
    private let dwellSeconds = 1.0
    private let minimumSamples = 3

    func ingest(distanceMeters: Double, at timestamp: Date) -> Bool {
        window.append((timestamp, distanceMeters))
        let cutoff = timestamp.addingTimeInterval(-dwellSeconds)
        window.removeAll { $0.timestamp < cutoff }
        guard window.count >= minimumSamples else { return false }
        guard timestamp.timeIntervalSince(window.first!.timestamp) >= dwellSeconds else { return false }
        return window.allSatisfy { $0.distance < proximityThreshold }
    }

    func reset() { window.removeAll() }
}

// MARK: - NIRangingSession

@MainActor
final class NIRangingSession: NSObject, RangingProvider {

    enum RangingError: Error {
        case hardwareUnsupported
        case tokenUnavailable
        case invalidPeerToken
    }

    let isHardwareSupported: Bool

    private var niSession: NISession?
    private let distanceSubject = PassthroughSubject<RangingDistance, Never>()
    private let stateSubject = CurrentValueSubject<RangingState, Never>(.idle)

    var distance: AnyPublisher<RangingDistance, Never> { distanceSubject.eraseToAnyPublisher() }
    var state: AnyPublisher<RangingState, Never> { stateSubject.eraseToAnyPublisher() }

    init(isHardwareSupported: Bool? = nil) {
        if let override = isHardwareSupported {
            self.isHardwareSupported = override
        } else if #available(iOS 16.0, *) {
            self.isHardwareSupported = NISession.deviceCapabilities.supportsPreciseDistanceMeasurement
        } else {
            self.isHardwareSupported = NISession.isSupported
        }
        super.init()
        if !self.isHardwareSupported {
            stateSubject.send(.fallback(rssiOnly: true))
        }
    }

    func myDiscoveryToken() async throws -> Data {
        guard isHardwareSupported else { throw RangingError.hardwareUnsupported }
        let session = getOrCreateSession()
        guard let token = session.discoveryToken else { throw RangingError.tokenUnavailable }
        return try NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
    }

    func start(with peerTokenData: Data) async throws {
        guard isHardwareSupported else {
            stateSubject.send(.fallback(rssiOnly: true))
            return
        }
        guard let peerToken = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NIDiscoveryToken.self, from: peerTokenData) else {
            throw RangingError.invalidPeerToken
        }
        let session = getOrCreateSession()
        let config = NINearbyPeerConfiguration(peerToken: peerToken)
        session.run(config)
        stateSubject.send(.running)
    }

    func stop() async {
        niSession?.invalidate()
        niSession = nil
        stateSubject.send(.idle)
    }

    private func getOrCreateSession() -> NISession {
        if let existing = niSession { return existing }
        let session = NISession()
        session.delegate = self
        niSession = session
        return session
    }
}

// MARK: - NISessionDelegate

extension NIRangingSession: NISessionDelegate {
    nonisolated func session(_ session: NISession, didUpdate nearbyObjects: [NINearbyObject]) {
        Task { @MainActor [weak self] in
            guard let self, let first = nearbyObjects.first else { return }
            if let dist = first.distance {
                self.distanceSubject.send(.meters(Double(dist), direction: first.direction))
            } else {
                self.distanceSubject.send(.unknown)
            }
        }
    }

    nonisolated func session(_ session: NISession, didInvalidateWith error: Error) {
        Task { @MainActor [weak self] in
            self?.stateSubject.send(.invalidated(reason: error.localizedDescription))
        }
    }

    nonisolated func sessionWasSuspended(_ session: NISession) {}
    nonisolated func sessionSuspensionEnded(_ session: NISession) {}
}
