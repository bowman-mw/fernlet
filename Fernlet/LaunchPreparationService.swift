import Foundation
import Observation

#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Photowall seed

struct PhotowallSeed: Identifiable {
    let id = UUID()
    let caption: String
    let rotation: Double
    let colorIndex: Int  // 0–3, mapped to themed colors in the view
}

// MARK: - Launch preparation service

@MainActor
@Observable
final class LaunchPreparationService {
    private(set) var isDone = false
    private(set) var statusMessage = initialStatusMessage

    static let initialStatusMessage = "Checking in with your body..."

    func prepare(store: FernletStore) async {
        guard !isDone else { return }

        let startedAt = Date()
        statusMessage = Self.initialStatusMessage
        await Task.yield()

        // Keep launch work deterministic and cheap so the first screen can animate.
        store.photowallSeeds = buildPhotowallSeeds(store: store)
        statusMessage = "Reading your recent patterns..."
        if let summary = deterministicDaySummaryForYesterday(store: store) {
            store.storeDaySummary(summary, for: yesterdayKey())
        }
        store.storeCompanionThought(deterministicThought(for: store))
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

        let rotations: [Double] = [-3, 2, -1, 3]
        return (0..<4).map { i in
            PhotowallSeed(
                caption: i < captions.count ? captions[i] : defaults[i % defaults.count],
                rotation: rotations[i],
                colorIndex: i
            )
        }
    }

    // MARK: - Day summary

    private func generateDaySummary(for store: FernletStore) async -> String? {
        let key = yesterdayKey()
        let targetDay = store.loadDay(for: key)

        guard !targetDay.meals.isEmpty || !targetDay.workouts.isEmpty else { return nil }

        // Skip if a summary already exists for yesterday.
        if let existing = store.dailyScores.first(where: { $0.dateKey == key })?.daySummaryText,
           !existing.isEmpty { return nil }

        return await makeDaySummaryText(for: targetDay, store: store)
    }

    private func makeDaySummaryText(for day: FernletDay, store: FernletStore) async -> String? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), isFoundationModelAvailable {
            if let text = await foundationModelsDaySummary(for: day) { return text }
        }
        #endif
        return deterministicDaySummary(for: day)
    }

    private func deterministicDaySummary(for day: FernletDay) -> String {
        var parts: [String] = []
        if !day.meals.isEmpty { parts.append("\(day.meals.count) meal\(day.meals.count == 1 ? "" : "s")") }
        if !day.workouts.isEmpty { parts.append(day.workouts.count == 1 ? "a workout" : "\(day.workouts.count) workouts") }
        if let sleep = day.sleep {
            let hours = sleep.hours.map { String(format: "%.1f", $0) + " hours" } ?? ""
            parts.append([sleep.quality.label.lowercased(), hours].filter { !$0.isEmpty }.joined(separator: " ") + " sleep")
        }
        if day.bottleCount > 0 { parts.append("\(day.bottleCount) bottle\(day.bottleCount == 1 ? "" : "s") of water") }
        if let tag = day.journals.last?.tag { parts.append("feeling \(tag.label.lowercased())") }
        guard !parts.isEmpty else { return "" }
        return parts.joined(separator: ", ").capitalized + "."
    }

    private func deterministicDaySummaryForYesterday(store: FernletStore) -> String? {
        let key = yesterdayKey()
        let targetDay = store.loadDay(for: key)

        guard !targetDay.meals.isEmpty || !targetDay.workouts.isEmpty else { return nil }
        if let existing = store.dailyScores.first(where: { $0.dateKey == key })?.daySummaryText,
           !existing.isEmpty { return nil }

        return deterministicDaySummary(for: targetDay)
    }

    // MARK: - Companion thought

    private func generateCompanionThought(for store: FernletStore) async -> String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), isFoundationModelAvailable {
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

    private func yesterdayKey() -> String {
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
        return FernletDate.dayKey(for: yesterday)
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    private func foundationModelsDaySummary(for day: FernletDay) async -> String? {
        let mealNames = day.meals.prefix(5).map(\.name).joined(separator: ", ")
        let workoutNames = day.workouts.prefix(3).map(\.name).joined(separator: ", ")
        let sleepDesc: String
        if let sleep = day.sleep {
            let hours = sleep.hours.map { String(format: "%.1f", $0) + " hrs" } ?? ""
            sleepDesc = [sleep.quality.label.lowercased(), hours].filter { !$0.isEmpty }.joined(separator: " ")
        } else {
            sleepDesc = ""
        }
        let journalTag = day.journals.last?.tag.label.lowercased() ?? ""

        var dataParts: [String] = []
        if !mealNames.isEmpty { dataParts.append("meals: \(mealNames)") }
        if !workoutNames.isEmpty { dataParts.append("workouts: \(workoutNames)") }
        if !sleepDesc.isEmpty { dataParts.append("sleep: \(sleepDesc)") }
        if !journalTag.isEmpty { dataParts.append("feeling: \(journalTag)") }
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

        let signalSummary = signals.prefix(3)
            .map { "\($0.signalName): \($0.value)" }
            .joined(separator: ", ")
        let journalTag = store.day.journals.last?.tag.label.lowercased() ?? ""

        let tierTwoContext = store.tierTwoContextSummary(maxChars: 400)

        var contextParts = [signalSummary]
        if !journalTag.isEmpty { contextParts.append("today feeling: \(journalTag)") }
        if !tierTwoContext.isEmpty { contextParts.append("user pattern: \(tierTwoContext)") }

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
