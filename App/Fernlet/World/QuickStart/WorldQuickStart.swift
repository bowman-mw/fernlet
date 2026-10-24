import Foundation
import WorldMapStore

/// Everything the blue quick-start button needs to know about where the person stands and what they're
/// doing (World app plan step 6b; designs `b1-qs-*`, approved 2026-10-23, and `b3-qs-hike` /
/// `b3-qs-session`, approved 2026-10-24). Plain values, gathered by
/// `FernletStore.worldQuickStartContext(at:includingPlans:)`, so the rules below are tested without a
/// store.
///
/// Nothing here was sent anywhere or asked for: the space match is on this iPhone against the person's
/// own pins (`SpacePinStore`, within 100 m), and it is read only when Home opens or the button is
/// tapped. There are no badges, buzzes or notifications on arrival.
nonisolated struct WorldQuickStartContext: Equatable, Sendable {
    /// A workout space of the person's own whose pin is within 100 m.
    struct Space: Equatable, Sendable {
        let id: UUID
        /// Its name as drawn (``WorkoutLocation/displayedName``).
        let name: String
        /// "Cardio, Free weights, Machines": the categories it has anything in (at most three).
        let equipment: String
        /// How many pieces of equipment it holds.
        let itemCount: Int
    }

    /// A friend session running now.
    struct Session: Equatable, Sendable {
        /// The other people's first names, in roster order.
        let names: [String]
        /// Shots left on the session's shared film.
        let shotsLeft: Int
    }

    /// A walk of the person's own, saved on this iPhone, that started within 100 m of here.
    struct SavedLine: Equatable, Sendable {
        /// Its length, in metres.
        let metres: Double
        /// How many recent walks started here.
        let walks: Int
    }

    /// What the person is doing right now.
    enum Activity: Equatable, Sendable {
        case none
        /// A walk (Walk together, or a saved line again) is recording.
        case walking
        /// A guided workout is under way; its title as drawn.
        case workout(title: String)
    }

    /// Whether Walk together can be offered: location is already allowed, and the walk can be precise
    /// (precise location, or the temporary-accuracy purpose that asks for it for the walk). Nothing on
    /// Home asks for location; the permission screens are their own step.
    var canWalk = false
    /// A decoy (duress) session: only the walk is offered, and a decoy walk leaves nothing behind.
    var isDecoy = false
    /// A resting or unwell day (`needsRestToday`, or today marked unwell).
    var isResting = false
    var space: Space?
    /// A saved walk that starts here (`b1-qs-trail`, as the data allows: a walk line, unnamed).
    var savedLine: SavedLine?
    /// Today's approved plan's next guided session, as drawn, when there is one.
    var plannedSession: String?
    /// Whether today's rest plan still has its optional gentle stretch to do.
    var hasGentleStretch = false
    var session: Session?
    var activity: Activity = .none
    /// Whether the disposable camera has its on-your-own mode (10 a day;
    /// `WorldDisposableCamera.soloIsAvailable`). Without it the camera is offered only in a session.
    var soloCameraAvailable = false
}

/// A saved walk line of the person's own that starts where they stand (`FernletStore.worldSavedLine`):
/// the line to draw while they walk it again, and the facts the card shows.
nonisolated struct WorldSavedLine: Equatable, Sendable {
    /// The walk it was saved with.
    let workoutID: UUID
    /// The line, start to end.
    let points: [GeoPoint]
    /// Its length, in metres.
    let metres: Double
    /// How many recent walks started here.
    let walks: Int

    /// The card's facts.
    var summary: WorldQuickStartContext.SavedLine { WorldQuickStartContext.SavedLine(metres: metres, walks: walks) }
}

/// One choice on the quick-start card. The view draws the words; these are the facts behind them.
nonisolated enum WorldQuickStartOption: Equatable, Hashable, Sendable {
    /// "Today's plan at Full gym": starts today's guided session with that space active.
    case todaysPlan(space: String, session: String)
    /// "Suggest today's workout": Move's suggestion, for that space (gently, on a resting day).
    case suggestWorkout(space: String, equipment: String, gentle: Bool)
    /// Today's rest plan's gentle stretch, guided.
    case gentleStretch
    /// Walk together: the walk bar, the line and a logged walk.
    case walkTogether
    /// Walk a saved line again: Walk together, with that line drawn on the map to follow.
    case walkSavedLine(metres: Double)
    /// The session's disposable camera, on its shared film.
    case sessionCamera(shotsLeft: Int)
    /// The disposable camera on your own (10 a day, the photos appear tonight).
    case soloCamera
    /// Back to the guided workout under way.
    case backToWorkout(title: String)
}

/// The card the blue button opens (the design's `.qs` card): a heading, an optional line, and the
/// choices, the first one leading in teal.
nonisolated struct WorldQuickStartCard: Equatable, Sendable {
    /// The card's heading.
    enum Heading: Equatable, Sendable {
        /// The workout space's name.
        case space(String)
        /// "With Sam and Rae".
        case session([String])
        /// "Go for a walk".
        case walk
        /// "Your walk from here": a saved walk starts where the person stands.
        case savedLine
        /// "A gentle day": resting, away from a space.
        case gentle
        /// "On your walk": while a walk records.
        case walking
        /// The guided workout's title, while it runs.
        case workout(String)
    }

    /// The line under the heading.
    enum Note: Equatable, Sendable {
        /// "Nothing planned yet. Fernlet can put something together from this space's 22 items."
        case nothingPlanned(items: Int)
        /// "Nothing saved here yet. It shows up once you've trained, hiked or eaten here a few times."
        case nothingSaved
        /// "Resting counts today. These are here if you want them." (drawn stronger)
        case restingCounts
        /// "You've walked from here 3 times"
        case walkedFromHere(times: Int)
    }

    let heading: Heading
    let note: Note?
    let options: [WorldQuickStartOption]
}

/// The blue button's icon.
nonisolated enum WorldQuickStartGlyph: Equatable, Sendable {
    /// Two companions side by side: Walk together.
    case walk
    /// A dumbbell: at a workout space.
    case space
    /// A resting zigzag: a resting or unwell day.
    case rest
    /// The disposable camera: in a session, or during a walk or workout.
    case camera
    /// A tree: at the start of a saved walk.
    case trail
}

/// The blue button's rules (World app plan step 6b), first match wins:
///
/// 1. **A decoy** offers only the walk (and nothing while it walks), so nothing hints at a decoy.
/// 2. **During a walk** the camera, when there is one to offer (the walk bar holds End).
/// 3. **During a guided workout** the camera, and the way back to the workout.
/// 4. **In a session** the session's camera, then Walk together.
/// 5. **On a resting or unwell day** "Resting counts today" first, the gentle stretch leading, and the
///    usual choices below so nothing is taken away.
/// 6. **At a pinned space** today's plan there (or Move's suggestion when nothing is planned), then
///    Walk together.
/// 7. **At the start of a saved walk** that walk again, its line drawn to follow.
/// 8. **Anywhere else** Walk together.
///
/// A card with no choice is no card: the button hides (for example while walking with no camera, or
/// with location off).
nonisolated enum WorldQuickStart {
    /// The card for `context`, or nil when the button has nothing to offer.
    static func card(for context: WorldQuickStartContext) -> WorldQuickStartCard? {
        let card = rule(for: context)
        guard let card, !card.options.isEmpty else { return nil }
        return card
    }

    /// The button's icon, or nil when it hides.
    static func glyph(for context: WorldQuickStartContext) -> WorldQuickStartGlyph? {
        guard let card = card(for: context) else { return nil }
        if card.options.contains(where: \.isCamera) { return .camera }
        switch card.heading {
        case .space, .workout: return context.isResting ? .rest : .space
        case .gentle: return .rest
        case .savedLine: return .trail
        case .session, .walk, .walking: return .walk
        }
    }

    /// The first rule that matches.
    private static func rule(for context: WorldQuickStartContext) -> WorldQuickStartCard? {
        if context.isDecoy {
            guard context.activity == .none, context.canWalk else { return nil }
            return WorldQuickStartCard(heading: .walk, note: .nothingSaved, options: [.walkTogether])
        }
        switch context.activity {
        case .walking:
            return WorldQuickStartCard(heading: .walking, note: nil, options: camera(context).map { [$0] } ?? [])
        case .workout(let title):
            return WorldQuickStartCard(heading: .workout(title), note: nil,
                                       options: (camera(context).map { [$0] } ?? []) + [.backToWorkout(title: title)])
        case .none:
            return still(context)
        }
    }

    /// The rules while nothing is under way: session, resting, space, anywhere.
    private static func still(_ context: WorldQuickStartContext) -> WorldQuickStartCard {
        let walk: [WorldQuickStartOption] = context.canWalk ? [.walkTogether] : []
        if let session = context.session {
            return WorldQuickStartCard(heading: .session(session.names), note: nil,
                                       options: [.sessionCamera(shotsLeft: session.shotsLeft)] + walk)
        }
        if context.isResting { return resting(context, walk: walk) }
        if let space = context.space {
            let first: WorldQuickStartOption = context.plannedSession.map { .todaysPlan(space: space.name, session: $0) }
                ?? .suggestWorkout(space: space.name, equipment: space.equipment, gentle: false)
            return WorldQuickStartCard(heading: .space(space.name),
                                       note: context.plannedSession == nil ? .nothingPlanned(items: space.itemCount) : nil,
                                       options: [first] + walk)
        }
        if let line = context.savedLine, context.canWalk {
            return WorldQuickStartCard(heading: .savedLine, note: .walkedFromHere(times: line.walks),
                                       options: [.walkSavedLine(metres: line.metres)])
        }
        return WorldQuickStartCard(heading: .walk, note: .nothingSaved, options: walk)
    }

    /// A resting or unwell day: the gentle stretch leads; at a space the workout stays, gently;
    /// elsewhere the walk stays.
    private static func resting(_ context: WorldQuickStartContext, walk: [WorldQuickStartOption]) -> WorldQuickStartCard {
        let stretch: [WorldQuickStartOption] = context.hasGentleStretch ? [.gentleStretch] : []
        guard let space = context.space else {
            return WorldQuickStartCard(heading: .gentle, note: .restingCounts, options: stretch + walk)
        }
        return WorldQuickStartCard(heading: .space(space.name), note: .restingCounts,
                                   options: stretch + [.suggestWorkout(space: space.name, equipment: space.equipment, gentle: true)])
    }

    /// The camera to offer: the session's, else the on-your-own one when it exists.
    private static func camera(_ context: WorldQuickStartContext) -> WorldQuickStartOption? {
        if let session = context.session { return .sessionCamera(shotsLeft: session.shotsLeft) }
        return context.soloCameraAvailable ? .soloCamera : nil
    }
}

extension WorldQuickStartOption {
    /// Whether this choice opens the disposable camera.
    nonisolated var isCamera: Bool {
        switch self {
        case .sessionCamera, .soloCamera: true
        default: false
        }
    }
}
