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

struct PhotowallSeed: Identifiable {
    let id = UUID()
    let caption: String
    let rotation: Double
    let colorIndex: Int  // 0–3, mapped to themed colors in the view
    let photoID: UUID?
}

struct PhotowallSelectionContext {
    let selectedAt: Date
    let derivedSignals: [DerivedSignalRecord]
    let recentActivityNames: [String]
}

protocol PhotowallPhotoRanking {
    func rankedCandidates(
        from photos: [FriendPhotoPayload],
        context: PhotowallSelectionContext
    ) -> [FriendPhotoPayload]
}

struct RandomPhotowallPhotoRanking: PhotowallPhotoRanking {
    func rankedCandidates(
        from photos: [FriendPhotoPayload],
        context: PhotowallSelectionContext
    ) -> [FriendPhotoPayload] {
        _ = context
        return photos.shuffled()
    }
}

struct PhotowallPhotoSelector {
    private let defaults: UserDefaults
    private let historyKey: String
    private let ranking: any PhotowallPhotoRanking

    init(
        defaults: UserDefaults = .standard,
        historyKey: String = "fernlet.homePhotowall.previousPhotoIDs",
        ranking: any PhotowallPhotoRanking = RandomPhotowallPhotoRanking()
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

@MainActor
@Observable
final class LaunchPreparationService {
    private(set) var isDone = false
    private(set) var statusMessage = initialStatusMessage
    private let photowallPhotoSelector: PhotowallPhotoSelector

    static let initialStatusMessage = "Checking in with your body..."

    init(photowallPhotoSelector: PhotowallPhotoSelector? = nil) {
        self.photowallPhotoSelector = photowallPhotoSelector ?? PhotowallPhotoSelector()
    }

    func prepare(store: FernletStore) async {
        guard !isDone else { return }

        let startedAt = Date()
        statusMessage = Self.initialStatusMessage
        await Task.yield()

        // A guided-workout Live Activity's state lives in a sheet's @State and can't survive a kill —
        // any still on screen from a previous launch is orphaned. End them once at startup.
        WorkoutLiveActivityController.endStaleActivities()

        // A plaintext "export my data" dump is written to tmp/ for the share sheet and purged when the
        // sheet closes — but a kill/crash/jettison mid-share leaves the full decrypted dump on disk. Launch
        // is a point where no share can be in flight, so sweep any survivor here (belt-and-braces with the
        // pre-write sweep in writeDataExportFile()).
        store.purgeDataExports()

        // Keep launch work deterministic and cheap so the first screen can animate.
        store.photowallSeeds = buildPhotowallSeeds(store: store)
        statusMessage = "Reading your recent patterns..."
        await backfillDaySummaries(for: store)
        store.storeCompanionThought(await generateCompanionThought(for: store))
        await store.backfillWorkoutsFromHealthIfNeeded()

        // Cycle status messages while async work runs.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.55))
            guard !isDone else { return }
            statusMessage = "Preparing your day summary..."
            try? await Task.sleep(for: .seconds(0.55))
            guard !isDone else { return }
            statusMessage = "Getting Fernlet ready..."
        }

        // Minimum display time so the status text has time to settle.
        let elapsed = Date().timeIntervalSince(startedAt)
        let minimumSeconds = 1.4
        if elapsed < minimumSeconds {
            try? await Task.sleep(for: .seconds(minimumSeconds - elapsed))
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
                recentActivityNames: store.day.workouts.map(\.name)
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

    /// Generates day summaries for every logged day (except today) that is missing one, most recent
    /// first. Gated to run at most once per calendar day per device (first open after midnight).
    /// When Foundation Models is unavailable the day's slot is intentionally left empty (spec) rather
    /// than filled with deterministic fallback text.
    private func backfillDaySummaries(for store: FernletStore) async {
        let todayKey = store.todayKey
        if UserDefaults.standard.string(forKey: Self.daySummaryRunKeyDefault) == todayKey { return }

        let dayKeys = store.loadDays().keys
            .filter { $0 != todayKey }
            .sorted(by: >)
        for key in dayKeys {
            if let existing = store.dailyScores.first(where: { $0.dateKey == key })?.daySummaryText,
               !existing.isEmpty { continue }
            let day = store.loadDay(for: key)
            guard !day.meals.isEmpty || !day.workouts.isEmpty else { continue }
            if let summary = await makeDaySummaryText(for: day, store: store), !summary.isEmpty {
                store.storeDaySummary(summary, for: key)
            }
            // When the summary is nil, the slot is left empty on purpose (FM unavailable).
        }
        UserDefaults.standard.set(todayKey, forKey: Self.daySummaryRunKeyDefault)
    }

    private func makeDaySummaryText(for day: FernletDay, store: FernletStore) async -> String? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), isFoundationModelAvailable, store.settings.aiStatus != .off {
            return await foundationModelsDaySummary(for: day)
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
    @available(iOS 26.0, *)
    private func foundationModelsDaySummary(for day: FernletDay) async -> String? {
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
        Task { await AIAuditLog.shared.record(payloadKind: auditKind, destination: .onDeviceFoundationModels, includedFields: auditFields) }

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
            return text.isEmpty ? nil : text
        } catch {
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
        Task { await AIAuditLog.shared.record(payloadKind: auditKind, destination: .onDeviceFoundationModels, includedFields: auditFields, memorySummaryCharCount: filteredMemory.count) }

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
            return text.isEmpty ? nil : text
        } catch {
            return nil
        }
    }
    #endif
}
