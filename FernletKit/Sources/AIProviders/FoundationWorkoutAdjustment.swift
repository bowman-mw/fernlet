import Foundation
import AIContext
import FernletDomainModel

#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Candidate exercises offered to the adjuster

public nonisolated struct WorkoutAdjustmentCandidate: Identifiable, Equatable {
    public var id: Int
    public var exercise: ExerciseTarget

    public init(id: Int, exercise: ExerciseTarget) {
        self.id = id
        self.exercise = exercise
    }

    public var promptLine: String {
        let muscles = exercise.primaryMuscles.map(\.displayName).sorted().prefix(2).joined(separator: "/")
        return "\(id). \(exercise.name) — \(exercise.equipment.displayName), \(exercise.movementPattern.rawValue)\(muscles.isEmpty ? "" : ", \(muscles)")"
    }
}

/// Builds the equipment- and injury-filtered candidate pool the adjuster may pick from, ranked so
/// the current session's exercises and request-relevant options come first, then capped for the
/// model's context budget.
public enum WorkoutAdjustmentCandidateBuilder {
    public static func candidates(
        currentNames: [String],
        request: String,
        location: WorkoutLocation,
        profile: WorkoutProfile,
        limit: Int = 28,
        catalog: [ExerciseTarget] = WorkoutExerciseCatalog.baseExercises
    ) -> [WorkoutAdjustmentCandidate] {
        let feasible = WorkoutSafetyFilter.feasibleExercises(in: catalog, location: location, profile: profile)
        guard feasible.isEmpty == false else { return [] }

        let byName = Dictionary(catalog.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let currentSet = Set(currentNames)
        let currentMuscles = currentNames.reduce(into: Set<MuscleGroup>()) { result, name in
            if let exercise = byName[name] { result.formUnion(exercise.primaryMuscles) }
        }
        let requestTokens = Set(
            request.lowercased()
                .split { !$0.isLetter }
                .map(String.init)
                .filter { $0.count >= 3 }
        )

        let ranked = feasible
            .map { exercise -> (exercise: ExerciseTarget, score: Int) in
                var score = 0
                if currentSet.contains(exercise.name) { score += 50 }
                score += exercise.primaryMuscles.intersection(currentMuscles).count * 8
                let nameTokens = Set(exercise.name.lowercased().split(separator: " ").map(String.init))
                if nameTokens.isDisjoint(with: requestTokens) == false { score += 30 }
                return (exercise, score)
            }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.exercise.name < rhs.exercise.name
            }
            .prefix(limit)
            .map(\.exercise)

        return ranked.enumerated().map { offset, exercise in
            WorkoutAdjustmentCandidate(id: offset + 1, exercise: exercise)
        }
    }
}

// MARK: - Adjuster model

public enum FoundationWorkoutAdjustmentModel {
    /// Adjusts a session's exercises to honour a natural-language request, constrained to the
    /// candidate list (equipment- and injury-filtered). Returns nil when the model is unavailable
    /// or produces nothing usable, leaving the original session intact.
    public static func adjust(
        _ payload: WorkoutAdjustmentPayload,
        candidates: [WorkoutAdjustmentCandidate],
        currentLines: [String]
    ) async throws -> [PrescribedExercise]? {
        guard candidates.isEmpty == false else { return nil }

        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            guard FoodSelectionAvailability.isFoundationModelAvailable else { return nil }
            let auditKind = payload.payloadKind
            let auditFields = payload.includedFieldNames

            let instructions = """
            You adjust a strength workout to fit a person's request, e.g. "swap the squat", \
            "I only have 30 minutes", "no barbell today", "go easier on my knee".
            Rebuild the session as 3–6 exercises chosen ONLY from the numbered candidate list, using \
            candidateNumber values. Keep what already works; change only what the request asks for. \
            For a shorter session, return fewer exercises. Honour any equipment the person rules out.
            Give realistic sets (2–6) and reps (e.g. "5", "8-12", or "30 sec").
            """
            let prompt = """
            Current session:
            \(currentLines.joined(separator: "\n"))

            Person's request: \(payload.request)

            Candidate exercises:
            \(candidates.map(\.promptLine).joined(separator: "\n"))
            """
            let session = LanguageModelSession(instructions: instructions)
            do {
                let response = try await session.respond(to: prompt, generating: FoundationWorkoutPlan.self)
                let resolved = response.content.resolved(candidates: candidates)
                await AIAuditLog.shared.record(
                    payloadKind: auditKind,
                    destination: .onDeviceFoundationModels,
                    modelIdentifier: AIAuditEntry.onDeviceFoundationModel,
                    includedFields: auditFields,
                    outcome: resolved == nil ? .fellBack : .succeeded
                )
                return resolved
            } catch {
                await AIAuditLog.shared.record(
                    payloadKind: auditKind,
                    destination: .onDeviceFoundationModels,
                    modelIdentifier: AIAuditEntry.onDeviceFoundationModel,
                    includedFields: auditFields,
                    outcome: .schemaFailed
                )
                throw error
            }
        }
        #endif
        return nil
    }
}

#if canImport(FoundationModels)
@available(iOS 26.0, *)
@Generable
private struct FoundationWorkoutPlan {
    @Guide(description: "The adjusted session: 3 to 6 exercises chosen from the candidate list")
    var exercises: [FoundationWorkoutItem]

    func resolved(candidates: [WorkoutAdjustmentCandidate]) -> [PrescribedExercise]? {
        var seenNames = Set<String>()
        let resolved = exercises.compactMap { item -> PrescribedExercise? in
            guard let candidate = candidates.first(where: { $0.id == item.candidateNumber }) else { return nil }
            let name = candidate.exercise.name
            guard seenNames.contains(name) == false else { return nil }
            seenNames.insert(name)
            let sets = min(max(item.sets, 1), 6)
            let trimmedReps = item.reps.trimmingCharacters(in: .whitespacesAndNewlines)
            let reps = trimmedReps.isEmpty ? "8-12" : trimmedReps
            let role: SlotRole = candidate.exercise.movementPattern == .isolation ? .accessory : .main
            return PrescribedExercise(name: name, sets: sets, reps: reps, role: role, fromCatalog: true)
        }
        let limited = Array(resolved.prefix(6))
        return limited.isEmpty ? nil : limited
    }
}

@available(iOS 26.0, *)
@Generable
private struct FoundationWorkoutItem {
    @Guide(description: "Number from the candidate list")
    var candidateNumber: Int
    @Guide(description: "Number of sets, 2 to 6")
    var sets: Int
    @Guide(description: "Reps for one set, e.g. '5', '8-12', or '30 sec'")
    var reps: String
}
#endif
