import Testing
import FernletDomainModel
import FernletUI
@testable import Fernlet

/// The World build's Customize, App colors, launch and onboarding pieces (designs `b2-customize`,
/// `b2-colors`, `b2-launch-fail`, `b2-onb-*`): their art is well formed, and the values they show
/// read right.
@MainActor
struct WorldCustomizeOnboardingTests {
    private func isRectangle(_ sprite: WorldSprite) -> Bool {
        let width = sprite.width
        return width > 0 && sprite.rows.allSatisfy { $0.count == width }
            && sprite.rows.joined().allSatisfy { $0 == "." || sprite.palette[$0] != nil }
    }

    @Test func theLaneArtIsRectangularWithEveryKeyColoured() {
        #expect(isRectangle(WorldLaunchArt.warning))
        #expect(isRectangle(OnboardingArt.bell))
        #expect(!WorldLaunchArt.warning.isMonoInk)
    }

    @Test func everyBuiltInPieceHasArtOrASymbol() {
        for accessory in CompanionAccessory.allCases {
            #expect(CustomizeSlotArt.sprite(for: accessory) != nil)
        }
        #expect(CustomizeSlotArt.sprite(for: CompanionClothing.none) == WorldSprites.xx)
        #expect(CustomizeSlotArt.sprite(for: CompanionSideItem.none) == WorldSprites.xx)
    }

    @Test func weightAndHeightReadInTheirUnits() {
        #expect(OnboardingMeasureText.weight(170, imperial: true) == "170 lb")
        #expect(OnboardingMeasureText.weight(76.4, imperial: false) == "76 kg")
        #expect(OnboardingMeasureText.height(68, imperial: true) == "5 ft 8 in")
        #expect(OnboardingMeasureText.height(175, imperial: false) == "175 cm")
    }

    @Test func paperPresetsStartWithTodaysDefaultsAndNeverRepeat() {
        #expect(AppPaperPreset.light.first?.hex == FernletThemeDefaults.lightBackgroundHex)
        #expect(AppPaperPreset.dark.first?.hex == FernletThemeDefaults.darkBackgroundHex)
        let all = (AppPaperPreset.light + AppPaperPreset.dark).map { $0.hex.uppercased() }
        #expect(Set(all).count == all.count)
    }

    @Test func theProgressSegmentsFollowTheStep() {
        let position = OnboardingStepPosition(index: OnboardingCoordinatorModel.Step.storageChoice.rawValue,
                                              count: OnboardingCoordinatorModel.Step.allCases.count)
        #expect(position.index == 2)
        #expect(position.count == 8)
    }
}
