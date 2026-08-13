import XCTest
import FernletDomainModel
@testable import ProximityKit

@MainActor
final class FriendStateTests: XCTestCase {
    private let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Fuzzy fold

    func testFuzzyFoldHidesTheFiveWayState() {
        XCTAssertEqual(CompanionState.thriving.fuzzy, .thriving)
        XCTAssertEqual(CompanionState.okay.fuzzy, .okay)
        // sick / resting / tired all collapse to struggling — a friend can't tell them apart.
        XCTAssertEqual(CompanionState.tired.fuzzy, .struggling)
        XCTAssertEqual(CompanionState.resting.fuzzy, .struggling)
        XCTAssertEqual(CompanionState.sick.fuzzy, .struggling)
        // The render bucket for struggling is `tired` — never sick/resting, so the render can't leak it.
        XCTAssertEqual(FriendFuzzyState.struggling.representativeState, .tired)
    }

    // MARK: - Wire contract

    func testPayloadIsConstantLengthAcrossStatesAndCarriesNoNumbers() throws {
        let id = UUID()
        let appearance = CompanionAppearance.standard
        let encoder = JSONEncoder()
        let thriving = try encoder.encode(FriendStatePayload(state: .thriving, appearance: appearance, id: id))
        let okay = try encoder.encode(FriendStatePayload(state: .okay, appearance: appearance, id: id))
        let struggling = try encoder.encode(FriendStatePayload(state: .struggling, appearance: appearance, id: id))
        // Same id + appearance, only the 1-byte state code differs → identical ciphertext-plaintext length,
        // so a passive observer can't read the state off a sealed envelope's length.
        XCTAssertEqual(thriving.count, okay.count)
        XCTAssertEqual(okay.count, struggling.count)

        let json = String(data: thriving, encoding: .utf8)!.lowercased()
        for token in ["score", "goal", "component", "cycle", "period", "sick"] {
            XCTAssertFalse(json.contains(token), "friend-state payload leaked a token: \(token)")
        }
    }

    func testWellFormedRejectsOutOfRangeState() {
        var payload = FriendStatePayload(state: .okay, appearance: .standard)
        XCTAssertTrue(payload.isWellFormed)
        XCTAssertEqual(payload.fuzzyState, .okay)
        payload.state = 9   // a hostile peer's out-of-range code
        XCTAssertFalse(payload.isWellFormed)
        XCTAssertNil(payload.fuzzyState)
    }

    func testSanitizedAppearanceClampsHostileHex() {
        var appearance = CompanionAppearance.standard
        appearance.bodyCustomColorHex = String(repeating: "Z", count: 500)   // invalid + oversized
        appearance.clothingCustomColorHex = "#A1B2C3"                        // valid
        let clean = FriendStatePayload(state: .okay, appearance: appearance).sanitizedAppearance
        XCTAssertNil(clean.bodyCustomColorHex)
        XCTAssertEqual(clean.clothingCustomColorHex, "#A1B2C3")
    }

    // MARK: - Cache staleness

    func testCacheReturnsFreshStateAndExpiresPast30Days() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        var now = fixedNow
        let cache = FriendStateCache(fileURL: url, now: { now })
        cache.record(fingerprint: "abcd1234", fuzzyState: .struggling, appearance: .standard)
        XCTAssertEqual(cache.state(for: "abcd1234")?.fuzzyState, .struggling)

        now = fixedNow.addingTimeInterval(31 * 86_400)   // 31 days later
        XCTAssertNil(cache.state(for: "abcd1234"), "a month-old vibe is expired and not shown")
        try? FileManager.default.removeItem(at: url)
    }
}
