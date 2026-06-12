import Foundation
import NearbyInteraction
import Combine

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
        // NISession.discoveryToken can be nil briefly after init; wait one tick for it to populate.
        if session.discoveryToken == nil {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
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
                self.distanceSubject.send(.meters(max(0, Double(dist)), direction: first.direction))
            } else {
                self.distanceSubject.send(.unknown)
            }
        }
    }

    nonisolated func session(_ session: NISession, didInvalidateWith error: Error) {
        Task { @MainActor [weak self] in
            if self?.niSession === session {
                self?.niSession = nil
            }
            self?.stateSubject.send(.invalidated(reason: error.localizedDescription))
        }
    }

    nonisolated func sessionWasSuspended(_ session: NISession) {}
    nonisolated func sessionSuspensionEnded(_ session: NISession) {}
}
