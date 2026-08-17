import ProximityKit
import Foundation
import AIContext
import AIProviders
import LocalPersistence
import FernletFoundation
import Observation

#if canImport(FoundationModels)
import FoundationModels
import FernletDomainModel
#endif

// MARK: - Photowall seed

/// One prepared tile for the Home photowall strip: caption, polaroid rotation, a themed color
/// index, and (optionally) a friend-photo id to render.
///
/// Built once per launch by ``LaunchPreparationService`` and stored on `FernletStore.photowallSeeds`;
/// `HomeView` maps these into `PhotowallTile`s.
struct PhotowallSeed: Identifiable {
    let id = UUID()
    let caption: String
    let rotation: Double
    let colorIndex: Int  // 0–3, mapped to themed colors in the view
    let photoID: UUID?
}

/// The inputs a ``PhotowallPhotoRanking`` may weigh when ordering candidate friend photos:
/// selection time, current derived signals, recent activity names, and the user's favorites.
///
/// Assembled by ``LaunchPreparationService`` from live store state; rankings are free to ignore
/// any of it (the random ranking does).
struct PhotowallSelectionContext {
    let selectedAt: Date
    let derivedSignals: [DerivedSignalRecord]
    let recentActivityNames: [String]
    /// Photo IDs the user has hearted (favorited) in the friend photo feed. Weighted higher by the
    /// default ranking so hearted photos surface on the home photowall more often. Defaults to empty
    /// (uniform selection) for callers/tests that don't supply favorites.
    let favoriteIDs: Set<UUID>

    init(
        selectedAt: Date,
        derivedSignals: [DerivedSignalRecord],
        recentActivityNames: [String],
        favoriteIDs: Set<UUID> = []
    ) {
        self.selectedAt = selectedAt
        self.derivedSignals = derivedSignals
        self.recentActivityNames = recentActivityNames
        self.favoriteIDs = favoriteIDs
    }
}

/// Strategy seam for ordering friend-photo candidates for the Home photowall.
///
/// Conformers: ``RandomPhotowallPhotoRanking`` (uniform shuffle, the test-friendly baseline) and
/// ``FavoriteWeightedPhotowallPhotoRanking`` (the production default, hearted photos weighted up).
/// ``PhotowallPhotoSelector`` consumes the ranking and layers the freshness/history rules on top.
protocol PhotowallPhotoRanking {
    func rankedCandidates(
        from photos: [FriendPhotoPayload],
        context: PhotowallSelectionContext
    ) -> [FriendPhotoPayload]
}

/// The simplest ``PhotowallPhotoRanking``: a uniform shuffle that ignores the context.
///
/// Kept as an injectable baseline for tests and as the behavior favorites-weighting degrades to
/// when no photo is hearted.
struct RandomPhotowallPhotoRanking: PhotowallPhotoRanking {
    func rankedCandidates(
        from photos: [FriendPhotoPayload],
        context: PhotowallSelectionContext
    ) -> [FriendPhotoPayload] {
        _ = context
        return photos.shuffled()
    }
}

/// Pure, seedable weighted-shuffle used to order home-photowall candidates so hearted (favorited) friend
/// photos surface more often than the rest — without ever starving the non-favorites (they keep 1× weight
/// and stay reachable in every position).
///
/// Extracted from ``FavoriteWeightedPhotowallPhotoRanking`` so the favorites-weighting is
/// deterministically unit-testable under a seeded generator.
enum WeightedPhotowallOrdering {
    /// Reorders `ids` by weighted random sampling WITHOUT replacement: at each step an id in `favoriteIDs`
    /// is drawn with `favoriteWeight`× the probability of a non-favorite. Deterministic for a given
    /// `generator` state. Empty `favoriteIDs` (or a non-positive weight) degrades to a uniform shuffle; an
    /// all-favorites input is a uniform shuffle among the favorites. Every id stays reachable in every
    /// position because all weights are strictly positive.
    static func weightedOrder<R: RandomNumberGenerator>(
        ids: [UUID],
        favoriteIDs: Set<UUID>,
        favoriteWeight: Double,
        using generator: inout R
    ) -> [UUID] {
        // R5: a non-finite weight would make `total` infinite and `Double.random(in: 0..<total)` a
        // trap, so an unusable weight degrades to the uniform-shuffle default rather than crashing.
        let favoriteWeight = (favoriteWeight.isFinite && favoriteWeight > 0) ? favoriteWeight : 1
        var remaining = ids
        var result: [UUID] = []
        result.reserveCapacity(remaining.count)
        while !remaining.isEmpty {
            let weights = remaining.map { favoriteIDs.contains($0) ? favoriteWeight : 1 }
            let total = weights.reduce(0, +)
            var threshold = Double.random(in: 0..<total, using: &generator)
            var chosenIndex = remaining.count - 1
            for index in weights.indices {
                threshold -= weights[index]
                if threshold < 0 {
                    chosenIndex = index
                    break
                }
            }
            result.append(remaining.remove(at: chosenIndex))
        }
        return result
    }
}

/// The home photowall's default ranking: a weighted shuffle that surfaces hearted (favorited) friend
/// photos more often than the rest without starving them.
///
/// Favorites carry `favoriteWeight`× the draw weight of a non-favorite; with no favorites this
/// reduces to a plain uniform shuffle. The sampling itself lives in the pure, seedable
/// ``WeightedPhotowallOrdering`` helper.
struct FavoriteWeightedPhotowallPhotoRanking: PhotowallPhotoRanking {
    /// How much likelier a favorited photo is to be drawn at each step than a non-favorite. ~3× per the
    /// tester decision: favorites appear meaningfully more, others still show up.
    var favoriteWeight: Double = 3

    func rankedCandidates(
        from photos: [FriendPhotoPayload],
        context: PhotowallSelectionContext
    ) -> [FriendPhotoPayload] {
        var generator = SystemRandomNumberGenerator()
        let order = WeightedPhotowallOrdering.weightedOrder(
            ids: photos.map(\.id),
            favoriteIDs: context.favoriteIDs,
            favoriteWeight: favoriteWeight,
            using: &generator
        )
        let byID = Dictionary(photos.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return order.compactMap { byID[$0] }
    }
}

/// Picks which friend-photo ids fill the Home photowall this launch: dedupes candidates, ranks
/// them via the injected ``PhotowallPhotoRanking``, prefers photos NOT shown last time, and
/// persists the new selection to `UserDefaults` as next launch's "previous" set.
///
/// The history key keeps the wall rotating across launches instead of resurfacing the same
/// photos; defaults/history-key/ranking are all injectable for tests.
struct PhotowallPhotoSelector {
    private let defaults: UserDefaults
    private let historyKey: String
    private let ranking: any PhotowallPhotoRanking

    init(
        defaults: UserDefaults = .standard,
        historyKey: String = "fernlet.homePhotowall.previousPhotoIDs",
        ranking: any PhotowallPhotoRanking = FavoriteWeightedPhotowallPhotoRanking()
    ) {
        self.defaults = defaults
        self.historyKey = historyKey
        self.ranking = ranking
    }

    func selectPhotoIDs(
        from photos: [FriendPhotoPayload],
        count: Int,
        context: PhotowallSelectionContext
    ) -> [UUID] {
        guard count > 0 else { return [] }
        let previousIDs = previousPhotoIDs()
        let uniquePhotos = photos.reduce(into: [FriendPhotoPayload]()) { result, photo in
            if !result.contains(where: { $0.id == photo.id }) {
                result.append(photo)
            }
        }
        let ranked = ranking.rankedCandidates(from: uniquePhotos, context: context)
        let fresh = ranked.filter { !previousIDs.contains($0.id) }
        let previous = ranked.filter { previousIDs.contains($0.id) }
        let selected = Array((fresh + previous).prefix(count).map(\.id))
        defaults.set(selected.map(\.uuidString), forKey: historyKey)
        return selected
    }

    private func previousPhotoIDs() -> Set<UUID> {
        Set((defaults.stringArray(forKey: historyKey) ?? []).compactMap(UUID.init(uuidString:)))
    }
}

// MARK: - Launch preparation service

/// The second-stage launch pipeline: everything ``ContentView`` runs between "store loaded" and
/// "main interface visible", behind the companion launch screen.
///
/// `prepare(store:)` reconciles guided-workout and cooking runs from the app-group container
/// (Lock Screen / Siri actions made while the app was gone), sweeps stranded plaintext data-export
/// files, builds the photowall seeds (via ``PhotowallPhotoSelector``), backfills missing day
/// summaries (capped per run, once per calendar day, ambient-tier AI with an intentionally empty
/// fallback), generates the companion thought (Foundation Models with a deterministic
/// signal-based fallback), and backfills workouts from Health — then flips `isDone` after a
/// minimum display time. All AI calls route through `FernletAIGate` and are recorded to
/// `AIAuditLog`. @MainActor + @Observable: `isDone`/`statusMessage` drive the launch UI.
@MainActor
@Observable
final class LaunchPreparationService {
    /// Set once `prepare(store:)` finishes; `ContentView` cross-fades to the main interface on it.
    private(set) var isDone = false
    /// The rotating status line the launch screen shows while preparation runs.
    private(set) var statusMessage = initialStatusMessage
    private let photowallPhotoSelector: PhotowallPhotoSelector

    /// The first status line, shared with `FernletStoreLoader` so both launch phases open on the
    /// same message.
    static let initialStatusMessage = "Checking in with your body..."

    init(photowallPhotoSelector: PhotowallPhotoSelector? = nil) {
        self.photowallPhotoSelector = photowallPhotoSelector ?? PhotowallPhotoSelector()
    }

    /// Runs the whole preparation pass once (re-entry is a no-op via `isDone`); called from
    /// `ContentView`'s launch task. Holds the launch screen for a ~1.4 s minimum so the status
    /// text settles instead of flashing.
    func prepare(store: FernletStore) async {
        guard !isDone else { return }

        let startedAt = Date()
        statusMessage = Self.initialStatusMessage
        await Task.yield()

        // The guided-workout run now survives a kill in the app-group container. Reconcile it: a finish
        // made from the Lock Screen is logged, an abandoned (long-untouched) run is retired, a live run
        // is adopted (resumable from the Move-root card). If nothing is active, reconcile also retires
        // any orphaned activity still on screen.
        store.reconcileGuidedRunFromAppGroup()

        // Same discipline for the cooking runner: a Next/Finish made from the Lock Screen / Siri while the
        // app was gone must be picked up at launch, and an abandoned or finished cook must be retired here
        // — otherwise an orphan cooking Live Activity lingers until the OS cap when relaunch lands anywhere
        // but the Food tab. Cheap and independent of which tab is on screen (mirrors the guided call).
        store.reconcileCookingRunFromAppGroup()

        // A plaintext "export my data" dump is written to tmp/ for the share sheet and purged when the
        // sheet closes — but a kill/crash/jettison mid-share leaves the full decrypted dump on disk. Launch
        // is a point where no share can be in flight, so sweep any survivor here (belt-and-braces with the
        // pre-write sweep in writeDataExportFile()).
        // R7: a failed sweep leaves a full plaintext dump on disk, so it is named rather than
        // assumed. Launch continues — the pre-write sweep and "Delete everything" both cover it.
        if !store.purgeDataExports() {
            FernletAuditLog.log("privacy.export.purgeFailed", context: ["site": "launch"])
        }

        // Keep launch work deterministic and cheap so the first screen can animate.
        store.photowallSeeds = buildPhotowallSeeds(store: store)
        statusMessage = "Reading your recent patterns..."
        await backfillDaySummaries(for: store)
        store.storeCompanionThought(await generateCompanionThought(for: store))
        await store.backfillWorkoutsFromHealthIfNeeded()

        // Cycle status messages while async work runs.
        Task { @MainActor in
            // `Task.sleep` throws only on cancellation, and a cancelled cycler must stop mutating
            // `statusMessage` — returning IS the recovery.
            do { try await Task.sleep(for: .seconds(0.55)) } catch { return }
            guard !isDone else { return }
            statusMessage = "Preparing your day summary..."
            do { try await Task.sleep(for: .seconds(0.55)) } catch { return }
            guard !isDone else { return }
            statusMessage = "Getting Fernlet ready..."
        }

        // Minimum display time so the status text has time to settle.
        let elapsed = Date().timeIntervalSince(startedAt)
        let minimumSeconds = 1.4
        if elapsed < minimumSeconds {
            do {
                try await Task.sleep(for: .seconds(minimumSeconds - elapsed))
            } catch {
                // `Task.sleep` throws only CancellationError: the launch task was torn down. Fall
                // through and still set `isDone` below — a re-fired `.task` must not re-run
                // reconcile/backfill.
            }
        }

        isDone = true
        StartupTiming.endAppLaunch()
    }

    // MARK: - Photowall

    private func buildPhotowallSeeds(store: FernletStore) -> [PhotowallSeed] {
        let categories = Array(
            Set(store.memories.suffix(30).map { $0.category.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) })
        ).filter { $0.count >= 3 }.sorted()

        let defaults = ["morning", "meal", "movement", "moment"]
        let captions = Array((categories + defaults).prefix(4))
        let selectedPhotoIDs = photowallPhotoSelector.selectPhotoIDs(
            from: store.meshNetworkManager.meshPhotos,
            count: 4,
            context: PhotowallSelectionContext(
                selectedAt: Date(),
                derivedSignals: store.derivedSignals,
                recentActivityNames: store.day.workouts.map(\.name),
                favoriteIDs: store.meshNetworkManager.allFavoritePhotoIDs
            )
        )

        let rotations: [Double] = [-3, 2, -1, 3]
        return (0..<4).map { i in
            PhotowallSeed(
                caption: i < captions.count ? captions[i] : defaults[i % defaults.count],
                rotation: rotations[i],
                colorIndex: i,
                photoID: selectedPhotoIDs.indices.contains(i) ? selectedPhotoIDs[i] : nil
            )
        }
    }

    // MARK: - Day summary

    /// Most day summaries to generate in one launch. Each generation is an ambient model call that
    /// charges the daily budget; on a first launch over a long history an uncapped backfill would burn
    /// straight to the sleepy floor before the user does anything. Capping per run spreads the burn
    /// across days (the once-per-day gate resumes tomorrow) so a fresh install's early mornings keep a
    /// live budget for the user's own taps.
    private static let daySummaryBackfillPerRunCap = 10

    /// Generates day summaries for logged days (except today) missing one, most recent first, up to a
    /// per-run cap. Gated to run at most once per calendar day per device (first open after midnight);
    /// remaining days are picked up on subsequent days. When Foundation Models is unavailable the day's
    /// slot is intentionally left empty (spec) rather than filled with deterministic fallback text.
    private func backfillDaySummaries(for store: FernletStore) async {
        let todayKey = store.todayKey
        if UserDefaults.standard.string(forKey: Self.daySummaryRunKeyDefault) == todayKey { return }

        let dayKeys = store.loadDays().keys
            .filter { $0 != todayKey }
            .sorted(by: >)
        var generated = 0
        for key in dayKeys {
            if let existing = store.dailyScores.first(where: { $0.dateKey == key })?.daySummaryText,
               !existing.isEmpty { continue }
            let day = store.loadDay(for: key)
            guard !day.meals.isEmpty || !day.workouts.isEmpty else { continue }
            if generated >= Self.daySummaryBackfillPerRunCap { break }
            if let summary = await makeDaySummaryText(for: day, store: store), !summary.isEmpty {
                store.storeDaySummary(summary, for: key)
                generated += 1
            }
            // When the summary is nil, the slot is left empty on purpose (FM unavailable).
        }
        // Once-per-calendar-day gate: any day still missing a summary is picked up on the next day's
        // first launch, so a long backlog drains a bounded slice at a time instead of all at once.
        UserDefaults.standard.set(todayKey, forKey: Self.daySummaryRunKeyDefault)
    }

    private func makeDaySummaryText(for day: FernletDay, store: FernletStore) async -> String? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), isFoundationModelAvailable, store.settings.aiStatus != .off {
            return await foundationModelsDaySummary(for: day, gate: store.aiGate)
        }
        #endif
        // Spec: leave the day-summary slot empty when Foundation Models is unavailable.
        return nil
    }

    // MARK: - Companion thought

    private func generateCompanionThought(for store: FernletStore) async -> String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), isFoundationModelAvailable, store.settings.aiStatus != .off {
            if let thought = await foundationModelsThought(for: store) { return thought }
        }
        #endif
        return deterministicThought(for: store)
    }

    private func deterministicThought(for store: FernletStore) -> String {
        let signals = store.derivedSignals
        if let energy = signals.first(where: { $0.signalName == "energyTrend" }) {
            if energy.value == "low" { return "Energy has been low lately. Rest counts as care." }
            if energy.value == "rising" { return "Something has been building. Notice the upward pull." }
        }
        if let mood = signals.first(where: { $0.signalName == "moodTrend" }) {
            if mood.value == "needs gentleness" { return "Some harder days in the window. Notice what is still steady." }
            if mood.value == "improving" { return "The mood trend has been moving upward. Quiet progress." }
        }
        if let readiness = signals.first(where: { $0.signalName == "intensityReadiness" }) {
            if readiness.value == "ready for light" { return "Today looks like a day to move gently and restore." }
        }
        if let eating = signals.first(where: { $0.signalName == "eatingPattern" }) {
            if eating.value == "light" { return "Nutrition has been lighter lately. One nourishing meal is enough." }
        }
        return "A few ordinary care notes are here. Keep the day simple."
    }

    // MARK: - Foundation Models

    private var isFoundationModelAvailable: Bool {
        FoodSelectionAvailability.isFoundationModelAvailable
    }

    /// Device-local (not synced) UserDefaults key gating the once-per-day day-summary backfill.
    private static let daySummaryRunKeyDefault = "fernlet.daySummary.lastRunKey"

    #if canImport(FoundationModels)
    /// Day summary is an AMBIENT/background task (`standard` tier, runs at launch) → `userInvoked:
    /// false`. In the sleepy band it takes the deterministic path (an empty slot, per spec).
    @available(iOS 26.0, *)
    private func foundationModelsDaySummary(for day: FernletDay, gate: FernletAIGate) async -> String? {
        let sleep = day.sleep
        let sleepHours = sleep?.hours
        let payload = DaySummaryPayload(
            mealNames: day.meals.prefix(5).map(\.name),
            workoutNames: day.workouts.prefix(3).map(\.name),
            sleepQualityLabel: sleep.map { $0.quality.label.lowercased() },
            sleepHours: sleepHours,
            journalTagLabel: day.journals.last?.tag.label.lowercased()
        )
        let auditKind = payload.payloadKind; let auditFields = payload.includedFieldNames

        var dataParts: [String] = []
        let mealLine = payload.mealNames.joined(separator: ", ")
        let workoutLine = payload.workoutNames.joined(separator: ", ")
        let sleepDesc: String = {
            guard let label = payload.sleepQualityLabel else { return "" }
            let hours = sleepHours.map { String(format: "%.1f", $0) + " hrs" } ?? ""
            return [label, hours].filter { !$0.isEmpty }.joined(separator: " ")
        }()
        if !mealLine.isEmpty { dataParts.append("meals: \(mealLine)") }
        if !workoutLine.isEmpty { dataParts.append("workouts: \(workoutLine)") }
        if !sleepDesc.isEmpty { dataParts.append("sleep: \(sleepDesc)") }
        if let tag = payload.journalTagLabel, !tag.isEmpty { dataParts.append("feeling: \(tag)") }
        guard !dataParts.isEmpty else { return nil }
        // Ambient: route + charge one call. A fallback (sleepy/resting/incapable) leaves the slot empty.
        guard let destination = gate.dispatch(tier: .standard, userInvoked: false) else { return nil }

        let prompt = """
        Write a brief day summary (under 50 words) for a wellness app called Fernlet.
        Data: \(dataParts.joined(separator: "; ")).
        Tone: warm, calm, non-judgmental. A single short paragraph. No lists. No advice. Just warm observation.
        """
        do {
            let session = LanguageModelSession(
                instructions: "You write brief warm wellness day summaries for a companion app called Fernlet. Under 50 words. No advice. No lists. Warm observation only."
            )
            let response = try await session.respond(to: prompt)
            let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            await AIAuditLog.shared.record(
                payloadKind: auditKind,
                destination: destination,
                modelIdentifier: AIAuditEntry.onDeviceFoundationModel,
                includedFields: auditFields,
                outcome: text.isEmpty ? .fellBack : .succeeded
            )
            return text.isEmpty ? nil : text
        } catch {
            await AIAuditLog.shared.record(
                payloadKind: auditKind,
                destination: destination,
                modelIdentifier: AIAuditEntry.onDeviceFoundationModel,
                includedFields: auditFields,
                outcome: AIAuditOutcome.fromModelError(error)
            )
            return nil
        }
    }

    @available(iOS 26.0, *)
    private func foundationModelsThought(for store: FernletStore) async -> String? {
        let signals = store.derivedSignals.filter { $0.value != "insufficient data" }
        guard !signals.isEmpty else { return nil }

        let signalSummaries = signals.prefix(3).map { AISignalSummary(signalName: $0.signalName, value: $0.value) }
        let journalTag = store.day.journals.last?.tag.label.lowercased() ?? ""
        let filteredMemory = MemoryAgent.filteredContext(
            from: store.tierTwoMemories,
            destinedFor: "companion-thought",
            maxChars: 400
        )
        let payload = CompanionThoughtPayload(
            signalSummaries: Array(signalSummaries),
            journalTagLabel: journalTag.isEmpty ? nil : journalTag,
            filteredMemorySummary: filteredMemory
        )
        let auditKind = payload.payloadKind; let auditFields = payload.includedFieldNames
        let auditMemoryChars = filteredMemory.count

        // Thought bubble is an AMBIENT, memory-adjacent `light` task (journal/memory context stays
        // on-device — `light` never escalates) → `userInvoked: false`. In the sleepy band it takes the
        // deterministic thought path.
        guard let destination = store.aiGate.dispatch(tier: .light, userInvoked: false) else { return nil }

        let signalLine = signalSummaries.map { "\($0.signalName): \($0.value)" }.joined(separator: ", ")
        var contextParts = [signalLine]
        if let tag = payload.journalTagLabel { contextParts.append("today feeling: \(tag)") }
        if !payload.filteredMemorySummary.isEmpty { contextParts.append("user pattern: \(payload.filteredMemorySummary)") }

        let prompt = """
        Write one brief gentle observation (under 20 words) for a wellness companion called Fernlet.
        Context: \(contextParts.joined(separator: "; ")).
        Write only the observation — no quotes, no attribution. Warm and honest.
        """
        do {
            let session = LanguageModelSession(
                instructions: "You write one-sentence gentle observations for a wellness companion called Fernlet. Under 20 words. No advice. Just warm noticing. You have honest behavioral context about the user — use it to write something that resonates, not something generic."
            )
            let response = try await session.respond(to: prompt)
            let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            await AIAuditLog.shared.record(
                payloadKind: auditKind,
                destination: destination,
                modelIdentifier: AIAuditEntry.onDeviceFoundationModel,
                includedFields: auditFields,
                memorySummaryCharCount: auditMemoryChars,
                outcome: text.isEmpty ? .fellBack : .succeeded
            )
            return text.isEmpty ? nil : text
        } catch {
            await AIAuditLog.shared.record(
                payloadKind: auditKind,
                destination: destination,
                modelIdentifier: AIAuditEntry.onDeviceFoundationModel,
                includedFields: auditFields,
                memorySummaryCharCount: auditMemoryChars,
                outcome: AIAuditOutcome.fromModelError(error)
            )
            return nil
        }
    }
    #endif
}
