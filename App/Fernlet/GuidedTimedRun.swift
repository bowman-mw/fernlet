//
//  GuidedTimedRun.swift
//  Fernlet
//
//  Guided timed cardio and mobility (comparison report idea 4, roadmap step 4a, 2026-10-20).
//
//  A plan's cardio and mobility lines ("Intervals - 8 × 1 min hard / 1 min easy", "Easy cardio -
//  20 min", "Mobility flow - 15 min", the rest day's gentle stretching) used to be text the runner
//  could not start. `WorkoutTimedSessions` (FernletDomainModel) now turns them into timed steps when a
//  run starts; this file is the app's half: the crossings between the domain's segments and the
//  app-group run state, what a finished timed run logs (its activity type and the time actually held),
//  and the words the runner draws and speaks for a segment. The heart-rate zone cue (step 4b) is
//  `GuidedZones.swift`.
//

import SwiftUI
import FernletDomainModel

/// The crossings between the domain's cardio segments and the guided run's app-group state, and what a
/// finished timed run logs.
///
/// The run state cannot import the domain, so a segment crosses as tokens (`GuidedWorkoutRunState
/// .Segment`) and comes back as a `CardioSegment` for the plan-text layout and a resumed session.
enum GuidedRunTimedLog {

    /// A plan step's segment as the run stores it, or nil for any other step.
    static func runSegment(_ segment: CardioSegment?) -> GuidedWorkoutRunState.Segment? {
        guard let segment else { return nil }
        return GuidedWorkoutRunState.Segment(
            paceRaw: segment.pace.rawValue, round: segment.round, rounds: segment.rounds, descriptor: segment.descriptor
        )
    }

    /// A run step's segment back as the domain's, or nil for any other step. An unknown pace token (a
    /// newer build's) reads as steady, which only ever changes a word on screen.
    static func cardioSegment(of exercise: GuidedWorkoutRunState.Exercise) -> CardioSegment? {
        guard let segment = exercise.segment else { return nil }
        return CardioSegment(
            pace: CardioPace(rawValue: segment.paceRaw) ?? .steady, seconds: exercise.holdSeconds ?? 0,
            round: segment.round, rounds: segment.rounds, descriptor: segment.descriptor,
            followsOn: exercise.leadInSeconds == 0
        )
    }

    /// The activity a finished cardio, mobility or sport run logs as, so Apple Health files it as what it
    /// was rather than "Other": its cardio line's type (HIIT for intervals, walking for a walk, mixed
    /// cardio otherwise), flexibility for a stretch session, and for a sport session the sport named in
    /// Workout setup (`sport`, ``WorkoutSportActivity``) when Fernlet models it — pickleball, tennis,
    /// volleyball and so on, with bare "football" read by `region` (round 2, R5). Nil for every other
    /// run, and for a sport session whose sport matches none or is a distance sport: it keeps the
    /// generic type it always had.
    static func activityType(
        for state: GuidedWorkoutRunState, sport: String? = nil, region: String? = nil
    ) -> WorkoutActivityType? {
        switch SessionKind(rawValue: state.sessionKindRaw) {
        case .cardio:
            let line = state.exercises.first(where: { $0.segment != nil })?.segment?.descriptor
            return line.flatMap(WorkoutTimedSessions.activityType(forDescriptor:)) ?? .mixedCardio
        case .mobility:
            return .flexibility
        case .sport:
            return sport.flatMap { WorkoutSportActivity.activityType(forSport: $0, region: region) }
        default:
            return nil
        }
    }

    /// The minutes a finished cardio or mobility run logs: the time its segments and stretches were
    /// actually held (`GuidedWorkoutRunState.Exercise.heldSeconds`) — not the lead-ins, and not the
    /// time the run waited while Fernlet was away — rounded to the nearest minute, at least one. Nil for
    /// every other run and for a timed run with nothing held.
    ///
    /// MERGE NOTE (2026-10-20): the History lane's idea 14 logs every guided run's wall-clock length
    /// from the run's own start and finish. This is the one place a timed run's held time is computed;
    /// at merge, keep it for cardio and mobility runs ahead of the wall clock, or drop it.
    static func heldMinutes(for state: GuidedWorkoutRunState) -> Int? {
        let kind = SessionKind(rawValue: state.sessionKindRaw)
        guard kind == .cardio || kind == .mobility else { return nil }
        let seconds = state.exercises.reduce(0) { $0 + max(0, $1.heldSeconds ?? 0) }
        guard seconds > 0 else { return nil }
        return max(1, Int((Double(seconds) / 60).rounded()))
    }
}

/// The words the runner draws and speaks for a timed cardio segment: its pace, its round, what VoiceOver
/// says as it changes, and the line under the card.
///
/// The pace is always a WORD — never colour alone (Differentiate Without Color) — and the pace tokens are
/// `GuidedWorkoutRunState.PaceToken`'s; an unknown token reads as steady. Pace words are keyed
/// (`workout.pace.*`) so a translator can tell an interval's "Easy" from the effort chip's.
enum GuidedSegmentWords {

    /// The pace word: "Hard", "Easy" or "Steady".
    nonisolated static func paceWord(_ paceRaw: String) -> String {
        switch paceRaw {
        case GuidedWorkoutRunState.PaceToken.hard:
            String(localized: "workout.pace.hard", defaultValue: "Hard",
                   comment: "Guided cardio: the pace of an interval's work part, shown over its countdown. Hard for this person, not all-out.")
        case GuidedWorkoutRunState.PaceToken.easy:
            String(localized: "workout.pace.easy", defaultValue: "Easy",
                   comment: "Guided cardio: the pace of an interval's recovery part or an easy steady session, shown over its countdown.")
        default:
            String(localized: "workout.pace.steady", defaultValue: "Steady",
                   comment: "Guided cardio: the pace of a steady-state session, shown over its countdown.")
        }
    }

    /// The countdown's caption once the segment's time runs.
    static func caption(_ paceRaw: String) -> Text {
        Text(verbatim: paceWord(paceRaw))
    }

    /// A segment's length as a clock ("1:00", "20:00") for the up-next list.
    nonisolated static func clock(seconds: Int) -> String {
        Duration.seconds(max(0, seconds)).formatted(.time(pattern: .minuteSecond))
    }

    /// An up-next row's spoken and listed name: the pace and length for a segment ("Easy 1:00"), the
    /// exercise's name otherwise.
    nonisolated static func upNextName(_ exercise: GuidedWorkoutRunState.Exercise) -> String {
        // The stored fields, not `displayedName` (a main-actor computed property in the app target).
        guard let segment = exercise.segment else { return exercise.displayName ?? exercise.name }
        return "\(paceWord(segment.paceRaw)) \(clock(seconds: exercise.holdSeconds ?? 0))"
    }

    /// What VoiceOver says as the run moves onto a segment: its pace, how long, and its round.
    static func changeLine(_ segment: GuidedWorkoutRunState.Segment, seconds: Int) -> LocalizedStringResource {
        let length = Duration.seconds(max(0, seconds)).formatted(.units(allowed: [.minutes, .seconds], width: .wide))
        if let round = segment.round, let rounds = segment.rounds {
            switch segment.paceRaw {
            case GuidedWorkoutRunState.PaceToken.hard: return "Hard for \(length). Round \(round) of \(rounds)."
            case GuidedWorkoutRunState.PaceToken.easy: return "Easy for \(length). Round \(round) of \(rounds)."
            default: return "Round \(round) of \(rounds), \(length)."
            }
        }
        switch segment.paceRaw {
        case GuidedWorkoutRunState.PaceToken.hard: return "Hard pace for \(length)."
        case GuidedWorkoutRunState.PaceToken.easy: return "Easy pace for \(length)."
        default: return "Steady pace for \(length)."
        }
    }

    /// What VoiceOver says when a segment's "Get ready" lead-in ends and its time starts — the segment's
    /// form of "Hold now."
    static func goLine(_ paceRaw: String) -> LocalizedStringResource {
        switch paceRaw {
        case GuidedWorkoutRunState.PaceToken.hard: "Go — hard."
        case GuidedWorkoutRunState.PaceToken.easy: "Go — easy."
        default: "Go — steady."
        }
    }

    /// The gentle line under the card for a segment, or for an untimed cardio step (nil).
    static func encouragement(_ paceRaw: String?) -> Text {
        guard let paceRaw else { return Text("No rush getting started.") }
        switch paceRaw {
        case GuidedWorkoutRunState.PaceToken.hard: return Text("Hard for you, not all-out.")
        case GuidedWorkoutRunState.PaceToken.easy: return Text("Ease right off and get your breath back.")
        default: return Text("A pace you could still talk at.")
        }
    }
}

/// What the runner's Ready screen says it will do, by what the session holds: sets with rests, timed
/// cardio, a stretch session, or the rest day's optional gentle stretch.
enum GuidedReadyIntro {

    /// The intro line for `session`. `address` is the user's term of address: the rest day's gentle
    /// stretch names positions the user takes (*acostada*, *sentada*), which Spanish agrees with them.
    static func text(for session: WorkoutProgram.SessionSuggestion, addressing address: TermOfAddress) -> Text {
        if session.exercises.contains(where: { $0.fromCatalog && $0.sets >= 1 }) {
            return Text("We'll walk through it together — one set at a time, with a gentle rest timer between. Go at a pace that feels good.")
        }
        let line = session.exercises.first(where: WorkoutTimedSessions.isDescriptor)
        switch line.flatMap({ WorkoutTimedSessions.classify($0.name) }) {
        case .steady, .intervals:
            return Text("I'll time each part and tell you when it changes. Go at a pace that feels good — you can stop whenever you like.")
        case .mobilityFlow:
            return Text("I'll time each stretch and move you on by myself. Ease in, and never bounce or push into pain.")
        case .gentleStretch:
            return Text(AddressedCopy.attributed("Just a few easy stretches, kneeling, lying and sitting. Stop whenever you've had enough — resting counts just as much today.", addressing: address))
        case nil:
            return Text("We'll walk through it together. Go at a pace that feels good.")
        }
    }
}

/// The runner's quiet "skip this block" secondary: its words and identifier for the block it is in.
///
/// "Skip warm-up" moves on to the activation work; "Skip cardio" hands a lifting session's cardio over
/// to the cool-down; "Finish early" ends a cardio or stretch session that has nothing after it, logging
/// the time actually held; "Skip cool-down" finishes and logs. Each drawn label is also its spoken and
/// Voice Control name.
struct GuidedBlockSkip {
    /// The drawn label.
    let label: Text
    /// The button's identifier (UI tests and the VoiceOver walk find it by this).
    let identifier: String

    /// The skip for the block `run` is in.
    init(run: GuidedWorkoutRunState) {
        switch run.currentBlock {
        case GuidedWorkoutRunState.BlockToken.warmUp:
            label = Text("Skip warm-up")
            identifier = "workout.guided.skipWarmUp"
        case GuidedWorkoutRunState.BlockToken.cardio where run.hasStepAfterCurrentBlock:
            label = Text("Skip cardio")
            identifier = "workout.guided.skipCardio"
        case GuidedWorkoutRunState.BlockToken.cardio, GuidedWorkoutRunState.BlockToken.mobility:
            label = Text("Finish early")
            identifier = "workout.guided.finishEarly"
        default:
            label = Text("Skip cool-down")
            identifier = "workout.guided.skipCoolDown"
        }
    }
}
