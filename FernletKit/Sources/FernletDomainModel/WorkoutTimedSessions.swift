import Foundation

/// The pace of one timed cardio segment.
///
/// FROZEN tokens: they cross into the app-group run state and the Live Activity payload as raw strings
/// (`GuidedWorkoutRunState.PaceToken`, pinned equal by a test), so a renamed case would strand a run in
/// progress. Display words live in the app's and the widget's catalogs, never here.
public nonisolated enum CardioPace: String, Codable, CaseIterable, Sendable {
    /// Steady-state work: one even effort for the whole segment.
    case steady
    /// An interval's work part — hard for this person, not all-out.
    case hard
    /// An interval's recovery part, or an easy steady segment (an easy walk, easy cardio).
    case easy
}

/// One timed part of a guided cardio run: its pace and length, which round it belongs to, the plan line
/// it was read from, and whether it starts straight off the part before it.
///
/// The runner walks these like holds — a countdown each, then on to the next by itself — and a finished
/// run's log folds them back into ``descriptor`` (``WorkoutSessionBlocks/planText(for:loggedLines:)``),
/// so a log reads "Intervals - 8 × 1 min hard / 1 min easy", never sixteen lines.
public nonisolated struct CardioSegment: Sendable, Equatable {
    /// How hard this part is.
    public var pace: CardioPace
    /// How long it lasts.
    public var seconds: Int
    /// The 1-based round of an interval set; nil for a steady segment.
    public var round: Int?
    /// The rounds in the whole interval set; nil for a steady segment.
    public var rounds: Int?
    /// The plan's own line this segment came from ("Intervals - 8 × 1 min hard / 1 min easy").
    public var descriptor: String
    /// True when the segment starts the moment the one before it ends — an interval's easy part, the
    /// next round's hard part — so the runner gives it no "get ready" lead-in.
    public var followsOn: Bool

    /// Creates a segment.
    public init(pace: CardioPace, seconds: Int, round: Int? = nil, rounds: Int? = nil, descriptor: String, followsOn: Bool = false) {
        self.pace = pace
        self.seconds = seconds
        self.round = round
        self.rounds = rounds
        self.descriptor = descriptor
        self.followsOn = followsOn
    }
}

/// What a plan's descriptor line (a cardio or mobility session, a conditioning finisher, the rest day's
/// movement) can be guided as, when the runner can time it at all.
public nonisolated enum TimedDescriptor: Equatable, Sendable {
    /// One steady-state segment ("Easy cardio - 20 min").
    case steady(minutes: Int, pace: CardioPace)
    /// `rounds` × (hard for `workSeconds`, easy for `easySeconds`) ("Intervals - 8 × 1 min hard / 1 min easy").
    case intervals(rounds: Int, workSeconds: Int, easySeconds: Int)
    /// A timed stretch session of about `minutes` ("Mobility flow - 15 min").
    case mobilityFlow(minutes: Int)
    /// The rest day's gentle stretch: short, floor-based, and only ever an optional extra.
    case gentleStretch

    /// Whether the runner offers it as the session itself. False for the rest day's gentle stretch,
    /// which must never become "Start today's workout" on a day the person said they are unwell.
    public var isPrimary: Bool {
        if case .gentleStretch = self { return false }
        return true
    }
}

/// Turns a plan's untimed descriptor lines into steps the guided runner can time: steady and interval
/// cardio as countdown segments, a Mobility day's "Mobility flow - 15 min" as a stretch session in the
/// owner's warm-up order, and the rest day's "Gentle stretching" as a short, optional floor stretch.
///
/// The plan keeps its descriptor lines (the planner's time budget caps them as text, and that text is
/// the source of truth); the runner expands them when a run starts (``expand(_:feasible:)``). Parsing is
/// deliberately strict — a line it cannot read with certainty (sport drills, a mixed "mobility + walk",
/// "3 rounds") stays the untimed step it always was. English plan text only, like the planner's other
/// generated copy. Deterministic: the same line and catalog always build the same steps. No heart rate.
public nonisolated enum WorkoutTimedSessions {

    /// The separators a descriptor puts between its label and its clause — the same three, in the same
    /// order, as ``WorkoutProgram/descriptorMinutes(in:)``.
    static let separators = [" - ", " – ", " — "]
    /// The longest timed line the runner takes on, in minutes.
    public static let maximumMinutes = 180
    /// The most rounds an interval line may ask for.
    public static let maximumRounds = 30
    /// The shortest and longest single interval part, in seconds.
    static let segmentSeconds = 5...1_800
    /// A mobility flow's holds: long enough to ease into, short of the 60 s holds the warm-up avoids.
    public static let mobilityHoldRange = 30...45
    /// The rest day's gentle holds.
    public static let gentleHoldSeconds = 40
    /// The runner's "get into position" lead-in before each stretch — `GuidedWorkoutRunState
    /// .holdLeadInSeconds` in the app, spelled here because the domain cannot see it (pinned equal by
    /// a test). A stretch session's length counts it.
    public static let stretchLeadInSeconds = 5

    /// Words in a label that mark a line the runner should not time (drills, circuits, a mixed session).
    static let untimedWords = ["drill", "circuit", "mobility", "stretch", "yoga", "+", "/", "&"]
    /// Words that name cardio in a line's label — every cardio line the planner writes carries one
    /// ("Easy cardio", "Easy walk", "Conditioning intervals"); a line without one is not timed as cardio.
    static let cardioWords = [
        "cardio", "walk", "run", "jog", "bike", "cycl", "row", "swim", "elliptical", "stair", "hike",
        "interval", "conditioning",
    ]
    /// Words in a steady line's label that make it an easy one.
    static let easyLabelWords = ["easy", "walk", "gentle", "recovery", "zone 2"]
    /// An interval part's first word that marks it hard, or easy.
    static let hardPartWords: Set<String> = ["hard", "fast", "sprint", "on", "work", "push"]
    static let easyPartWords: Set<String> = ["easy", "slow", "recover", "recovery", "rest", "off", "walk", "jog"]

    /// The stretches a mobility flow adds after the owner's flow when the flow alone runs short.
    static let mobilityExtras = ["Figure-four stretch", "Thread the needle", "Supine twist", "Calf stretch", "Doorway chest stretch"]
    /// The rest day's gentle sequence: kneeling, lying and seated stretches only — nothing to balance on
    /// and no deep lunge — from child's pose down to the floor and back up to sitting.
    static let gentleMoves = [
        "Child's pose", "Cat-cow", "Supine twist", "Lying hamstring stretch", "Figure-four stretch",
        "Butterfly stretch", "Cross-body shoulder stretch",
    ]

    // MARK: Reading a descriptor

    /// What `descriptor` can be guided as, or nil to keep it an untimed step.
    public static func classify(_ descriptor: String) -> TimedDescriptor? {
        guard let parts = split(descriptor) else { return nil }
        if let shaped = intervals(in: parts.clause) { return shaped }
        guard let minutes = WorkoutProgram.descriptorMinutes(in: descriptor), minutes <= maximumMinutes else {
            return nil
        }
        let label = parts.label.lowercased()
        if label.hasPrefix("gentle stretching") { return .gentleStretch }
        if label.contains("mobility flow") { return .mobilityFlow(minutes: minutes) }
        if untimedWords.contains(where: { label.contains($0) }) { return nil }
        // Only a line that names cardio is timed as cardio: "Foam roll - 5 min" stays text.
        guard cardioWords.contains(where: { label.contains($0) }) else { return nil }
        // "Conditioning intervals - 12 min" names a length, not a shape: the plan's own interval shape
        // (1 min hard / 1 min easy) fills it.
        if label.contains("interval") {
            return .intervals(rounds: max(1, minutes / 2), workSeconds: 60, easySeconds: 60)
        }
        let easy = easyLabelWords.contains { label.contains($0) }
        return .steady(minutes: minutes, pace: easy ? .easy : .steady)
    }

    /// The label before a descriptor's separator ("Intervals"), or the whole line when it has none.
    public static func label(of descriptor: String) -> String {
        split(descriptor)?.label ?? descriptor
    }

    /// The line's label and clause, split at its first separator; nil when either side is empty.
    static func split(_ descriptor: String) -> (label: String, clause: String)? {
        for separator in separators {
            guard let range = descriptor.range(of: separator) else { continue }
            let label = descriptor[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            let clause = descriptor[range.upperBound...].trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty, !clause.isEmpty else { return nil }
            return (label, clause)
        }
        return nil
    }

    /// An interval clause — "8 × 1 min hard / 1 min easy" (also "x") — or nil. The first part must not
    /// read easy and the second must not read hard; anything else is left untimed rather than guessed.
    static func intervals(in clause: String) -> TimedDescriptor? {
        let parts = clause.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let head = parts[0]
        guard let times = head.firstIndex(where: { $0 == "×" || $0 == "x" || $0 == "X" }),
              let rounds = Int(head[..<times].trimmingCharacters(in: .whitespaces)),
              (1...maximumRounds).contains(rounds),
              let work = timedPart(String(head[head.index(after: times)...])),
              let easy = timedPart(String(parts[1])),
              work.pace != .easy, easy.pace != .hard,
              rounds * (work.seconds + easy.seconds) <= maximumMinutes * 60 else { return nil }
        return .intervals(rounds: rounds, workSeconds: work.seconds, easySeconds: easy.seconds)
    }

    /// One interval part — "1 min hard", "30 s easy", "90s" — as seconds and the pace its word names.
    static func timedPart(_ text: String) -> (seconds: Int, pace: CardioPace?)? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let digits = trimmed.prefix(while: \.isNumber)
        guard let amount = Int(digits), amount > 0 else { return nil }
        let rest = trimmed.dropFirst(digits.count).trimmingCharacters(in: .whitespaces).lowercased()
        let unit = String(rest.prefix(while: \.isLetter))
        let seconds: Int
        switch unit {
        case "min", "mins", "minute", "minutes": seconds = amount * 60
        case "s", "sec", "secs", "second", "seconds": seconds = amount
        default: return nil
        }
        guard segmentSeconds.contains(seconds) else { return nil }
        let word = rest.dropFirst(unit.count).split(separator: " ").first.map(String.init) ?? ""
        if hardPartWords.contains(word) { return (seconds, .hard) }
        if easyPartWords.contains(word) { return (seconds, .easy) }
        return (seconds, nil)
    }

    // MARK: Building the steps

    /// The countdown segments of a timed cardio line, in run order: one for a steady line; hard then
    /// easy for each round of an interval line, every part after the first following straight on.
    public static func segments(for timed: TimedDescriptor, descriptor: String) -> [CardioSegment] {
        switch timed {
        case .steady(let minutes, let pace):
            guard minutes > 0 else { return [] }
            return [CardioSegment(pace: pace, seconds: minutes * 60, descriptor: descriptor)]
        case .intervals(let rounds, let work, let easy):
            guard work > 0, easy > 0 else { return [] }
            let count = min(max(0, rounds), maximumRounds)
            var segments: [CardioSegment] = []
            for index in 0..<count {
                segments.append(CardioSegment(pace: .hard, seconds: work, round: index + 1, rounds: count,
                                              descriptor: descriptor, followsOn: index > 0))
                segments.append(CardioSegment(pace: .easy, seconds: easy, round: index + 1, rounds: count,
                                              descriptor: descriptor, followsOn: true))
            }
            return segments
        case .mobilityFlow, .gentleStretch:
            return []
        }
    }

    /// One runner step for a cardio segment: a one-set timed step in the cardio block, named by its
    /// line's label ("Intervals"), with no rest after it.
    static func segmentStep(label: String, segment: CardioSegment) -> PrescribedExercise {
        PrescribedExercise(
            name: label, sets: 1, reps: PrescribedExercise.holdText(seconds: segment.seconds), role: .accessory,
            fromCatalog: false, restSecondsOverride: 0, block: .cardio, holdSeconds: segment.seconds,
            segment: segment
        )
    }

    /// A Mobility day's stretch session of about `minutes`: the owner's warm-up flow in its own order
    /// with longer holds (30–45 s), one-sided stretches done both sides. When the flow alone cannot fill
    /// the time even at 45 s, the other catalog stretches follow it; when it overruns even at 30 s, each
    /// move is done once and whole moves come off the end, so a left side never goes without its right.
    /// Only stretches in `feasible` (the equipment- and injury-filtered catalog) are used.
    public static func mobilityFlow(minutes: Int, feasible: [ExerciseTarget]) -> [PrescribedExercise] {
        guard minutes > 0 else { return [] }
        let stretches = mobilityRows(feasible)
        let target = min(minutes, maximumMinutes) * 60
        let flow = WorkoutSessionBlocks.warmUpFlow.filter { stretches[$0.name] != nil }
        let shortest = mobilityHoldRange.lowerBound + stretchLeadInSeconds
        let longest = mobilityHoldRange.upperBound + stretchLeadInSeconds
        var steps: [WorkoutSessionBlocks.FlowStep]
        if flow.count * shortest > target {
            steps = wholeMoves(uniqueMoves(flow), fitting: target, perStep: shortest)
        } else {
            steps = flow
            for name in mobilityExtras where steps.count * longest < target {
                guard let stretch = stretches[name] else { continue }
                steps += sides(of: stretch).map { WorkoutSessionBlocks.FlowStep(name: stretch.name, seconds: 0, side: $0) }
            }
        }
        guard !steps.isEmpty else { return [] }
        let hold = holdSeconds(steps: steps.count, target: target)
        return steps.map { WorkoutSessionBlocks.timedStep(name: $0.name, seconds: hold, side: $0.side, block: .mobility) }
    }

    /// The rest day's optional gentle stretch, about eight minutes: ``gentleMoves`` at
    /// ``gentleHoldSeconds`` each, both sides where one-sided, minus anything `feasible` leaves out.
    public static func gentleStretch(feasible: [ExerciseTarget]) -> [PrescribedExercise] {
        let stretches = mobilityRows(feasible)
        var steps: [PrescribedExercise] = []
        for name in gentleMoves {
            guard let stretch = stretches[name] else { continue }
            for side in sides(of: stretch) {
                steps.append(WorkoutSessionBlocks.timedStep(name: stretch.name, seconds: gentleHoldSeconds, side: side, block: .mobility))
            }
        }
        return steps
    }

    /// The feasible stretch rows by name.
    static func mobilityRows(_ feasible: [ExerciseTarget]) -> [String: ExerciseTarget] {
        Dictionary(feasible.filter { $0.modality == .mobility }.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Left then right for a one-sided stretch; one two-sided step otherwise.
    static func sides(of stretch: ExerciseTarget) -> [ExerciseSide?] {
        stretch.unilateral ? ExerciseSide.allCases : [nil]
    }

    /// Each move of the flow once, in the order it first appears, a one-sided move left then right.
    static func uniqueMoves(_ flow: [WorkoutSessionBlocks.FlowStep]) -> [[WorkoutSessionBlocks.FlowStep]] {
        var seen: Set<String> = []
        var moves: [[WorkoutSessionBlocks.FlowStep]] = []
        for step in flow where !seen.contains(step.name) {
            seen.insert(step.name)
            let sided = flow.contains { $0.name == step.name && $0.side != nil }
            let sides: [ExerciseSide?] = sided ? ExerciseSide.allCases : [nil]
            moves.append(sides.map { WorkoutSessionBlocks.FlowStep(name: step.name, seconds: 0, side: $0) })
        }
        return moves
    }

    /// Whole moves from the front while their steps fit `target` at `perStep` seconds each — at least
    /// the first move, so a very short line still guides something.
    static func wholeMoves(_ moves: [[WorkoutSessionBlocks.FlowStep]], fitting target: Int, perStep: Int) -> [WorkoutSessionBlocks.FlowStep] {
        guard let first = moves.first else { return [] }
        var steps = first
        for move in moves.dropFirst() {
            guard (steps.count + move.count) * perStep <= target else { break }
            steps += move
        }
        return steps
    }

    /// The hold that brings `steps` stretches (each with its lead-in) closest to `target`, on a
    /// five-second grid inside ``mobilityHoldRange``.
    static func holdSeconds(steps: Int, target: Int) -> Int {
        guard steps > 0 else { return mobilityHoldRange.lowerBound }
        let raw = Double(target) / Double(steps) - Double(stretchLeadInSeconds)
        let snapped = Int((raw / 5).rounded()) * 5
        return min(max(snapped, mobilityHoldRange.lowerBound), mobilityHoldRange.upperBound)
    }

    // MARK: The run's steps

    /// Whether a plan step is an untimed descriptor line (a cardio or mobility session, a finisher).
    public static func isDescriptor(_ step: PrescribedExercise) -> Bool {
        !step.fromCatalog && step.sets < 1
    }

    /// Whether a plan step is a line the runner can time as the session itself.
    public static func isGuidable(_ step: PrescribedExercise) -> Bool {
        guard isDescriptor(step), let timed = classify(step.name) else { return false }
        return timed.isPrimary
    }

    /// Whether a plan step is the rest day's optional gentle stretch.
    public static func isOptionalStretch(_ step: PrescribedExercise) -> Bool {
        isDescriptor(step) && classify(step.name) == .gentleStretch
    }

    /// Whether expanding `steps` needs the stretch catalog (a mobility flow or the gentle stretch), so
    /// a cardio or lifting run never filters the catalog for nothing.
    public static func needsStretches(_ steps: [PrescribedExercise]) -> Bool {
        steps.contains { step in
            guard isDescriptor(step), let timed = classify(step.name) else { return false }
            switch timed {
            case .mobilityFlow, .gentleStretch: return true
            case .steady, .intervals: return false
            }
        }
    }

    /// The run's steps for a plan: every timed descriptor line replaced by its segments or stretches,
    /// everything else — lifts, holds, a line it cannot time — as it was. Bounded by the plan's steps.
    public static func expand(_ steps: [PrescribedExercise], feasible: [ExerciseTarget]) -> [PrescribedExercise] {
        var expanded: [PrescribedExercise] = []
        for step in steps {
            expanded += expansion(of: step, feasible: feasible) ?? [step]
        }
        return expanded
    }

    /// One descriptor's timed steps, or nil to keep the step — including when the filter left no
    /// stretch to build from.
    static func expansion(of step: PrescribedExercise, feasible: [ExerciseTarget]) -> [PrescribedExercise]? {
        guard isDescriptor(step), let timed = classify(step.name) else { return nil }
        let built: [PrescribedExercise]
        switch timed {
        case .steady, .intervals:
            let title = label(of: step.name)
            built = segments(for: timed, descriptor: step.name).map { segmentStep(label: title, segment: $0) }
        case .mobilityFlow(let minutes):
            built = mobilityFlow(minutes: minutes, feasible: feasible)
        case .gentleStretch:
            built = gentleStretch(feasible: feasible)
        }
        return built.isEmpty ? nil : built
    }

    // MARK: Logging

    /// The activity a timed line logs as — the same types the Log sheet offers, so Apple Health files it
    /// as what it was rather than "Other": interval cardio as HIIT, a steady walk as walking, other
    /// steady cardio as mixed cardio, a stretch session as flexibility. Nil for a line the runner does
    /// not time.
    public static func activityType(forDescriptor descriptor: String) -> WorkoutActivityType? {
        switch classify(descriptor) {
        case .intervals: return .hiit
        case .steady: return label(of: descriptor).lowercased().contains("walk") ? .walking : .mixedCardio
        case .mobilityFlow, .gentleStretch: return .flexibility
        case nil: return nil
        }
    }
}
