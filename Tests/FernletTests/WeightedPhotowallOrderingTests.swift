import Foundation
import Testing
import FernletDomainModel
@testable import Fernlet

/// Deterministic (seeded-RNG) coverage for the home-photowall favorites weighting: hearted photos should
/// surface meaningfully more often than the rest without ever starving them. The statistics below are
/// fully repeatable because `SeededGenerator` produces a fixed stream for a given seed.
struct WeightedPhotowallOrderingTests {

    // MARK: - Weighting

    /// With one favorite among several non-favorites at 3× weight, the favorite lands in the FIRST
    /// position about three times as often as any single non-favorite (the exact per-step ratio).
    @Test func favoritesLeadAboutThreeTimesMoreOftenAtFirstPosition() {
        let favorite = UUID()
        let others = (0..<3).map { _ in UUID() }
        let ids = [favorite] + others
        var generator = SeededGenerator(seed: 0xF00D_CAFE)

        let trials = 6000
        var firstCounts: [UUID: Int] = [:]
        for _ in 0..<trials {
            let order = WeightedPhotowallOrdering.weightedOrder(
                ids: ids, favoriteIDs: [favorite], favoriteWeight: 3, using: &generator
            )
            firstCounts[order[0], default: 0] += 1
        }

        let favoriteFirst = firstCounts[favorite] ?? 0
        let averageOtherFirst = Double(others.compactMap { firstCounts[$0] }.reduce(0, +)) / Double(others.count)
        let ratio = Double(favoriteFirst) / averageOtherFirst
        #expect(ratio > 2.4 && ratio < 3.6, "favorite should lead ~3x more often (got \(ratio))")
        // Non-favorites still appear at the front sometimes — never starved.
        #expect(others.allSatisfy { (firstCounts[$0] ?? 0) > 0 })
    }

    /// Every photo, favorite or not, remains reachable in every position (all weights strictly positive):
    /// each id shows up at the front at least once over many draws.
    @Test func allPhotosRemainReachable() {
        let ids = (0..<5).map { _ in UUID() }
        let favorites: Set<UUID> = [ids[0]]
        var generator = SeededGenerator(seed: 0x1234_5678)

        var seenFirst: Set<UUID> = []
        for _ in 0..<4000 {
            let order = WeightedPhotowallOrdering.weightedOrder(
                ids: ids, favoriteIDs: favorites, favoriteWeight: 3, using: &generator
            )
            seenFirst.insert(order[0])
        }
        #expect(seenFirst == Set(ids))
    }

    /// Empty favorites degrade to a uniform shuffle — first-position frequency is roughly equal.
    @Test func emptyFavoritesDegradesToUniform() {
        let ids = (0..<4).map { _ in UUID() }
        var generator = SeededGenerator(seed: 0xABCD_EF01)

        let trials = 6000
        var firstCounts: [UUID: Int] = [:]
        for _ in 0..<trials {
            let order = WeightedPhotowallOrdering.weightedOrder(
                ids: ids, favoriteIDs: [], favoriteWeight: 3, using: &generator
            )
            firstCounts[order[0], default: 0] += 1
        }
        let expected = Double(trials) / Double(ids.count)  // 1500
        for id in ids {
            let count = Double(firstCounts[id] ?? 0)
            #expect(count > expected * 0.8 && count < expected * 1.2, "uniform-ish, got \(count)")
        }
    }

    /// When every photo is a favorite the weights are all equal → uniform among favorites (same shape as
    /// the empty-favorites case). Covers the "favorites-only set" edge.
    @Test func allFavoritesIsUniformAmongFavorites() {
        let ids = (0..<4).map { _ in UUID() }
        var generator = SeededGenerator(seed: 0x0BAD_F00D)

        let trials = 6000
        var firstCounts: [UUID: Int] = [:]
        for _ in 0..<trials {
            let order = WeightedPhotowallOrdering.weightedOrder(
                ids: ids, favoriteIDs: Set(ids), favoriteWeight: 3, using: &generator
            )
            firstCounts[order[0], default: 0] += 1
        }
        let expected = Double(trials) / Double(ids.count)
        for id in ids {
            let count = Double(firstCounts[id] ?? 0)
            #expect(count > expected * 0.8 && count < expected * 1.2, "uniform-ish, got \(count)")
        }
    }

    // MARK: - Purity / determinism

    /// Same seed → identical order; the result is always a permutation of the input (nothing dropped or
    /// duplicated), and favorite IDs not present in the input are harmless.
    @Test func deterministicPermutationUnderSeededGenerator() {
        let ids = (0..<6).map { _ in UUID() }
        let favorites: Set<UUID> = [ids[1], UUID()]  // second id favorited + a stray id not in the input

        var genA = SeededGenerator(seed: 42)
        var genB = SeededGenerator(seed: 42)
        let a = WeightedPhotowallOrdering.weightedOrder(ids: ids, favoriteIDs: favorites, favoriteWeight: 3, using: &genA)
        let b = WeightedPhotowallOrdering.weightedOrder(ids: ids, favoriteIDs: favorites, favoriteWeight: 3, using: &genB)

        #expect(a == b)
        #expect(Set(a) == Set(ids))
        #expect(a.count == ids.count)
    }

    /// Empty input yields an empty order; single input yields itself.
    @Test func edgeCounts() {
        var generator = SeededGenerator(seed: 7)
        #expect(WeightedPhotowallOrdering.weightedOrder(ids: [], favoriteIDs: [], favoriteWeight: 3, using: &generator).isEmpty)
        let only = UUID()
        #expect(WeightedPhotowallOrdering.weightedOrder(ids: [only], favoriteIDs: [only], favoriteWeight: 3, using: &generator) == [only])
    }

    // MARK: - Ranking wrapper

    /// The production ranking preserves the candidate set exactly (permutation only) — the id→payload
    /// reconstruction drops or duplicates nothing.
    @Test func rankingPreservesCandidateSet() {
        let photos = (0..<8).map { index in
            FriendPhotoPayload(imageData: Data([UInt8(index)]), senderName: "Friend")
        }
        let context = PhotowallSelectionContext(
            selectedAt: Date(timeIntervalSince1970: 0),
            derivedSignals: [],
            recentActivityNames: [],
            favoriteIDs: [photos[2].id, photos[5].id]
        )
        let ranked = FavoriteWeightedPhotowallPhotoRanking().rankedCandidates(from: photos, context: context)
        #expect(ranked.count == photos.count)
        #expect(Set(ranked.map(\.id)) == Set(photos.map(\.id)))
    }
}

/// SplitMix64 — a tiny deterministic generator so the weighting statistics are fully repeatable.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
