import CryptoKit
import FernletCrypto
import Foundation
import ProximityKit
import Security
import Testing
@testable import Fernlet

/// Pins the parts of the physical-device spike that can be validated without a radio.
@Suite(.serialized)
struct MeshNetworkFeasibilityTests {
    @Test @MainActor func probeUsesAnInfrastructureProfileInTheSimulator() {
        #expect(MeshProbeNetworkProfile.runsInSimulator)
        #expect(MeshProbeNetworkProfile.displayName(peerToPeerIncluded: false) == "Simulator infrastructure")
        #expect(MeshProbeNetworkProfile.displayName(peerToPeerIncluded: true) == "Simulator infrastructure")

        let probe = NetworkMeshFeasibilityProbe.shared
        #expect(!probe.canUseInfrastructureCompatibility)
        #expect(probe.pathPolicyDescription == "Infrastructure only")
        #expect(probe.transportDisplayName == "Simulator infrastructure")
    }

    @Test func discoveryPolicyRejectsSelfAndPreviouslyFailedCandidates() {
        let attemptedIDs: Set<String> = ["failed"]

        #expect(!MeshProbeDiscoveryPolicy.allowsOutboundConnection(
            localServiceName: "fernlet-probe-b",
            candidateServiceName: "fernlet-probe-b",
            candidateID: "self",
            attemptedEndpointIDs: attemptedIDs,
            localRunsInSimulator: false,
            candidateRunsInSimulator: false
        ))
        #expect(!MeshProbeDiscoveryPolicy.allowsOutboundConnection(
            localServiceName: "fernlet-probe-b",
            candidateServiceName: "fernlet-probe-c",
            candidateID: "failed",
            attemptedEndpointIDs: attemptedIDs,
            localRunsInSimulator: false,
            candidateRunsInSimulator: false
        ))
        #expect(MeshProbeDiscoveryPolicy.allowsOutboundConnection(
            localServiceName: "fernlet-probe-b",
            candidateServiceName: "fernlet-probe-c",
            candidateID: "fresh",
            attemptedEndpointIDs: attemptedIDs,
            localRunsInSimulator: false,
            candidateRunsInSimulator: false
        ))
        #expect(MeshProbeDiscoveryPolicy.allowsOutboundConnection(
            localServiceName: "fernlet-probe-z",
            candidateServiceName: "fernlet-probe-a",
            candidateID: "device",
            attemptedEndpointIDs: attemptedIDs,
            localRunsInSimulator: true,
            candidateRunsInSimulator: false
        ))
        #expect(!MeshProbeDiscoveryPolicy.allowsOutboundConnection(
            localServiceName: "fernlet-probe-a",
            candidateServiceName: "fernlet-probe-z",
            candidateID: "simulator",
            attemptedEndpointIDs: attemptedIDs,
            localRunsInSimulator: false,
            candidateRunsInSimulator: true
        ))
    }

    @Test func probeTLSIdentityCanBeImported() throws {
        let identity = try MeshProbeTLSIdentity.load()

        #expect(sec_identity_copy_ref(identity) != nil)
    }

    @Test func datagramDiagnosticLabelsDoNotExposePayloads() {
        #expect(MeshProbeDatagram.label(for: MeshProbeDatagram.ping) == "ping")
        #expect(
            MeshProbeDatagram.label(for: Data(repeating: 4, count: 7))
                == "an unrecognized 7-byte datagram"
        )
        let unavailable = MeshProbeError.datagramUnavailable(0).errorDescription ?? ""
        #expect(unavailable.contains("0 bytes"))
    }

    @Test func signedIntroductionRejectsAnyChangedChannelBinding() throws {
        let signingKey = Curve25519.Signing.PrivateKey()
        var introduction = makeIntroduction()
        introduction.signature = try signingKey.signature(for: introduction.canonicalSigningBytes)

        #expect(introduction.verifies(using: signingKey.publicKey.rawRepresentation))

        var changed = makeIntroduction(
            channelBindingHash: Data(repeating: 9, count: MeshProbeConstants.channelBindingByteCount)
        )
        changed.signature = introduction.signature
        #expect(!changed.verifies(using: signingKey.publicKey.rawRepresentation))
    }

    @Test @MainActor func probeInfoPlistConfigurationAllowsTheDeviceSpike() throws {
        let plist = try appInfoPlist()
        let services = plist["NSBonjourServices"] as? [String] ?? []
        let taskIdentifiers = plist["BGTaskSchedulerPermittedIdentifiers"] as? [String] ?? []
        let localNetworkCopy = plist["NSLocalNetworkUsageDescription"] as? String ?? ""

        #expect(services.contains(NetworkMeshFeasibilityProbe.bonjourServiceType))
        #expect(taskIdentifiers.contains(NetworkMeshFeasibilityProbe.backgroundTaskIdentifierPattern))
        #expect(NetworkMeshFeasibilityProbe.backgroundTaskRegistrationIdentifier == NetworkMeshFeasibilityProbe.backgroundTaskIdentifier)
        #expect(NetworkMeshFeasibilityProbe.backgroundTaskRegistrationIdentifier != NetworkMeshFeasibilityProbe.backgroundTaskIdentifierPattern)
        #expect(localNetworkCopy.contains("mesh photos"))
        #expect(localNetworkCopy.contains("background"))
    }

    private func makeIntroduction(
        channelBindingHash: Data = Data(repeating: 5, count: MeshProbeConstants.channelBindingByteCount)
    ) -> MeshProbeChannelIntroduction {
        MeshProbeChannelIntroduction(
            protocolVersion: MeshProbeConstants.protocolVersion,
            meshID: MeshProbeConstants.meshID,
            membershipEpoch: MeshProbeConstants.membershipEpoch,
            initiatorSigningPublicKey: Data(repeating: 1, count: MeshProbeConstants.signingKeyByteCount),
            responderSigningPublicKey: Data(repeating: 2, count: MeshProbeConstants.signingKeyByteCount),
            initiatorNonce: Data(repeating: 3, count: MeshProbeConstants.nonceByteCount),
            responderNonce: Data(repeating: 4, count: MeshProbeConstants.nonceByteCount),
            channelBindingHash: channelBindingHash,
            signature: Data()
        )
    }

    private func appInfoPlist() throws -> [String: Any] {
        let url = RepoRoot.url.appendingPathComponent("App/Fernlet/Info.plist")
        let data = try Data(contentsOf: url)
        let value = try PropertyListSerialization.propertyList(from: data, format: nil)
        guard let plist = value as? [String: Any] else {
            Issue.record("The app Info.plist was not a dictionary.")
            return [:]
        }
        return plist
    }
}
