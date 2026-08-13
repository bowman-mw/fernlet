// FernletLockTests.swift
// FernletTests
//
// Unit tests for FernletLockService and PendingNarrativeBuffer.
// All Keychain writes go to real Keychain in the test process —
// each test uses a per-test lockService instance that cleans up after itself.

import Foundation
import FernletFoundation
import SwiftUI
import Testing
import CryptoKit
import UIKit
import FernletDomainModel
import PrivateStoreCore
import FernletLock
import FernletLockUI
@testable import Fernlet

// MARK: - Helpers

@MainActor
private func freshService() -> FernletLockService {
    let service = FernletLockService(
        keychainService: "com.fernlet.lock.test.\(UUID().uuidString)",
        // reset() sweeps the sealed-content device keys too; keep that off the real service.
        sealedContentKeyServices: ["com.fernlet.journal.test.\(UUID().uuidString)"],
        // reset() also purges the pending-narrative buffer; keep that off the process-wide scope.
        narrativeBufferScope: uniqueNarrativeBufferScope()
    )
    try? service.reset()      // Clear any leftover Keychain state
    return service
}

// MARK: - Configure + verify + unlock round-trips

@Suite(.serialized)
struct FernletLockTests {

    @MainActor
    @Test func pin4ConfigureAndUnlock() async throws {
        let service = freshService()

        try await service.configure(credential: .pin4("1234"), grantingScope: .privateHub)
        #expect(service.state == .unlocked(scope: .privateHub))
        #expect(service.credentialKind == .pin4)

        // Relocking and re-unlocking should work with the same PIN
        service.lock(reason: .manual)
        if case .locked = service.state { } else { Issue.record("Expected locked state") }

        let result = try await service.unlock(passcode: "1234", for: .privateHub)
        #expect(result.method == .passcode)
        #expect(service.state == .unlocked(scope: .privateHub))

        try? service.reset()
    }

    @MainActor
    @Test func pin6ConfigureAndUnlock() async throws {
        let service = freshService()

        try await service.configure(credential: .pin6("654321"), grantingScope: .privateHub)
        service.lock(reason: .manual)

        let result = try await service.unlock(passcode: "654321", for: .privateHub)
        #expect(result.method == .passcode)
        #expect(service.state == .unlocked(scope: .privateHub))

        try? service.reset()
    }

    @MainActor
    @Test func alphanumericConfigureAndUnlock() async throws {
        let service = freshService()

        try await service.configure(credential: .alphanumeric("hunter2-secure"), grantingScope: .privateHub)
        service.lock(reason: .manual)

        let result = try await service.unlock(passcode: "hunter2-secure", for: .privateHub)
        #expect(result.method == .passcode)
        #expect(service.state == .unlocked(scope: .privateHub))

        try? service.reset()
    }

    // MARK: - Wrong passcode increments attempt count

    @MainActor
    @Test func wrongPasscodeIncrementsAttemptCount() async throws {
        let service = freshService()

        try await service.configure(credential: .pin6("111111"), grantingScope: .privateHub)
        service.lock(reason: .manual)

        #expect(service.currentAttemptCount == 0)

        for expected in 1...3 {
            do {
                _ = try await service.unlock(passcode: "000000", for: .privateHub)
            } catch FernletLockError.invalidPasscode { }
            #expect(service.currentAttemptCount == expected)
        }

        try? service.reset()
    }

    // MARK: - 4 wrong attempts triggers cooldown level 1

    @MainActor
    @Test func fourWrongAttemptsTriggersCooldownLevel1() async throws {
        let service = freshService()

        try await service.configure(credential: .pin6("999999"), grantingScope: .privateHub)
        service.lock(reason: .manual)

        for _ in 0..<4 {
            do {
                _ = try await service.unlock(passcode: "000000", for: .privateHub)
            } catch { }
        }

        // Should now be in cooldown
        if case .locked(let deadline) = service.state {
            #expect(deadline != nil)
            let remaining = deadline!.timeIntervalSinceNow
            // Level 1 = 60 s; allow a few seconds of test latency
            #expect(remaining > 50 && remaining <= 61)
        } else {
            Issue.record("Expected locked state with cooldown deadline")
        }

        #expect(service.currentAttemptCount == 0)

        try? service.reset()
    }

    // MARK: - Cooldown progression 1m → 15m → 1h → 4h → reset-only

    @MainActor
    @Test func cooldownLevelProgression() async throws {
        let harness = LockTestHarness()
        defer { harness.cleanup() }
        let service = harness.makeService()

        try await service.configure(credential: .pin6("123456"), grantingScope: .privateHub)
        service.lock(reason: .manual)

        let expectedDurations: [TimeInterval] = [60, 900, 3600, 14400]

        for expectedDuration in expectedDurations {
            // Burn 4 attempts to reach this level's cooldown
            for _ in 0..<4 {
                do { _ = try await service.unlock(passcode: "wrong", for: .privateHub) } catch { }
            }

            if case .locked(let deadline) = service.state {
                #expect(deadline != nil)
                if let d = deadline {
                    let remaining = d.timeIntervalSince(harness.clock.now)
                    #expect(remaining == expectedDuration,
                            "Cooldown expected \(expectedDuration)s, got \(remaining)")
                }
            }

            harness.clock.advance(by: expectedDuration + 1)
            harness.uptime.advance(by: expectedDuration + 1)
        }

        for _ in 0..<(4 * 4) {
            do { _ = try await service.unlock(passcode: "bad", for: .privateHub) } catch { }
        }
        #expect(service.requiresReset)

        try? service.reset()
    }

    // MARK: - Successful unlock resets attempt count

    @MainActor
    @Test func successfulUnlockResetsAttemptCount() async throws {
        let service = freshService()

        try await service.configure(credential: .pin4("5678"), grantingScope: .privateHub)
        service.lock(reason: .manual)

        for _ in 0..<3 {
            do { _ = try await service.unlock(passcode: "0000", for: .privateHub) } catch { }
        }
        #expect(service.currentAttemptCount == 3)

        _ = try await service.unlock(passcode: "5678", for: .privateHub)
        #expect(service.currentAttemptCount == 0)

        try? service.reset()
    }

    // MARK: - attemptCount and cooldownLevel survive service restart (Keychain persistence)

    @MainActor
    @Test func attemptCountSurvivesServiceRestart() async throws {
        let serviceA = freshService()

        try await serviceA.configure(credential: .pin6("777777"), grantingScope: .privateHub)
        serviceA.lock(reason: .manual)

        for _ in 0..<2 {
            do { _ = try await serviceA.unlock(passcode: "000000", for: .privateHub) } catch { }
        }
        #expect(serviceA.currentAttemptCount == 2)

        let serviceB = FernletLockService(
            keychainService: serviceA.keychainService,
            sealedContentKeyServices: serviceA.sealedContentKeyServices,
            // A simulated relaunch shares the SAME buffer scope — same file, same key.
            narrativeBufferScope: serviceA.narrativeBufferScope
        )
        #expect(serviceB.currentAttemptCount == 2)

        try? serviceB.reset()
    }

    // MARK: - reset() deletes all Keychain items and buffer file

    @MainActor
    @Test func resetDeletesAllState() async throws {
        let service = freshService()

        try await service.configure(credential: .pin4("4321"), grantingScope: .privateHub)
        #expect(service.state == .unlocked(scope: .privateHub))
        service.lock(reason: .manual)

        for _ in 0..<4 {
            do { _ = try await service.unlock(passcode: "0000", for: .privateHub) } catch { }
        }
        #expect(KeychainItem.load(for: .cooldownMonotonicAnchor, service: service.keychainService) != nil)
        #expect(KeychainItem.load(for: .cooldownDurationSeconds, service: service.keychainService) != nil)

        try service.reset()

        #expect(service.state == .notConfigured)
        #expect(service.credentialKind == nil)
        #expect(service.currentAttemptCount == 0)
        #expect(!service.requiresReset)

        let service2 = FernletLockService(
            keychainService: service.keychainService,
            sealedContentKeyServices: service.sealedContentKeyServices,
            // A simulated relaunch shares the SAME buffer scope — same file, same key.
            narrativeBufferScope: service.narrativeBufferScope
        )
        #expect(service2.state == .notConfigured)
        #expect(KeychainItem.load(for: .cooldownMonotonicAnchor, service: service.keychainService) == nil)
        #expect(KeychainItem.load(for: .cooldownDurationSeconds, service: service.keychainService) == nil)
    }

    // MARK: - Content key available when unlocked, nil when locked

    @MainActor
    @Test func contentKeyAvailabilityWithLockCycle() async throws {
        let service = freshService()

        try await service.configure(credential: .pin6("246810"), grantingScope: .privateHub)
        let keyAfterConfigure = service.contentKey(for: .privateHub)
        #expect(keyAfterConfigure != nil)

        service.lock(reason: .manual)
        #expect(service.contentKey(for: .privateHub) == nil)

        _ = try await service.unlock(passcode: "246810", for: .privateHub)
        let keyAfterUnlock = service.contentKey(for: .privateHub)
        #expect(keyAfterUnlock != nil)

        service.lock(reason: .manual)
        _ = try await service.unlock(passcode: "246810", for: .privateHub)
        let keyAfterSecondUnlock = service.contentKey(for: .privateHub)
        #expect(keyAfterSecondUnlock != nil)

        let d1 = keyAfterUnlock!.withUnsafeBytes { Data($0) }
        let d2 = keyAfterSecondUnlock!.withUnsafeBytes { Data($0) }
        #expect(d1 == d2)

        try? service.reset()
    }

    // MARK: - changeCredential re-wraps same content key

    @MainActor
    @Test func changeCredentialPreservesContentKey() async throws {
        let service = freshService()

        try await service.configure(credential: .pin4("1111"), grantingScope: .privateHub)
        let originalKeyData = service.contentKey(for: .privateHub)!.withUnsafeBytes { Data($0) }

        try await service.changeCredential(current: "1111", new: .pin6("222222"))

        service.lock(reason: .manual)
        _ = try await service.unlock(passcode: "222222", for: .privateHub)

        let newKeyData = service.contentKey(for: .privateHub)!.withUnsafeBytes { Data($0) }
        #expect(originalKeyData == newKeyData)

        try? service.reset()
    }

    // MARK: - Credential validation

    @MainActor
    @Test func credentialValidationRejects() async throws {
        let service = freshService()

        await #expect(throws: FernletLockError.self) {
            try await service.configure(credential: .pin4("123"), grantingScope: .privateHub)    // too short
        }
        await #expect(throws: FernletLockError.self) {
            try await service.configure(credential: .pin6("12345"), grantingScope: .privateHub)  // too short
        }
        await #expect(throws: FernletLockError.self) {
            try await service.configure(credential: .alphanumeric("short"), grantingScope: .privateHub)  // < 8 chars
        }
        await #expect(throws: FernletLockError.self) {
            try await service.configure(credential: .pin4("12ab"), grantingScope: .privateHub)   // non-numeric
        }
    }

    // MARK: - PendingNarrativeBuffer round-trip

    @Test func pendingNarrativeBufferAppendDrainRoundTrip() throws {
        let scope = uniqueNarrativeBufferScope()
        defer { KeychainItem.deleteAll(service: scope.keychainService) }
        let buffer = PendingNarrativeBuffer(scope: scope)
        try buffer.purge()  // clean slate

        let payload = PendingNarrativePayload(
            hkExternalUUID: UUID().uuidString,
            dateKey: "2026-05-20",
            noteBytes: "Mild cramps.".data(using: .utf8),
            symptomFlagsBytes: Data([0b00000001]),
            customSymptomScalesBytes: nil
        )

        try buffer.append(payload)

        let drained = try buffer.drainAll()
        #expect(drained.count == 1)
        #expect(drained[0].hkExternalUUID == payload.hkExternalUUID)
        #expect(drained[0].dateKey == "2026-05-20")
        #expect(drained[0].noteBytes == payload.noteBytes)

        // drainAll() is non-destructive: re-draining returns the same entries
        // until the caller has persisted them and explicitly purges. This guards
        // against silently losing notes when a downstream insert fails partway.
        let drainedAgain = try buffer.drainAll()
        #expect(drainedAgain.count == 1)
        #expect(drainedAgain[0].hkExternalUUID == payload.hkExternalUUID)

        try buffer.purge()
        let afterPurge = try buffer.drainAll()
        #expect(afterPurge.isEmpty)
    }

    // MARK: - PendingNarrativeBuffer eviction at 50

    @Test func pendingNarrativeBufferEvictsAt50() throws {
        let scope = uniqueNarrativeBufferScope()
        defer { KeychainItem.deleteAll(service: scope.keychainService) }
        let buffer = PendingNarrativeBuffer(scope: scope)
        try buffer.purge()

        for i in 0..<55 {
            let payload = PendingNarrativePayload(
                hkExternalUUID: "uuid-\(i)",
                dateKey: "2026-05-\(String(format: "%02d", (i % 28) + 1))",
                noteBytes: nil,
                symptomFlagsBytes: nil,
                customSymptomScalesBytes: nil
            )
            try buffer.append(payload)
        }

        let all = try buffer.drainAll()
        #expect(all.count == 50)
        #expect(all.first?.hkExternalUUID == "uuid-5")
        #expect(all.last?.hkExternalUUID == "uuid-54")
    }

    // MARK: - PendingNarrativeBuffer encryption (ChaChaPoly)

    @Test func pendingNarrativeBufferIsEncrypted() throws {
        let scope = uniqueNarrativeBufferScope()
        defer { KeychainItem.deleteAll(service: scope.keychainService) }
        let buffer = PendingNarrativeBuffer(scope: scope)
        try buffer.purge()

        let secret = "top-secret-note-content"
        let payload = PendingNarrativePayload(
            hkExternalUUID: UUID().uuidString,
            dateKey: "2026-05-20",
            noteBytes: secret.data(using: .utf8),
            symptomFlagsBytes: nil,
            customSymptomScalesBytes: nil
        )
        try buffer.append(payload)

        let fileURL = PendingNarrativeBuffer.fileURL(in: scope.directory)
        let raw = try Data(contentsOf: fileURL)
        let rawString = String(data: raw, encoding: .utf8) ?? ""
        #expect(!rawString.contains(secret), "Raw file must not contain plaintext note")

        try buffer.purge()
    }

    // MARK: - PendingNarrativeBuffer per-scope isolation

    /// The behavioral half of the buffer's cross-suite isolation (the grep-wall in
    /// `PhotoDirectoryIsolationTests` is the other): two lock services on different
    /// `PendingNarrativeStorageScope`s, wipe one, the other's buffered notes survive.
    ///
    /// The wipe is BOTH halves of the identity: `purgePendingNarratives()` (the exact body of the
    /// `pendingNarrativeBufferPurgeHook` closure `ContentView.attachDeleteAllHooks` wires) plus a
    /// `deleteAll` over the scope's keychain service (what every harness `cleanup()` does today,
    /// and what the flagged owner call in `Docs/PrivacyWipeCoverage.md` will fold into delete-all).
    ///
    /// The THIRD service, built on A's scope only after B's wipe, is the load-bearing assertion
    /// twice over: it must load A's buffer key fresh from the keychain, so it fails if the two
    /// scopes secretly share a key service (B's sweep would have taken A's key, and the drain
    /// would throw on ChaChaPoly open — the file-path-only fix this family warns about); and it
    /// reads the file from disk, so it fails just as loudly if persistence silently stopped and
    /// the live instance A was draining from memory it never wrote.
    @MainActor
    @Test func theNarrativeBufferIsIsolatedPerScope() throws {
        let scopeA = uniqueNarrativeBufferScope()
        let scopeB = uniqueNarrativeBufferScope()
        defer {
            try? PendingNarrativeBuffer(scope: scopeA).purge()
            KeychainItem.deleteAll(service: scopeA.keychainService)
            KeychainItem.deleteAll(service: scopeB.keychainService)
        }
        func makeLockService(scope: PendingNarrativeStorageScope) -> FernletLockService {
            FernletLockService(
                keychainService: "com.fernlet.lock.test.\(UUID().uuidString)",
                sealedContentKeyServices: ["com.fernlet.journal.test.\(UUID().uuidString)"],
                narrativeBufferScope: scope
            )
        }
        func payload(_ uuid: String) -> PendingNarrativePayload {
            PendingNarrativePayload(
                hkExternalUUID: uuid, dateKey: "2026-08-12",
                noteBytes: "note for \(uuid)".data(using: .utf8),
                symptomFlagsBytes: nil, customSymptomScalesBytes: nil
            )
        }

        let serviceA = makeLockService(scope: scopeA)
        let serviceB = makeLockService(scope: scopeB)
        try serviceA.bufferPendingNarrative(payload("uuid-A"))
        try serviceB.bufferPendingNarrative(payload("uuid-B"))

        // The buffer key must LIVE on the scope's service ("com.fernlet.buffer.key.v2" is the
        // buffer's v2 account). This is the assertion the wipe below cannot replace: a regression
        // that sealed per-scope files under a process-wide key would survive that wipe — the test
        // only sweeps B's NAMED service — and every scoped buffer would share one key again.
        #expect(KeychainItem.load(account: "com.fernlet.buffer.key.v2", service: scopeA.keychainService) != nil,
                "A's buffer key is not on A's scoped keychain service")

        // B's wipe: the real purge funnel, plus the key half its harness cleanup sweeps.
        try serviceB.purgePendingNarratives()
        KeychainItem.deleteAll(service: scopeB.keychainService)

        // A intact through the live instance…
        let drainedA = try serviceA.drainPendingNarratives()
        #expect(drainedA.map(\.hkExternalUUID) == ["uuid-A"], "A's buffered note did not survive B's wipe")

        // …and through a FRESH service on A's scope, built after the wipe — same file, same key.
        let serviceC = makeLockService(scope: scopeA)
        let drainedC = try serviceC.drainPendingNarratives()
        #expect(drainedC.map(\.hkExternalUUID) == ["uuid-A"],
                "a fresh service on A's scope could not reopen A's buffer — file or key was shared with B")

        // And the wipe actually wiped: a fresh service on B's scope finds nothing.
        let serviceB2 = makeLockService(scope: scopeB)
        #expect(try serviceB2.drainPendingNarratives().isEmpty, "B's wipe left buffered notes behind")
    }

    /// Pins `.production` to the shipped identity — the exact file path and keychain service the
    /// buffer used before the scope seam existed — so the seam that made it injectable can never
    /// silently migrate a real install. The spelled-out path is the pre-seam spelling verbatim.
    @Test func theProductionNarrativeBufferScopeResolvesToTheShippedIdentity() {
        let scope = PendingNarrativeStorageScope.production
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        #expect(scope.directory.path == support.appendingPathComponent("Fernlet", isDirectory: true).path)
        #expect(PendingNarrativeBuffer.fileURL(in: scope.directory).path
                == support.appendingPathComponent("Fernlet/pending-narratives.bin").path)
        #expect(scope.keychainService == "com.fernlet.narrative-buffer")
    }

    // MARK: - FernletLockGate: onDisappear locks

    @MainActor
    @Test func lockGateCallsLockOnDisappear() async throws {
        let service = freshService()

        try await service.configure(credential: .pin6("135246"), grantingScope: .privateHub)
        #expect(service.state == .unlocked(scope: .privateHub))

        service.lock(reason: .viewDisappeared)
        if case .locked = service.state { } else {
            Issue.record("Gate's onDisappear must call lock(reason: .viewDisappeared)")
        }

        try? service.reset()
    }

    @MainActor
    @Test func privateHubSiblingMovementPreservesUnlockedSessionUntilOuterGateDisappears() async throws {
        let service = freshService()
        guard let windowScene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            Issue.record("Expected an active window scene for SwiftUI lifecycle testing")
            return
        }
        var window: UIWindow? = UIWindow(windowScene: windowScene)
        window?.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        defer {
            window?.isHidden = true
            window = nil
            try? service.reset()
        }

        try await service.configure(credential: .pin6("135246"), grantingScope: .privateHub)
        #expect(service.state == .unlocked(scope: .privateHub))

        let hostingController = UIHostingController(
            rootView: HubMovementLockHarness(showChild: true)
                .environment(service)
        )
        window?.rootViewController = hostingController
        window?.makeKeyAndVisible()
        try await Task.sleep(nanoseconds: 100_000_000)

        hostingController.rootView = HubMovementLockHarness(showChild: false)
            .environment(service)
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(service.state == .unlocked(scope: .privateHub))

        window?.isHidden = true
        window?.rootViewController = nil
        try await Task.sleep(nanoseconds: 100_000_000)

        if case .locked(let cooldownDeadline) = service.state {
            #expect(cooldownDeadline == nil)
        } else {
            Issue.record("Outer hub gate disappearance should lock without cooldown")
        }
    }

    @MainActor
    @Test func inactiveLockGateDoesNotLockOnDisappear() async throws {
        let service = freshService()
        guard let windowScene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            Issue.record("Expected an active window scene for SwiftUI lifecycle testing")
            return
        }
        var window: UIWindow? = UIWindow(windowScene: windowScene)
        window?.frame = CGRect(x: 0, y: 0, width: 100, height: 100)

        try await service.configure(credential: .pin6("135246"), grantingScope: .privateHub)
        #expect(service.state == .unlocked(scope: .privateHub))

        window?.rootViewController = UIHostingController(
            rootView: Text("hi")
                .fernletLockGate(scope: .privateHub, active: false)
                .environment(service)
        )
        window?.makeKeyAndVisible()
        await Task.yield()

        window?.rootViewController = nil
        await Task.yield()

        #expect(service.state == .unlocked(scope: .privateHub))

        window?.isHidden = true
        window = nil
        try? service.reset()
    }
}
private struct HubMovementLockHarness: View {
    let showChild: Bool

    var body: some View {
        VStack {
            if showChild {
                Text("inner")
                    .fernletLockGate(scope: .privateHub, active: false)
            }
        }
        .fernletLockGate(scope: .privateHub)
    }
}
