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

    /// A favourite place to eat the person stands at (`b1-qs-food`; three meals or more logged there).
    struct EatingOut: Equatable, Sendable {
        let id: UUID
        /// Its name: the person's own, else Apple's given again by reference, else "A place you eat".
        let name: String
        /// How many meals were logged there.
        let meals: Int
        /// The usual's name, when it can be logged again.
        let usual: String?
    }

    /// A friend session running now.
    struct Session: Equatable, Sendable {
        /// The other people's first names, in roster order.
        let names: [String]
        /// Shots left on the session's shared film.
        let shotsLeft: Int
    }

    /// A walk or run of the person's own, saved on this iPhone, that started within 100 m of here.
    struct SavedLine: Equatable, Sendable {
        /// Its length, in metres.
        let metres: Double
        /// How many recent walks (or runs, for a run's line) started here.
        let walks: Int
        /// A walk's line (a trail, `b1-qs-trail`) or a run's (a saved run route, `b1-qs-run`).
        var kind: WorldWalkRecorder.Kind = .walk
    }

    /// What the person is doing right now.
    enum Activity: Equatable, Sendable {
        case none
        /// A walk (Walk together, or a saved line again) is recording.
        case walking
        /// A run on a saved route is recording.
        case running
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
    /// A favourite place to eat within 75 m (`b1-qs-food`, `b3-qs-food-camera`).
    var eatingPlace: EatingOut?
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
    /// Whether friends in person are offered at all (`b4-mem-blue-*`): never in a decoy, below the
    /// minimum age, or while Delete everything runs (the radios' own hard stops).
    var canMeetFriends = false
    /// Kept friends the presence radio hears nearby right now, by first name (at most two; empty with
    /// Nearby friends off). Strangers are never here: presence recognises kept friends only.
    var nearbyFriends: [String] = []
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
    /// How many recent walks (or runs) started here.
    let walks: Int
    /// A walk's line or a run's.
    var kind: WorldWalkRecorder.Kind = .walk

    /// The card's facts.
    var summary: WorldQuickStartContext.SavedLine { WorldQuickStartContext.SavedLine(metres: metres, walks: walks, kind: kind) }
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
    /// Run a saved run route again (`b1-qs-run`): recorded and logged as a run, the line drawn to follow.
    case runSavedLine(metres: Double)
    /// The session's disposable camera, on its shared film.
    case sessionCamera(shotsLeft: Int)
    /// The disposable camera on your own (10 a day, the photos appear tonight).
    case soloCamera
    /// Back to the guided workout under way.
    case backToWorkout(title: String)
    /// "Start a session with Sam" (`b4-mem-blue-friend`): Friends nearby, where the phones meet.
    case startSession(friend: String)
    /// "Start an activity": Activities, a walk, coffee or meal that friends nearby can join.
    case startActivity
    /// "Friends nearby": the same page, for a session, a hangout or a new friend when the presence
    /// radio hears no friend (it can't hear people who aren't friends; `b4-mem-blue-join`, `-blue-new`).
    case friendsNearby
    /// "Log your usual: tonkotsu ramen" at a favourite place to eat (`b1-qs-food`): logs it again, in one tap.
    case logUsual(meal: String, meals: Int)
    /// "Find Hoshi Noodle Bar's menu": the meal sheet, ready for Fernlet's food lookup by the place's name;
    /// the person's location is never sent.
    case findMenu(place: String)
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
        /// "Your run from here": a saved run route starts where the person stands (`b1-qs-run`).
        case savedRun
        /// "A gentle day": resting, away from a space.
        case gentle
        /// "On your walk": while a walk records.
        case walking
        /// "On your run": while a run records.
        case running
        /// The guided workout's title, while it runs.
        case workout(String)
        /// "Sam is nearby" (`b4-mem-blue-friend`).
        case friendNearby([String])
        /// "Together, in person": nothing else to offer here but friends nearby.
        case inPerson
        /// A favourite place to eat's name (`b1-qs-food`).
        case eatingPlace(String)
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
        /// "You've run this route 8 times"
        case ranFromHere(times: Int)
        /// "You've logged meals here 4 times" (`b1-qs-food`)
        case loggedMealsHere(times: Int)
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
    /// A runner: at the start of a saved run route.
    case run
    /// Two people: a friend nearby, or friends in person.
    case friends
    /// A bowl: at a favourite place to eat (`b1-qs-food`, and with the camera too, `b3-qs-food-camera`).
    case eat
}

/// The blue button's rules (World app plan step 6b), first match wins:
///
/// 1. **A decoy** offers only the walk (and nothing while it walks), so nothing hints at a decoy.
/// 2. **During a walk or run** the camera, when there is one to offer (the walk bar holds End).
/// 3. **During a guided workout** the camera, and the way back to the workout.
/// 4. **In a session** the session's camera, then Walk together.
/// 5. **With a friend nearby** (`b4-mem-blue-friend`) "Sam is nearby": Start a session with Sam,
///    Start an activity, and the usual choices below so nothing is taken away.
/// 6a. **At a favourite place to eat** (away from a pinned space, round 6: `b1-qs-food`, `b3-qs-food-camera`)
///    its name: Log your usual, the disposable camera on your own, Find its menu; on a resting day too. The
///    button shows the bowl, never badges or buzzes on arrival.
/// 6. **On a resting or unwell day** "Resting counts today" first, the gentle stretch leading, and the
///    usual choices below so nothing is taken away.
/// 7. **At a pinned space** today's plan there (or Move's suggestion when nothing is planned), then
///    Walk together.
/// 8. **At the start of a saved walk** that walk again, its line drawn to follow; **at the start of a saved
///    run route** that run again, then Walk together (`b1-qs-run`).
/// 9. **Anywhere else** Walk together.
///
/// Rules 6 to 9 end with "Friends nearby" while friends are offered at all, so a session, a hangout
/// and a new friend stay reachable when the presence radio hears no friend (`b4-mem-blue-join`,
/// `-blue-new`). A card with no choice is no card: the button hides (for example while walking with no
/// camera, or in a decoy with location off).
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
        // At a favourite place to eat the bowl stays, camera row or not (`b3-qs-food-camera`).
        if case .eatingPlace = card.heading { return .eat }
        if card.options.contains(where: \.isCamera) { return .camera }
        switch card.heading {
        case .space, .workout: return context.isResting ? .rest : .space
        case .gentle: return .rest
        case .savedLine: return .trail
        case .savedRun: return .run
        case .session, .walk, .walking, .running: return .walk
        case .friendNearby, .inPerson: return .friends
        case .eatingPlace: return .eat
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
        case .running:
            return WorldQuickStartCard(heading: .running, note: nil, options: camera(context).map { [$0] } ?? [])
        case .workout(let title):
            return WorldQuickStartCard(heading: .workout(title), note: nil,
                                       options: (camera(context).map { [$0] } ?? []) + [.backToWorkout(title: title)])
        case .none:
            return still(context)
        }
    }

    /// The rules while nothing is under way: session, a friend nearby, then the usual ones with friends
    /// nearby last.
    private static func still(_ context: WorldQuickStartContext) -> WorldQuickStartCard {
        let walk: [WorldQuickStartOption] = context.canWalk ? [.walkTogether] : []
        if let session = context.session {
            return WorldQuickStartCard(heading: .session(session.names), note: nil,
                                       options: [.sessionCamera(shotsLeft: session.shotsLeft)] + walk)
        }
        let card = usual(context, walk: walk)
        guard context.canMeetFriends else { return card }
        if let friend = context.nearbyFriends.first {
            return WorldQuickStartCard(heading: .friendNearby(context.nearbyFriends), note: nil,
                                       options: [.startSession(friend: friend), .startActivity] + card.options)
        }
        guard !card.options.isEmpty else {
            return WorldQuickStartCard(heading: .inPerson, note: nil, options: [.friendsNearby])
        }
        return WorldQuickStartCard(heading: card.heading, note: card.note, options: card.options + [.friendsNearby])
    }

    /// The rules without friends: a place to eat, resting, space, saved walk, anywhere.
    private static func usual(_ context: WorldQuickStartContext, walk: [WorldQuickStartOption]) -> WorldQuickStartCard {
        if context.space == nil, let place = context.eatingPlace { return eating(place, context) }
        if context.isResting { return resting(context, walk: walk) }
        if let space = context.space {
            let first: WorldQuickStartOption = context.plannedSession.map { .todaysPlan(space: space.name, session: $0) }
                ?? .suggestWorkout(space: space.name, equipment: space.equipment, gentle: false)
            return WorldQuickStartCard(heading: .space(space.name),
                                       note: context.plannedSession == nil ? .nothingPlanned(items: space.itemCount) : nil,
                                       options: [first] + walk)
        }
        if let line = context.savedLine, context.canWalk {
            guard line.kind == .run else {
                return WorldQuickStartCard(heading: .savedLine, note: .walkedFromHere(times: line.walks),
                                           options: [.walkSavedLine(metres: line.metres)])
            }
            return WorldQuickStartCard(heading: .savedRun, note: .ranFromHere(times: line.walks),
                                       options: [.runSavedLine(metres: line.metres)] + walk)
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

    /// At a favourite place to eat (`b1-qs-food`, `b3-qs-food-camera`): the usual in one tap, the camera on
    /// your own second (its solo rules: 10 a day, they appear tonight), and the menu search by name.
    private static func eating(_ place: WorldQuickStartContext.EatingOut, _ context: WorldQuickStartContext) -> WorldQuickStartCard {
        let usual: [WorldQuickStartOption] = place.usual.map { [.logUsual(meal: $0, meals: place.meals)] } ?? []
        let camera: [WorldQuickStartOption] = context.soloCameraAvailable ? [.soloCamera] : []
        return WorldQuickStartCard(heading: .eatingPlace(place.name), note: .loggedMealsHere(times: place.meals),
                                   options: usual + camera + [.findMenu(place: place.name)])
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
