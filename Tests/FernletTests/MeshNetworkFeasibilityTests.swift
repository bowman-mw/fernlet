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

    /// The spike's channel-binding label and its production successor must never be the same
    /// string. If they were, a DEBUG build and a shipping build would derive the SAME exporter
    /// secret from the same QUIC connection, and the probe would become a signing oracle for the
    /// shipping introduction — the exact thing the separate `…probe…` spellings exist to prevent.
    /// Nothing else fails when they collide: both sides still verify, because both use the same one.
    @Test func probeAndProductionMeshLabelsAreSeparateDomains() {
        let probeExporter = FernletCryptoPurpose.KeyDerivation.meshProbeTLSExporterV1
        let productionExporter = FernletCryptoPurpose.KeyDerivation.meshTLSExporterV1
        let probeIntroduction = FernletCryptoPurpose.Signature.meshProbeChannelIntroductionV1
        let productionIntroduction = FernletCryptoPurpose.Signature.meshChannelIntroductionV1

        #expect(probeExporter.rawValue == "fernlet.mesh.probe.tls-exporter.v1")
        #expect(productionExporter.rawValue == "fernlet.mesh.tls-exporter.v1")
        #expect(probeExporter.rawValue != productionExporter.rawValue)
        #expect(probeIntroduction.rawValue != productionIntroduction.rawValue)
        // The probe's spellings carry the `probe` marker; the production ones must not.
        #expect(probeExporter.rawValue.contains(".probe."))
        #expect(probeIntroduction.rawValue.contains(".probe."))
        #expect(!productionExporter.rawValue.contains(".probe."))
        #expect(!productionIntroduction.rawValue.contains(".probe."))
    }

    /// The thermal names are diagnostic TOKENS pasted into bug notes, not display text: they stay
    /// frozen English and exhaustive, so a soak report never reads "unknown" for a state iOS names.
    @Test @MainActor func thermalStateNamesAreFrozenTokens() {
        #expect(NetworkMeshFeasibilityProbe.thermalStateName(.nominal) == "nominal")
        #expect(NetworkMeshFeasibilityProbe.thermalStateName(.fair) == "fair")
        #expect(NetworkMeshFeasibilityProbe.thermalStateName(.serious) == "serious")
        #expect(NetworkMeshFeasibilityProbe.thermalStateName(.critical) == "critical")
        #expect(NetworkMeshFeasibilityProbe.timestamp(nil) == "never")
    }

    /// The P8 gate reads its numbers out of the copied diagnostic report (§15.1/§15.3), so every
    /// counter the plan names must actually appear in it. A counter that is only a field measures
    /// nothing on a device the developer cannot attach a debugger to.
    @Test @MainActor func theDiagnosticReportCarriesTheP8GateCounters() {
        let report = NetworkMeshFeasibilityProbe.shared.diagnosticReport
        for label in ["bytes sent:", "bytes received:", "connects:", "reconnects:",
                      "thermal state:", "low power mode:"] {
            #expect(report.contains(label), "diagnostic report is missing \"\(label)\"")
        }
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
