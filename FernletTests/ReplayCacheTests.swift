import Foundation
import Testing
import FernletDomainModel
@testable import Fernlet

@MainActor
struct ReplayCacheTests {
    /// Regression for prior finding #12: when the cache overflows it must evict the OLDEST
    /// entries, not the newest. Otherwise a flood of distinct IDs evicts the fingerprints of
    /// recent legitimate envelopes, letting those recent envelopes be replayed undetected.
    @Test func overflowEvictsOldestNotNewest() throws {
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        let cache = ReplayCache(maxEntries: 3, dateProvider: { now })

        let oldest = UUID()
        try cache.recordIfNew(envelopeID: oldest, createdAt: now)

        // Three newer IDs arrive, overflowing the cap of 3 and pushing `oldest` out.
        var newer: [UUID] = []
        for _ in 0..<3 {
            now = now.addingTimeInterval(1)
            let id = UUID()
            newer.append(id)
            try cache.recordIfNew(envelopeID: id, createdAt: now)
        }

        // The newest IDs are retained — replaying any of them is still detected.
        for id in newer {
            #expect(throws: FernletIdentityEnvelope.VerifyError.replayDetected) {
                try cache.recordIfNew(envelopeID: id, createdAt: now)
            }
        }

        // The oldest ID was evicted, so it is (incorrectly, but harmlessly) accepted as new —
        // it is still within the retention window, proving newest-retention is what matters.
        #expect(throws: Never.self) {
            try cache.recordIfNew(envelopeID: oldest, createdAt: now)
        }
    }
}
