import Foundation
import AIContext
import FernletDomainModel

#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Candidate exercises offered to the adjuster

/// One numbered exercise the adjuster model may pick, pairing a stable prompt number with its
/// catalog `ExerciseTarget`.
///
/// Built by ``WorkoutAdjustmentCandidateBuilder`` and rendered into the prompt via ``promptLine``;
/// the model answers with `candidateNumber` values that are bound back through ``id``, so it can
/// never introduce an exercise outside this pool. Explicitly `nonisolated` — a pure value type in a
/// MainActor-default module.
public nonisolated struct WorkoutAdjustmentCandidate: Identifiable, Equatable {
    /// Stable 1-based number used in the prompt and matched against the model's `candidateNumber`
    /// replies.
    public var id: Int
    /// The catalog exercise this number stands for.
    public var exercise: ExerciseTarget

    public init(id: Int, exercise: ExerciseTarget) {
        self.id = id
        self.exercise = exercise
    }

    /// The single prompt line describing this candidate: number, name, equipment, movement pattern,
    /// and up to two primary muscles.
    ///
    /// **Prompt vocabulary, not UI copy — every descriptive term here is a `rawValue`, never a
    /// `displayName`.** `MuscleGroup.displayName` and `Equipment.displayName` are display strings
    /// bound for localization; their rawValues (`upperBack`, `dumbbell`, …) are frozen English
    /// tokens. This line must be built from the tokens for two reasons:
    ///
    /// * The model's grounding would otherwise change with the device's language. The prompt would
    ///   describe a "Mancuerna" to a Spanish user and a "Dumbbell" to an English one, on a model
    ///   whose training and whose instruction text are English — a quality regression that produces
    ///   no error, no log, and no test failure, only worse picks on non-English devices.
    /// * Nothing is lost by using tokens. The model never echoes this text back: it answers with a
    ///   `candidateNumber`, bound to ``id``, so the descriptive words only have to disambiguate
    ///   candidates from each other. `upperBack` disambiguates exactly as well as "Upper Back".
    ///
    /// `exercise.name` stays as-is — it is the catalog's own identifier for the movement, already a
    /// stable token, and it is what the human sees in the approve/edit sheet.
    public var promptLine: String {
        let muscles = exercise.primaryMuscles.map(\.rawValue).sorted().prefix(2).joined(separator: "/")
        return "\(id). \(exercise.name) — \(exercise.equipment.rawValue), \(exercise.movementPattern.rawValue)\(muscles.isEmpty ? "" : ", \(muscles)")"
    }
}

/// Builds the equipment- and injury-filtered candidate pool the adjuster may pick from, ranked so
/// the current session's exercises and request-relevant options come first, then capped for the
/// model's context budget.
///
/// The safety property lives here, in code: only exercises `WorkoutSafetyFilter` deems feasible for
/// the user's location and profile ever reach the prompt, so the model cannot select around an
/// injury or missing equipment. The app's workout-adjust flow builds this pool, hands it to
/// ``FoundationWorkoutAdjustmentModel``, and binds the reply back by candidate number.
public enum WorkoutAdjustmentCandidateBuilder {
    /// Ranks the feasible catalog for one adjustment request.
    ///
    /// Scoring favors exercises already in the session (+50), overlapping primary muscles (+8 each),
    /// and name tokens shared with the request (+30); ties break alphabetically for determinism.
    /// - Parameters:
    ///   - currentNames: Exercise names in the session being adjusted.
    ///   - request: The user's natural-language request, tokenized for relevance scoring.
    ///   - location: Where the session happens; drives equipment feasibility.
    ///   - profile: The equipment and injury constraints `WorkoutSafetyFilter` applies.
    ///   - limit: Maximum candidates emitted (the model's context budget). Zero or negative yields
    ///     an empty result rather than trapping.
    ///   - catalog: The exercise universe to draw from.
    /// - Returns: Candidates numbered from 1 in rank order; empty when nothing is feasible.
    public static func candidates(
        currentNames: [String],
        request: String,
        location: WorkoutLocation,
        profile: WorkoutProfile,
        limit: Int = 28,
        catalog: [ExerciseTarget] = WorkoutExerciseCatalog.allExercises
    ) -> [WorkoutAdjustmentCandidate] {
        // R5: `prefix(_:)` traps on a negative length, so validate `limit` at entry rather than at the
        // `prefix` below; "nothing to offer" is already this function's documented empty answer.
        let feasible = WorkoutSafetyFilter.feasibleExercises(in: catalog, location: location, profile: profile)
        guard limit > 0, feasible.isEmpty == false else { return [] }

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

/// On-device AI stage for natural-language workout adjustment — "swap the squat", "I only have 30
/// minutes", "no barbell today" — rebuilding a session from a numbered candidate pool.
///
/// The app's workout-adjust flow calls ``adjust(_:candidates:currentLines:gate:)`` with a
/// de-identified `WorkoutAdjustmentPayload`, the ``WorkoutAdjustmentCandidateBuilder`` pool, and the
/// rendered current-session lines. The model returns candidate numbers with sets/reps; code binds
/// each number back to its real exercise, dedupes by name, clamps sets to 1–6, defaults blank reps,
/// derives the `SlotRole` from the movement pattern, and caps the session at 6 exercises — the
/// model never introduces an exercise, and the injury/equipment filter already ran in code before
/// the prompt was built.
///
/// Dispatch routes through `FernletAIGate` (standard tier, user-invoked) and every call is recorded
/// in `AIAuditLog`; session errors are audited and rethrown. A `nil` result leaves the original
/// session intact. MainActor by the module's default isolation.
public enum FoundationWorkoutAdjustmentModel {
    /// Adjusts a session's exercises to honour a natural-language request, constrained to the
    /// candidate list (equipment- and injury-filtered). Returns nil when the model is unavailable
    /// or produces nothing usable, leaving the original session intact.
    ///
    /// Workout adjustment (`standard` tier, user-invoked). Routes through `gate` at the model-dispatch
    /// point: capability cap + sleepy/resting budget + one-call charge. `nil` (resting / incapable /
    /// off) leaves the original session intact, exactly as the old availability guard did.
    public static func adjust(
        _ payload: WorkoutAdjustmentPayload,
        candidates: [WorkoutAdjustmentCandidate],
        currentLines: [String],
        gate: FernletAIGate
    ) async throws -> [PrescribedExercise]? {
        guard candidates.isEmpty == false else { return nil }

        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            guard let destination = gate.dispatch(tier: .standard, userInvoked: true) else { return nil }
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
                    destination: destination,
                    modelIdentifier: AIAuditEntry.onDeviceFoundationModel,
                    includedFields: auditFields,
                    outcome: resolved == nil ? .fellBack : .succeeded
                )
                return resolved
            } catch {
                await AIAuditLog.shared.record(
                    payloadKind: auditKind,
                    destination: destination,
                    modelIdentifier: AIAuditEntry.onDeviceFoundationModel,
                    includedFields: auditFields,
                    outcome: AIAuditOutcome.fromModelError(error)
                )
                throw error
            }
        }
        #endif
        return nil
    }
}

#if canImport(FoundationModels)
/// The `@Generable` response schema for an adjusted session: the model's ordered exercise picks.
///
/// Guided generation guarantees shape, never validity — ``resolved(candidates:)`` is the binding
/// and sanity pass that stands between the raw response and the `PrescribedExercise` list the
/// caller applies.
@available(iOS 26.0, *)
@Generable
private struct FoundationWorkoutPlan {
    @Guide(description: "The adjusted session: 3 to 6 exercises chosen from the candidate list")
    var exercises: [FoundationWorkoutItem]

    /// Binds the picks to real exercises: unknown candidate numbers and duplicate names are dropped,
    /// sets clamped to 1–6, blank reps defaulted to "8-12", roles derived from movement pattern
    /// (isolation → accessory), and the result capped at 6. Returns `nil` when nothing survives —
    /// the fell-back signal that leaves the original session intact.
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

/// One exercise pick in the model's adjusted session: a candidate number plus the model's sets and
/// reps.
///
/// The number is re-bound to a real ``WorkoutAdjustmentCandidate`` by `FoundationWorkoutPlan.resolved`;
/// a pick whose number matches no candidate is dropped, so the model cannot invent an exercise.
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
