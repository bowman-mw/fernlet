import FernletFoundation
import FernletUI
import SwiftUI

/// Home's one-time question about a Bluetooth device seen on a drive (owner 2026-11-09, car signals; the approved
/// "Ask during a drive" card): "Is "Camry" your car?", what Yes does, and [Not my car] [Yes]. Home shows it only while
/// its device is connected and the person isn't riding along (never during a drive, so never to someone moving), and
/// never in a decoy (``WorldCarKeeper/askable``). Paper and ink like Remember this place, with the car Sprout rides in.
///
/// Yes marks the device as a car and says so, with a logged meal's haptic; Not my car keeps it out for good. VoiceOver
/// reads the question and its line as one, then the two buttons.
struct WorldCarQuestionNote: View {
    let question: WorldCarBook.Question
    /// The companion's name for the line ("Sprout will know …").
    let companion: String
    let onAnswer: (Bool) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                WorldSpriteView(sprite: WorldSprites.rideCar(dark: colorScheme == .dark, increasedContrast: contrast == .increased),
                                scale: 1.5)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(WorldCarCopy.question(question.name))
                        .font(Font.custom(FernletFontName.dmSansBold, size: 15, relativeTo: .subheadline))
                    Text(WorldCarCopy.line(companion: companion))
                        .font(Font.custom(FernletFontName.dmSans, size: 13, relativeTo: .footnote))
                }
                .foregroundStyle(WorldPalette.bark)
                .fernletWrappingText()
                .accessibilityElement(children: .combine)
            }
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                answerButton(WorldCarCopy.notMyCar, isCar: false, identifier: "world.carQuestion.no")
                answerButton(WorldCarCopy.yes, isCar: true, identifier: "world.carQuestion.yes")
            }
        }
        .padding(12)
        .frame(maxWidth: 360, alignment: .leading)
        .background(WorldPalette.paperLight, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(WorldPalette.ink, lineWidth: 2))
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("world.carQuestion")
    }

    /// One answer: at least 44 pt, ink on paper.
    private func answerButton(_ title: LocalizedStringResource, isCar: Bool, identifier: String) -> some View {
        Button { answer(isCar) } label: {
            Text(title)
                .font(Font.custom(FernletFontName.dmSansBold, size: 14, relativeTo: .subheadline))
                .foregroundStyle(isCar ? WorldPalette.paperLight : WorldPalette.bark)
                .padding(.horizontal, 14)
                .frame(minWidth: 44, minHeight: 44)
                .background(isCar ? WorldPalette.ink : WorldPalette.paperLight, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(WorldPalette.ink, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }

    /// Answers, and on Yes says so with a logged meal's haptic.
    private func answer(_ isCar: Bool) {
        onAnswer(isCar)
        guard isCar else { return }
        FernletFeedback.system.play(.done)
        FernletAnnouncer.system.announce(.success, resolved: String(localized: HomeMapCarCopy.marked(question.name)))
    }
}

/// The car question's copy (owner 2026-11-09, approved with the "Ask during a drive" card).
nonisolated enum WorldCarCopy {
    static let notMyCar = LocalizedStringResource("worldCar.question.notMyCar", defaultValue: "Not my car",
                                                  comment: "Home: the car question's answer that the device isn't the person's car")
    static let yes = LocalizedStringResource("worldCar.question.yes", defaultValue: "Yes",
                                             comment: "Home: the car question's answer that the device is the person's car")

    /// "Is "Camry" your car?"
    static func question(_ name: String) -> LocalizedStringResource {
        LocalizedStringResource("worldCar.question", defaultValue: "Is \"\(name)\" your car?",
                                comment: "Home: asks whether a Bluetooth device seen on a drive is the person's car; its name")
    }

    /// "Sprout will know you're driving whenever you connect."
    static func line(companion: String) -> LocalizedStringResource {
        LocalizedStringResource("worldCar.question.line", defaultValue: "\(companion) will know you're driving whenever you connect.",
                                comment: "Home: under the car question, what Yes does; the companion's name")
    }
}
