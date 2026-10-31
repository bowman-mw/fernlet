import FernletDomainModel
import FernletFoundation
import FernletScoring
import FernletUI
import SwiftUI

/// The travel-day workouts' words (World-Airports-Spec §13, approved; Spanish in the mockup). Display only:
/// nothing here is stored, matched or prompted with, and none of it names a flight, an airport or a place.
enum MoveTravelDayCopy {
    /// The Move card's line on a flight's date (screen 31, draft 2).
    static let flightDayLine: LocalizedStringResource = "Travel day: an easy walk and stretches."
    /// The Move card's line the day after an overnight flight (screen 35, draft 2).
    static let afterOvernightLine: LocalizedStringResource = "After an overnight flight: an easy walk and stretches."
    /// The plan sheet's eyebrow and the day page's chip.
    static let travelDay: LocalizedStringResource = "Travel day"
    /// "Lift instead, lighter": the light plan in the travel session's place (§13.2).
    static let liftInstead: LocalizedStringResource = "Lift instead, lighter"
    /// A planned session not done on a travel day (screen 34).
    static let forgiven: LocalizedStringResource = "Not done today, and that's fine. On a travel day it doesn't count as missed, and your weights stay where they were."
    /// The week card's caption (screen 34).
    static let thisWeek: LocalizedStringResource = "This week"

    /// The card's line for `kind`.
    static func cardLine(_ kind: WorkoutTravelDayKind) -> LocalizedStringResource {
        switch kind {
        case .flightDay: flightDayLine
        case .afterOvernight: afterOvernightLine
        }
    }

    /// "8 moves · ~40 min · outdoors in daylight if you can" under the session's name.
    static func sessionMeta(moves: Int, minutes: Int) -> LocalizedStringResource {
        "\(moves) moves · ~\(minutes) min · outdoors in daylight if you can"
    }

    /// "2 of 2 sessions": the week's done planned sessions of those that count.
    static func weekSessions(_ done: Int, of total: Int) -> LocalizedStringResource {
        "\(done) of \(total) sessions"
    }

    /// "Saturday was a travel day, so it's left out." `weekday` is already in the person's language.
    static func leftOut(weekday: String) -> LocalizedStringResource {
        "\(weekday) was a travel day, so it's left out."
    }

    /// Each move's figure on the session card, by its frozen catalog name (§13.2).
    static func figure(for name: String) -> LocalizedStringResource {
        switch name {
        case "Easy walk": "20–30 min"
        case "Standing calf raise": "2 × 15"
        case "Glute bridge": "2 × 12"
        case "Cat-cow": "8 slow"
        case "Thread the needle": "5 each side"
        default: "30 s each side"
        }
    }
}

/// The Travel-day reset on the plan sheet (screen 32, `b3-suggest-plan`): one framed card with the session's
/// name, its one-line summary and its eight moves (each with its how-to), then the approved reason line and
/// "Lift instead, lighter". No "Why this session" (the owner's note on 33).
struct TravelDaySessionCard: View {
    /// The committed session (its note is the reason line).
    let session: WorkoutProgram.SessionSuggestion
    /// Opens a move's how-to.
    let onHowTo: (String) -> Void
    /// Swaps in the light plan.
    let onLiftInstead: () -> Void
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: session.displayedName)
                    .font(look == nil ? .fernlet(.headerMedium) : FernletFramedFont.cardTitle)
                    .foregroundStyle(look?.text ?? Color.bark)
                    .accessibilityAddTraits(.isHeader)
                Text(MoveTravelDayCopy.sessionMeta(moves: WorkoutPlanner.travelDayMoveNames.count,
                                                   minutes: WorkoutPlanner.travelDayMinutes))
                    .font(look == nil ? .fernlet(.labelSmall) : FernletFramedFont.body)
                    .foregroundStyle(look?.dim ?? Color.slate)
                    .fernletWrappingText()
                moveRows.controlSize(look == nil ? .regular : .small)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(MoveInsetCardFrame(cornerRadius: look == nil ? 14 : 12))
            reasonAndLink
        }
    }

    /// The eight moves, a dotted rule above each.
    private var moveRows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(WorkoutPlanner.travelDayMoveNames, id: \.self) { name in
                FernletDottedRule().padding(.vertical, 4)
                TravelDayMoveRow(name: name) { onHowTo(name) }
                    .frame(minHeight: 36)
            }
        }
    }

    /// The reason line and the one link under the card.
    private var reasonAndLink: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !session.suggestion.notes.isEmpty {
                Text(verbatim: session.suggestion.notes)
                    .font(look == nil ? .fernlet(.bubble) : FernletFramedFont.body)
                    .foregroundStyle(look?.text ?? Color.bark)
                    .fernletWrappingText()
            }
            Button(action: onLiftInstead) { Text(MoveTravelDayCopy.liftInstead) }
                .font(look == nil ? .fernlet(.label) : FernletFramedFont.sheetControl)
                .foregroundStyle(look?.link ?? Color.mossInk)
                .buttonStyle(.plain)
                .fernletTapTarget()
                .accessibilityIdentifier("workout.travel.liftInstead")
        }
    }
}

/// One move of the Travel-day reset: its name in the person's language, its figure ("2 × 15", "30 s each
/// side") and its how-to button. At accessibility sizes the figure goes under the name.
private struct TravelDayMoveRow: View {
    let name: String
    let onHowTo: () -> Void
    @Environment(\.fernletFramedLook) private var look
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            AdaptiveStack(spacing: dynamicTypeSize.isAccessibilitySize ? 2 : 10, horizontalAlignment: .leading) {
                Text(verbatim: ExerciseHowToCatalog.displayName(for: name))
                    .font(look == nil ? .fernlet(.body) : FernletFramedFont.body)
                    .foregroundStyle(look?.text ?? Color.bark)
                    .fernletWrappingText()
                if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 8) }
                Text(MoveTravelDayCopy.figure(for: name))
                    .font(look == nil ? .fernlet(.labelSmall) : MoveFont.body)
                    .foregroundStyle(look?.text ?? Color.slate)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            ExerciseHowToButton(exerciseName: name, action: onHowTo)
        }
    }
}

/// The day page's travel-day pieces (screen 34, `b2-move-day`): under a travel day's plan, the chip and the
/// forgiven line when a planned session isn't done today, and the week's count that leaves a travel day's
/// planned sessions out. Draws nothing on any other day.
struct TravelDayPlanNotes: View {
    /// Whether this page's day is a travel day with a planned session not done (the forgiven line shows on
    /// today's page, whose words say "today").
    let showsForgiven: Bool
    /// The week's count, when a travel day's planned sessions were left out of it.
    let week: TravelDayWeekProgress?
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        if showsForgiven {
            VStack(alignment: .leading, spacing: 8) {
                TravelDayChip()
                HStack(alignment: .top, spacing: 9) {
                    WorldSpriteView(sprite: WorldSprites.check, scale: 2).accessibilityHidden(true)
                    Text(MoveTravelDayCopy.forgiven)
                        .font(look == nil ? .fernlet(.bodySmall) : FernletFramedFont.body)
                        .foregroundStyle(look?.text ?? Color.bark)
                        .fernletWrappingText()
                }
                .accessibilityElement(children: .combine)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(MoveInsetCardFrame(cornerRadius: 9))
        }
        if let week, let weekday = week.leftOutWeekday {
            TravelDayWeekCard(done: week.done, total: week.total, weekday: weekday)
        }
    }
}

/// "Travel day" beside the suitcase (`aptw`): the day page's tag. The suitcase is decoration.
private struct TravelDayChip: View {
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        HStack(spacing: 6) {
            WorldSpriteView(sprite: WorldAirportSprites.suitcase, scale: 2).accessibilityHidden(true)
            Text(MoveTravelDayCopy.travelDay)
                .font(look == nil ? .fernlet(.labelSmall) : MoveFont.rowDetail)
                .foregroundStyle(look?.text ?? Color.bark)
        }
        .padding(.vertical, 3)
        .padding(.leading, 6)
        .padding(.trailing, 8)
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(look?.ink ?? Color.bark, lineWidth: 2))
    }
}

/// "This week · 2 of 2 sessions · Saturday was a travel day, so it's left out." (screen 34).
private struct TravelDayWeekCard: View {
    let done: Int
    let total: Int
    let weekday: String
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            AdaptiveStack(spacing: 6, horizontalAlignment: .leading) {
                Text(MoveTravelDayCopy.thisWeek)
                    .font(look == nil ? .fernlet(.labelSmall) : MoveFont.caption)
                    .foregroundStyle(look?.dim ?? Color.slate)
                Spacer(minLength: 8)
                Text(MoveTravelDayCopy.weekSessions(done, of: total))
                    .font(look == nil ? .fernlet(.label) : MoveFont.rowValue)
                    .foregroundStyle(look?.text ?? Color.bark)
            }
            Text(MoveTravelDayCopy.leftOut(weekday: weekday))
                .font(look == nil ? .fernlet(.bodySmall) : FernletFramedFont.body)
                .foregroundStyle(look?.dim ?? Color.slate)
                .fernletWrappingText()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(MoveInsetCardFrame(cornerRadius: 9))
        .accessibilityElement(children: .combine)
    }
}
