import Foundation

/// The quick start's words (designs `b1-qs-*`, `b3-qs-*`, `b1-home-walk`), in the person's language.
/// The card's model (``WorldQuickStartCard``) holds facts; this turns them into lines.
nonisolated enum WorldQuickStartCopy {
    static let buttonLabel = LocalizedStringResource("worldQuickStart.label", defaultValue: "Quick start",
                                                     comment: "World Home: the blue button's name, for VoiceOver and Voice Control")
    static let buttonHint = LocalizedStringResource("worldQuickStart.hint", defaultValue: "Shows what you can start here.",
                                                    comment: "World Home: what the blue quick-start button does, for VoiceOver")

    /// The card's heading.
    static func heading(_ heading: WorldQuickStartCard.Heading) -> String {
        switch heading {
        case .space(let name):
            return name
        case .session(let names):
            let list = names.formatted(.list(type: .and))
            return String(localized: "worldQuickStart.heading.session", defaultValue: "With \(list)",
                          comment: "World Home quick-start card heading in a friend session: the friends' first names, e.g. 'With Sam and Rae'")
        case .walk:
            return String(localized: "worldQuickStart.heading.walk", defaultValue: "Go for a walk",
                          comment: "World Home quick-start card heading when nothing is saved where the person stands")
        case .gentle:
            return String(localized: "worldQuickStart.heading.gentle", defaultValue: "A gentle day",
                          comment: "World Home quick-start card heading on a resting or unwell day, away from a workout space")
        case .walking:
            return String(localized: "worldQuickStart.heading.walking", defaultValue: "On your walk",
                          comment: "World Home quick-start card heading while a walk is recording")
        case .savedLine:
            return String(localized: "worldQuickStart.heading.savedLine", defaultValue: "Your walk from here",
                          comment: "World Home quick-start card heading where one of the person's saved walks starts")
        case .savedRun:
            return String(localized: "worldQuickStart.heading.savedRun", defaultValue: "Your run from here",
                          comment: "World Home quick-start card heading where one of the person's saved run routes starts")
        case .running:
            return String(localized: "worldQuickStart.heading.running", defaultValue: "On your run",
                          comment: "World Home quick-start card heading while a run records")
        case .workout(let title):
            return title
        case .friendNearby(let names):
            return friendsAreNearby(names)
        case .inPerson:
            return String(localized: "worldQuickStart.heading.inPerson", defaultValue: "Together, in person",
                          comment: "World Home quick-start card heading when friends nearby is the only choice")
        }
    }

    /// "Sam is nearby", or "Sam and Rae are nearby".
    static func friendsAreNearby(_ names: [String]) -> String {
        guard names.count > 1 else { return FriendsNearbyCopy.isNearby(names.first ?? "") }
        let list = names.formatted(.list(type: .and))
        return String(localized: "worldQuickStart.heading.friendsNearby", defaultValue: "\(list) are nearby",
                      comment: "World Home quick-start card heading: two friends nearby, e.g. 'Sam and Rae are nearby'")
    }

    /// What VoiceOver hears on the blue button with a friend nearby: "Sam is nearby. Start a session or
    /// an activity." Nil otherwise.
    static func spokenStatus(_ card: WorldQuickStartCard?) -> String? {
        guard case .friendNearby(let names) = card?.heading else { return nil }
        return String(localized: "worldQuickStart.status.friendNearby",
                      defaultValue: "\(friendsAreNearby(names)). Start a session or an activity.",
                      comment: "World Home: the blue button's VoiceOver value with a friend nearby; the heading, e.g. 'Sam is nearby'")
    }

    /// The line under the heading.
    static func note(_ note: WorldQuickStartCard.Note) -> String {
        switch note {
        case .nothingPlanned(let items):
            return String(localized: "worldQuickStart.note.nothingPlanned",
                          defaultValue: "Nothing planned yet. Fernlet can put something together from this space's \(items) items.",
                          comment: "World Home quick-start card at a workout space with no plan today; the number is how many pieces of equipment the space holds. Plural on the number")
        case .nothingSaved:
            return String(localized: "worldQuickStart.note.nothingSaved",
                          defaultValue: "Nothing saved here yet. It shows up once you've trained, hiked or eaten here a few times.",
                          comment: "World Home quick-start card away from any saved place")
        case .restingCounts:
            return String(localized: "worldQuickStart.note.resting",
                          defaultValue: "Resting counts today. These are here if you want them.",
                          comment: "World Home quick-start card on a resting or unwell day, before the gentle choices")
        case .walkedFromHere(let times):
            return String(localized: "worldQuickStart.note.walkedFromHere", defaultValue: "You've walked from here \(times) times",
                          comment: "World Home quick-start card where saved walks start: how many recent walks started here. Plural on the number")
        case .ranFromHere(let times):
            return String(localized: "worldQuickStart.note.ranFromHere", defaultValue: "You've run this route \(times) times",
                          comment: "World Home quick-start card where a saved run route starts: how many recent runs started here. Plural on the number")
        }
    }

    /// A choice's name.
    static func title(_ option: WorldQuickStartOption) -> String {
        switch option {
        case .todaysPlan(let space, _):
            return String(localized: "worldQuickStart.todaysPlan", defaultValue: "Today's plan at \(space)",
                          comment: "World Home quick start: starts today's guided workout at the named workout space")
        case .suggestWorkout:
            return String(localized: "worldQuickStart.suggest", defaultValue: "Suggest today's workout",
                          comment: "World Home quick start at a workout space: opens Move's workout suggestion for it")
        case .gentleStretch:
            return String(localized: "worldQuickStart.gentleStretch", defaultValue: "Gentle stretch",
                          comment: "World Home quick start on a resting day: a guided gentle stretch")
        case .walkTogether:
            return String(localized: "worldQuickStart.walk", defaultValue: "Walk together",
                          comment: "World Home quick start: start a walk with the companion, recorded on the map")
        case .walkSavedLine:
            return String(localized: "worldQuickStart.savedLine", defaultValue: "Walk it again",
                          comment: "World Home quick start where a saved walk starts: walk that same line again")
        case .runSavedLine:
            return String(localized: "worldQuickStart.savedRun", defaultValue: "Run it again",
                          comment: "World Home quick start where a saved run route starts: run that same route again")
        case .sessionCamera, .soloCamera:
            return String(localized: "worldQuickStart.camera", defaultValue: "Disposable camera",
                          comment: "World Home quick start: opens the disposable camera")
        case .backToWorkout(let title):
            return String(localized: "worldQuickStart.backToWorkout", defaultValue: "Back to \(title)",
                          comment: "World Home quick start during a guided workout: returns to it; the workout's name")
        case .startSession(let friend):
            return FriendsNearbyCopy.startSession(with: friend)
        case .startActivity:
            return String(localized: "worldQuickStart.startActivity", defaultValue: "Start an activity",
                          comment: "World Home quick start with a friend nearby: opens Activities to plan one friends nearby can join")
        case .friendsNearby:
            return String(localized: "worldQuickStart.friendsNearby", defaultValue: "Friends nearby",
                          comment: "World Home quick start: opens Friends nearby, to start a session or make a friend in person")
        }
    }

    /// A choice's line.
    static func detail(_ option: WorldQuickStartOption) -> String {
        switch option {
        case .todaysPlan(_, let session):
            return session
        case .suggestWorkout(let space, let equipment, let gentle):
            return gentle ? String(localized: "worldQuickStart.suggest.gentle", defaultValue: "\(space) · only if you feel up to it",
                                   comment: "World Home quick start on a resting day at a workout space: the space's name, then a gentle qualifier")
                : [space, equipment].filter { !$0.isEmpty }.joined(separator: " · ")
        case .gentleStretch:
            return String(localized: "worldQuickStart.gentleStretch.detail", defaultValue: "About 8 min · no equipment",
                          comment: "World Home quick start: the gentle stretch's length and what it needs")
        case .walkTogether:
            return String(localized: "worldQuickStart.walk.detail", defaultValue: "Precise location for this walk only",
                          comment: "World Home quick start: under Walk together; precise location is used for this walk only")
        case .walkSavedLine(let metres):
            let distance = WorldWalkCopy.distance(metres)
            return String(localized: "worldQuickStart.savedLine.detail", defaultValue: "\(distance) · your saved line",
                          comment: "World Home quick start: under 'Walk it again'; the saved walk's length")
        case .runSavedLine(let metres):
            let distance = WorldWalkCopy.distance(metres)
            return String(localized: "worldQuickStart.savedRun.detail", defaultValue: "\(distance) · your saved route",
                          comment: "World Home quick start: under 'Run it again'; the saved run route's length")
        case .sessionCamera(let shots):
            return String(localized: "worldQuickStart.camera.session", defaultValue: "\(shots) shots left · shared with the session",
                          comment: "World Home quick start in a friend session: the shared film's shots left. Plural on the number")
        case .soloCamera:
            return String(localized: "worldQuickStart.camera.solo", defaultValue: "Yours only · 10 a day · they appear tonight",
                          comment: "World Home quick start on your own: the disposable camera's rules (10 photos a day, shown after the companion sleeps)")
        case .backToWorkout:
            return String(localized: "worldQuickStart.backToWorkout.detail", defaultValue: "Your workout is still going",
                          comment: "World Home quick start during a guided workout: under 'Back to …'")
        case .startSession:
            return FriendsNearbyCopy.sessionDetail
        case .startActivity:
            return String(localized: "worldQuickStart.startActivity.detail", defaultValue: "A walk, coffee or meal that friends nearby can join",
                          comment: "World Home quick start: under 'Start an activity'")
        case .friendsNearby:
            return String(localized: "worldQuickStart.friendsNearby.detail", defaultValue: "Start a session or make a friend, in person",
                          comment: "World Home quick start: under 'Friends nearby'")
        }
    }
}
