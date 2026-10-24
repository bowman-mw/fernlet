// LiveActivityDemoHarness.swift
// Fernlet (app target, DEBUG only).
//
// `FERNLET_UI_TEST_LIVE_ACTIVITY=<scene>` puts one canned workout or cooking Live Activity on screen at
// launch, so the World look of the Lock Screen card and the Dynamic Island (World Review Batch 4,
// b4-la-* and b4-di-*) can be screenshotted on the simulator and checked on a device without walking
// a real workout or recipe to the right step. The values are the approved pages' own ("Upper body",
// "Goblet squat", "Chicken rice bowl"); nothing is read from or written to the store, and nothing of
// the person's reaches the activity. Release builds compile `install()` to a no-op.

#if DEBUG
import ActivityKit
import Foundation
#endif

/// DEBUG-only: requests one canned Live Activity named by `FERNLET_UI_TEST_LIVE_ACTIVITY`.
///
/// Scenes: `workout-set`, `workout-rest`, `workout-cardio`, `workout-hold`, `workout-warmup`,
/// `workout-step`, `workout-paused`, `cook-step`, `cook-notimer`, `cook-last`, `cook-paused`, and `both`
/// (a rest and a timed step at once, for the minimal island). A paused scene posts a snapshot that goes
/// stale two seconds later, which is how an orphaned run looks. Every activity of both kinds is ended
/// first, so one launch shows exactly one scene.
@MainActor
enum LiveActivityDemoHarness {
    #if DEBUG
    /// Request the scene the launch environment names, if any. Call once the app is in the foreground
    /// (ActivityKit refuses a request from the background).
    ///
    /// The request waits a few seconds: at launch and on every foreground the store retires any workout
    /// or cooking activity with no run behind it (`reconcileGuidedRunFromAppGroup()`), and a canned
    /// activity has none, so one requested at once is ended a moment later.
    static func install() {
        guard let scene = ProcessInfo.processInfo.environment["FERNLET_UI_TEST_LIVE_ACTIVITY"] else { return }
        Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(settleSeconds))
            } catch {
                return
            }
            requestScene(scene)
        }
    }

    /// Seconds to let the launch reconcile settle before requesting.
    private static let settleSeconds = 5

    /// End every activity of both kinds, then request the scene's.
    private static func requestScene(_ scene: String) {
        for activity in Activity<WorkoutActivityAttributes>.activities {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
        for activity in Activity<CookingActivityAttributes>.activities {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
        let now = Date()
        let stale = scene.hasSuffix("-paused") ? now.addingTimeInterval(2) : nil
        if scene == "both" {
            // A rest and a timed step at once: the island shows one compact and the other minimal.
            request(WorkoutActivityAttributes(workoutTitle: "Upper body"), workoutState("workout-rest", now: now), stale: nil)
            request(CookingActivityAttributes(recipeName: "Chicken rice bowl"), cookingState("cook-step", now: now), stale: nil)
        } else if scene.hasPrefix("cook") {
            request(CookingActivityAttributes(recipeName: "Chicken rice bowl"), cookingState(scene, now: now), stale: stale)
        } else {
            let title = scene == "workout-cardio" ? "Easy run-walk" : (scene == "workout-hold" ? "Stretch" : "Upper body")
            request(WorkoutActivityAttributes(workoutTitle: title), workoutState(scene, now: now), stale: stale)
        }
    }

    /// One request; a refusal is printed, never thrown (the harness is a screenshot aid).
    private static func request<A: ActivityAttributes>(_ attributes: A, _ state: A.ContentState, stale: Date?) {
        do {
            _ = try Activity.request(attributes: attributes, content: ActivityContent(state: state, staleDate: stale))
        } catch {
            print("[live-activity-demo] request refused: \(error)")
        }
    }

    /// The workout scene's snapshot: the approved pages' goblet squat, side plank and run-walk.
    private static func workoutState(_ scene: String, now: Date) -> WorkoutActivityAttributes.ContentState {
        typealias State = WorkoutActivityAttributes.ContentState
        let load = State.Load(weight: 25, suggested: 25, rangeLow: 25, rangeHigh: 30, unitRaw: "lb",
                              lastSets: 3, lastReps: "10", lastWeight: 25, lastUnitRaw: "lb")
        var state = State(exerciseName: "Goblet squat", setNumber: 2, totalSets: 3, reps: "10", phase: .working,
                          restStartedAt: nil, restEndsAt: nil, exerciseIndex: 2, totalExercises: 6, load: load)
        switch scene {
        case "workout-rest":
            state.phase = .resting
            state.setNumber = 3
            state.restStartedAt = now
            state.restEndsAt = now.addingTimeInterval(90)
        case "workout-warmup":
            state.setNumber = 1
            state.warmUpSet = 1
            state.warmUpSets = 3
        case "workout-step":
            state = State(exerciseName: "Brisk walk", setNumber: 1, totalSets: 1, reps: "", phase: .working,
                          restStartedAt: nil, restEndsAt: nil, exerciseIndex: 0, totalExercises: 3)
        case "workout-hold":
            state = State(exerciseName: "Side plank", setNumber: 1, totalSets: 1, reps: "20 s", phase: .working,
                          restStartedAt: nil, restEndsAt: nil, exerciseIndex: 3, totalExercises: 5,
                          holdStartsAt: now.addingTimeInterval(4), holdEndsAt: now.addingTimeInterval(24), sideRaw: "left")
        case "workout-cardio":
            state = cardioState(now: now)
        default:
            break
        }
        return state
    }

    /// A run-walk's easy round with a live heart rate in range.
    private static func cardioState(now: Date) -> WorkoutActivityAttributes.ContentState {
        typealias State = WorkoutActivityAttributes.ContentState
        return State(exerciseName: "Run", setNumber: 1, totalSets: 1, reps: "", phase: .working,
                     restStartedAt: nil, restEndsAt: nil, exerciseIndex: 1, totalExercises: 3,
                     holdStartsAt: now, holdEndsAt: now.addingTimeInterval(180), paceRaw: "easy", round: 2, rounds: 4,
                     zone: State.Zone(target: 2, bpm: 118, low: 110, high: 125))
    }

    /// The cooking scene's snapshot: the approved pages' chicken rice bowl.
    private static func cookingState(_ scene: String, now: Date) -> CookingActivityAttributes.ContentState {
        guard scene != "cook-last" else {
            return CookingActivityAttributes.ContentState(
                stepText: "Slice the chicken and pile everything into bowls.", stepNumber: 8, stepCount: 8,
                isLastStep: true, timerStartedAt: nil, timerEndsAt: nil)
        }
        let timed = scene != "cook-notimer"
        return CookingActivityAttributes.ContentState(
            stepText: "Simmer the rice, covered, until the water is gone.", stepNumber: 3, stepCount: 8,
            isLastStep: false, timerStartedAt: timed ? now : nil, timerEndsAt: timed ? now.addingTimeInterval(765) : nil)
    }
    #else
    /// Release: no hook, nothing to request.
    static func install() {}
    #endif
}
