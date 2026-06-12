import CryptoKit
import Foundation

enum SealedBackupPayloadType: String, Codable, CaseIterable {
    case sensitiveNotes
    case periodData
}

struct SealedBackupRecord: Equatable {
    var payloadType: SealedBackupPayloadType
    var signingPublicKey: Data
    var keyAgreementPublicKey: Data
    var nonce: Data
    var ciphertext: Data
    var tag: Data
    var updatedAt: Date
}

enum SealedBackupError: Error, Equatable {
    case keyAgreementIdentityMismatch
    case malformedRecord
}

enum SealedBackupCrypto {
    @MainActor
    static func seal(
        _ plaintext: Data,
        payloadType: SealedBackupPayloadType,
        identityService: IdentityService,
        updatedAt: Date = Date()
    ) throws -> SealedBackupRecord {
        let key = try identityService.sealedBackupKey()
        let nonce = AES.GCM.Nonce()
        let signingPublicKey = identityService.localSigningPublicKey
        let sealedBox = try AES.GCM.seal(
            plaintext,
            using: key,
            nonce: nonce,
            authenticating: authenticatedData(payloadType: payloadType, signingPublicKey: signingPublicKey)
        )
        return SealedBackupRecord(
            payloadType: payloadType,
            signingPublicKey: signingPublicKey,
            keyAgreementPublicKey: identityService.localKeyAgreementPublicKey,
            nonce: nonce.data,
            ciphertext: sealedBox.ciphertext,
            tag: sealedBox.tag,
            updatedAt: updatedAt
        )
    }

    @MainActor
    static func open(_ record: SealedBackupRecord, identityService: IdentityService) throws -> Data {
        guard record.keyAgreementPublicKey == identityService.localKeyAgreementPublicKey else {
            throw SealedBackupError.keyAgreementIdentityMismatch
        }
        do {
            let nonce = try AES.GCM.Nonce(data: record.nonce)
            let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: record.ciphertext, tag: record.tag)
            return try AES.GCM.open(
                sealedBox,
                using: identityService.sealedBackupKey(),
                authenticating: authenticatedData(payloadType: record.payloadType, signingPublicKey: record.signingPublicKey)
            )
        } catch let error as SealedBackupError {
            throw error
        } catch {
            throw SealedBackupError.malformedRecord
        }
    }

    private static func authenticatedData(payloadType: SealedBackupPayloadType, signingPublicKey: Data) -> Data {
        Data(payloadType.rawValue.utf8) + Data([0]) + signingPublicKey
    }
}

@MainActor
final class SealedBackupService {
    private let cloudDataService: CloudKitDataService
    private let identityService: IdentityService

    init(cloudDataService: CloudKitDataService, identityService: IdentityService) {
        self.cloudDataService = cloudDataService
        self.identityService = identityService
    }

    func reconcile(_ plaintext: Data, payloadType: SealedBackupPayloadType, enabled: Bool) async throws {
        if enabled {
            let record = try SealedBackupCrypto.seal(
                plaintext,
                payloadType: payloadType,
                identityService: identityService
            )
            try await cloudDataService.saveSealedBackup(record)
        } else {
            try await cloudDataService.deleteSealedBackup(payloadType: payloadType)
        }
    }

    func restore(payloadType: SealedBackupPayloadType) async throws -> Data? {
        guard let record = try await cloudDataService.sealedBackup(payloadType: payloadType) else {
            return nil
        }
        return try SealedBackupCrypto.open(record, identityService: identityService)
    }
}

private extension AES.GCM.Nonce {
    var data: Data {
        withUnsafeBytes { Data($0) }
    }
}
