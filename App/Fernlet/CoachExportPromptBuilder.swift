//
//  CoachExportPromptBuilder.swift
//  Fernlet
//
//  Builds the single block of text the manual coach exchange puts on the clipboard: an instruction
//  preamble that states exactly the JSON an assistant must reply with, followed by the user's
//  curated training data.
//
//  WHY THE PROMPT TRAVELS WITH THE DATA. The round trip only closes if what comes back parses —
//  and `CoachPlanImporter` is deliberately strict, because a plan is a set of physical instructions.
//  Shipping the schema next to the data means the schema can never drift from the decoder: both
//  halves live in this repo, and the CoachPlan `CodingKeys` this file describes are the same ones
//  `CoachPlan` decodes. Change one, change the other in the same commit.
//
//  PRIVACY. This produces PLAINTEXT on the clipboard, destined for whatever app the user pastes
//  into. That is the whole point of the feature and it is the user's choice, but it is a genuine
//  departure from Fernlet's on-device default — so the export screen says so plainly before the
//  copy happens. Nothing here makes a network call; the no-tracking wall is untouched.
//
//  NO EXERCISE CATALOG IS SENT. Fernlet's 90-exercise catalog is deliberately NOT included: the
//  assistant names exercises freely and defines any Fernlet doesn't know. What IS included is the
//  ENUM VOCABULARY (muscles, equipment, movement patterns) — those are Fernlet's own tokens, and a
//  definition that misses them can't be checked by `WorkoutSafetyFilter`, so the import rejects it.
//

import Foundation
import FernletDomainModel

/// Assembles the clipboard text for the manual coach handoff.
///
/// Pure and store-free — it takes already-encoded bundle JSON — so the prompt can be tested against
/// a fixture without standing up a ``FernletStore``.
enum CoachExportPromptBuilder {

    /// The full clipboard payload: instructions, schema, vocabulary, then the data.
    ///
    /// - Parameters:
    ///   - bundleJSON: the encoded ``TrainerExportBundle``, pretty-printed.
    ///   - dayCount: how many days of training the bundle covers, for the summary line.
    static func clipboardText(bundleJSON: String, dayCount: Int) -> String {
        """
        \(instructions)

        \(schemaSection)

        \(vocabularySection)

        ---

        MY TRAINING DATA (\(dayCount) day\(dayCount == 1 ? "" : "s")):

        ```json
        \(bundleJSON)
        ```
        """
    }

    // MARK: - Sections

    /// What the assistant is being asked to do, and the rules the plan has to satisfy.
    ///
    /// Rule 6 is the load-bearing one for the round trip: asking for a definition with EVERY
    /// exercise (rather than only unfamiliar ones) is what makes the import reliable. Fernlet drops
    /// definitions for exercises it already knows, so a redundant definition costs nothing, while a
    /// missing one blocks the whole import.
    private static let instructions: String =
        """
        You are helping me program my own training. Below is my recent training data from Fernlet, \
        a privacy-first health app. Read it, then reply with ONE JSON code block and nothing else — \
        no explanation before or after it. I paste your reply straight back into the app.

        Rules for the plan:

        1. SAFETY FIRST. Do not prescribe anything that works a muscle in `profile.avoidedMuscles` \
        or uses a movement in `profile.avoidedMovements`, and respect `profile.injuryNotes`. If \
        that makes part of the plan impossible, prescribe less rather than working around the limit.
        2. Only use equipment listed in `trainingSetup.ownedEquipment`. Bodyweight is always available.
        3. Aim for about `trainingSetup.trainingDaysPerWeek` training days; use rest days for the rest.
        4. Use `exerciseHistory` to pick starting loads and sensible progression — `lastWeight`, \
        `bestWeight`, and `estimatedOneRepMax` are in the unit shown by `weightUnit`. Put load and \
        tempo advice in each exercise's `guidance` field, not in the exercise name.
        5. The plan must be between 1 and 30 days. Number days from 1.
        6. Include an entry in `newExercises` for EVERY exercise you prescribe. Fernlet ignores \
        definitions for exercises it already knows, so redundant ones are harmless — but an \
        exercise with no definition that Fernlet doesn't recognise blocks the whole import.
        7. Use only the exact token values listed under VOCABULARY for muscles, equipment, and \
        movement patterns. Anything else is rejected.
        8. CHANGING WHAT I ALREADY HAVE. Days I've already planned appear under \
        `plannedWorkouts` in my data, each with an `id`. To change one of those rather than add a \
        new workout, put an entry in `edits` with that exact `id` — don't invent ids, and don't \
        repeat a workout in `days` that you're also editing. Use `days` for genuinely new workouts \
        and `edits` for ones already on my calendar. An `edits`-only reply is fine if all I need is \
        my existing plan adjusted.
        """

    /// The exact JSON shape to reply with, mirroring ``CoachPlan``'s coding keys.
    ///
    /// Assembled from two data-shaped constants (R4: a schema example is data, not a function body).
    private static let schemaSection: String =
        """
        REPLY WITH EXACTLY THIS SHAPE:

        \(schemaExampleJSON)

        \(schemaFieldNotes)
        """

    /// The fenced JSON example itself — every key here is a ``CoachPlan`` coding key.
    private static let schemaExampleJSON: String =
        """
        ```json
        {
          "format": "\(CoachPlan.formatTag)",
          "schemaVersion": \(CoachPlan.currentSchemaVersion),
          "title": "short plan name",
          "coachDisplayName": "your name",
          "notes": "optional overview of the block",
          "startPolicy": { "kind": "onAccept" },
          "days": [
            {
              "dayIndex": 1,
              "title": "Push",
              "isRestDay": false,
              "sessions": [
                {
                  "title": "Push",
                  "kind": "strength",
                  "notes": "optional session note",
                  "conditioning": "optional free-text for cardio/mobility sessions",
                  "exercises": [
                    {
                      "name": "Incline dumbbell press",
                      "sets": 3,
                      "reps": "8-10",
                      "restSeconds": 120,
                      "guidance": "RPE 7, 2s lowering"
                    }
                  ]
                }
              ]
            },
            { "dayIndex": 2, "title": "Rest", "isRestDay": true, "sessions": [] }
          ],
          "edits": [
            {
              "targetID": "copy an id from plannedWorkouts in my data, exactly",
              "action": "adjust",
              "title": "optional new name",
              "notes": "optional new note",
              "exercises": [
                { "name": "Incline dumbbell press", "sets": 4, "reps": "6-8", "restSeconds": 150,
                  "guidance": "add 5lb" }
              ]
            }
          ],
          "newExercises": [
            {
              "name": "Incline dumbbell press",
              "primaryMuscles": ["chest", "frontDelts"],
              "secondaryMuscles": ["triceps"],
              "equipment": "dumbbell",
              "movementPattern": "push",
              "inputKind": "strength"
            }
          ]
        }
        ```
        """

    /// The prose that qualifies the schema: optional fields, the `edits` actions, and the maximums.
    private static let schemaFieldNotes: String =
        """
        Notes on the fields: `reps` is text, so "8-10", "AMRAP", or "30s each side" are all fine. \
        `restSeconds` is optional — leave it out and Fernlet uses its own rest guidance. A rest day \
        has `isRestDay: true` and no sessions.

        In `edits`, `action` is one of \
        \(CoachPlanEditAction.allCases.map(\.rawValue).joined(separator: ", ")). `adjust` keeps every \
        field you leave out — send only `exercises` to change the prescription and keep the name and \
        notes. `replace` must list the full new `exercises`. `delete` needs only `targetID` and \
        removes that planned workout. Fernlet only changes workouts still ahead of today, and never \
        touches anything already logged. Omit `edits` entirely if you're not changing existing plans.

        Maximums: \(CoachPlanLimits.maxDays) days, \(CoachPlanLimits.maxEdits) edits, \
        \(CoachPlanLimits.maxSessionsPerDay) sessions per day, \
        \(CoachPlanLimits.maxExercisesPerSession) exercises per session, \
        \(CoachPlanLimits.maxSets) sets per exercise.
        """

    /// The enum tokens a definition must use, quoted from the domain model itself so the prompt can
    /// never drift from what ``CoachPlanTokens`` will accept.
    private static let vocabularySection: String =
        """
        VOCABULARY — use these exact values:

        primaryMuscles / secondaryMuscles: \(CoachPlanTokens.muscleVocabulary)
        equipment: \(CoachPlanTokens.equipmentVocabulary)
        movementPattern: \(CoachPlanTokens.movementVocabulary)
        session kind: \(CoachPlanTokens.sessionKindVocabulary)
        inputKind: strength, treadmill, none
        """
}

// MARK: - Store seam

extension FernletStore {

    /// Builds the clipboard text for the manual coach handoff: the curated export narrowed to the
    /// ``TrainerExportWindow/coachHandoff`` window, wrapped in the instruction preamble.
    ///
    /// Returns nil only if the bundle can't be encoded, which the caller surfaces as an error rather
    /// than silently copying nothing.
    func coachHandoffClipboardText(options: TrainerExportOptions) -> String? {
        let bundle = buildTrainerExport(options: options, window: .coachHandoff)
        guard let data = encodeTrainerExport(bundle),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return CoachExportPromptBuilder.clipboardText(bundleJSON: json, dayCount: bundle.days.count)
    }
}
