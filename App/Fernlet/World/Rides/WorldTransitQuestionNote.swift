import FernletFoundation
import FernletUI
import SwiftUI
import WorldMapStore

/// Home's question after a ride the transit guess wasn't sure of (ferry and train build, owner's C1, 2026-11-15):
/// "Was that a train?" with [Train] [Bus or car] [Not sure], or "Was that a ferry?" with [Ferry] [Car or bus]
/// [Not sure]. Home shows it in the car question's place and on the same terms: only while the person is stopped
/// (never riding along), never over the quick-start card, never in a decoy.
///
/// An answer goes to `WorldFogKeeper.answerTransitQuestion(_:)`; a train, a ferry or a road plays a logged meal's
/// haptic and says what was kept, as the car question's Yes does. VoiceOver reads the question and its line as one,
/// then each answer as its own button.
struct WorldTransitQuestionNote: View {
    let question: WornTransitQuestion
    let onAnswer: (WornWayKind?) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(WornTransitAskCopy.question(question.guess))
                    .font(Font.custom(FernletFontName.dmSansBold, size: 15, relativeTo: .subheadline))
                Text(WornTransitAskCopy.line)
                    .font(Font.custom(FernletFontName.dmSans, size: 13, relativeTo: .footnote))
            }
            .foregroundStyle(WorldPalette.bark)
            .fernletWrappingText()
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    answers
                }
                VStack(alignment: .trailing, spacing: 8) { answers }
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(12)
        .frame(maxWidth: 360, alignment: .leading)
        .background(WorldPalette.paperLight, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(WorldPalette.ink, lineWidth: 2))
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("world.transitQuestion")
    }

    /// The three answers, the guess last (the filled one, nearest the thumb, as the car question's Yes).
    @ViewBuilder private var answers: some View {
        ForEach(WornTransitAnswer.allCases.reversed(), id: \.self) { answer in
            answerButton(answer)
        }
    }

    /// One answer: at least 44 pt, ink on paper; the guess filled.
    private func answerButton(_ answer: WornTransitAnswer) -> some View {
        let filled = answer == .guess
        return Button { choose(answer) } label: {
            Text(WornTransitAskCopy.title(answer, guess: question.guess))
                .font(Font.custom(FernletFontName.dmSansBold, size: 14, relativeTo: .subheadline))
                .foregroundStyle(filled ? WorldPalette.paperLight : WorldPalette.bark)
                .padding(.horizontal, 14)
                .frame(minWidth: 44, minHeight: 44)
                .background(filled ? WorldPalette.ink : WorldPalette.paperLight, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(WorldPalette.ink, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("world.transitQuestion.\(answer.rawValue)")
    }

    /// Answers; a kind says so with a logged meal's haptic and a spoken line.
    private func choose(_ answer: WornTransitAnswer) {
        let kind = question.kind(for: answer)
        onAnswer(kind)
        guard let kind else { return }
        FernletFeedback.system.play(.done)
        FernletAnnouncer.system.announce(.success, resolved: String(localized: WornTransitAskCopy.kept(kind)))
    }
}

/// The three answers to Home's transit question.
nonisolated enum WornTransitAnswer: String, CaseIterable, Sendable {
    /// Yes: the guess (Train or Ferry).
    case guess
    /// It went by road (Bus or car, Car or bus).
    case road
    /// Not sure: kept as guessed, never asked again.
    case notSure
}

/// What Home asks about a kept trip: only a train or a ferry guess is asked about (a road guess has nothing to
/// offer instead).
nonisolated struct WornTransitQuestion: Equatable, Sendable {
    /// The trip asked about.
    let tripID: UUID
    /// What the ride was guessed to be: ``WornWayKind/rail`` or ``WornWayKind/ferry``.
    let guess: WornWayKind

    /// The question for `trip`, or nil when its guess is a road or a subway hop (which has its own sheet), or the
    /// person already said what it was.
    init?(_ trip: WornTrip?) {
        guard let trip, !trip.confirmed, trip.kind == .rail || trip.kind == .ferry else { return nil }
        tripID = trip.id
        guess = trip.kind
    }

    /// The kind `answer` gives `answerTransitQuestion(_:)`: the guess, a road, or nil for Not sure.
    func kind(for answer: WornTransitAnswer) -> WornWayKind? {
        switch answer {
        case .guess: guess
        case .road: .road
        case .notSure: nil
        }
    }
}

/// Home's transit question's copy (ferry and train build, owner's C1).
nonisolated enum WornTransitAskCopy {
    static let line = LocalizedStringResource("wornTransit.ask.line", defaultValue: "Your answer sets how that ride shows on your map.",
                                              comment: "Home: under the question whether a ride was a train or a ferry")
    static let train = LocalizedStringResource("wornTransit.ask.train", defaultValue: "Train",
                                               comment: "Home: answer that the ride asked about was a train")
    static let ferry = LocalizedStringResource("wornTransit.ask.ferry", defaultValue: "Ferry",
                                               comment: "Home: answer that the ride asked about was a ferry or another boat")
    static let busOrCar = LocalizedStringResource("wornTransit.ask.busOrCar", defaultValue: "Bus or car",
                                                  comment: "Home: answer that the ride guessed as a train went by road")
    static let carOrBus = LocalizedStringResource("wornTransit.ask.carOrBus", defaultValue: "Car or bus",
                                                  comment: "Home: answer that the ride guessed as a ferry went by road")
    static let notSure = LocalizedStringResource("wornTransit.ask.notSure", defaultValue: "Not sure",
                                                 comment: "Home: answer to the train or ferry question; keeps the guess")

    /// "Was that a train?" or "Was that a ferry?"
    static func question(_ guess: WornWayKind) -> LocalizedStringResource {
        switch guess {
        case .ferry:
            LocalizedStringResource("wornTransit.ask.ferryQuestion", defaultValue: "Was that a ferry?",
                                    comment: "Home: asks whether the ride that just ended was on a ferry or another boat")
        case .rail, .road, .subway:
            LocalizedStringResource("wornTransit.ask.trainQuestion", defaultValue: "Was that a train?",
                                    comment: "Home: asks whether the ride that just ended was on a train")
        }
    }

    /// An answer's button title.
    static func title(_ answer: WornTransitAnswer, guess: WornWayKind) -> LocalizedStringResource {
        switch (answer, guess) {
        case (.guess, .ferry): ferry
        case (.guess, _): train
        case (.road, .ferry): carOrBus
        case (.road, _): busOrCar
        case (.notSure, _): notSure
        }
    }

    /// What VoiceOver says once an answer is kept.
    static func kept(_ kind: WornWayKind) -> LocalizedStringResource {
        switch kind {
        case .rail:
            LocalizedStringResource("wornTransit.ask.keptTrain", defaultValue: "Kept as a train ride.",
                                    comment: "Spoken after answering Home's question: the ride is now a train ride")
        case .ferry:
            LocalizedStringResource("wornTransit.ask.keptFerry", defaultValue: "Kept as a ferry ride.",
                                    comment: "Spoken after answering Home's question: the ride is now a ferry ride")
        case .road, .subway:
            LocalizedStringResource("wornTransit.ask.keptRoad", defaultValue: "Kept as a road trip.",
                                    comment: "Spoken after answering Home's question: the ride went by road")
        }
    }
}
