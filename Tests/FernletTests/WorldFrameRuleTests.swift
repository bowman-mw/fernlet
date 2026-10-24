import Foundation
import Testing
import FernletUI
import SwiftUI
import UIKit
@testable import Fernlet

/// The frame rule (World Review Refinements `ref-frames-rule`, approved 2026-10-24): one frame per
/// section, hairlines inside, frames on controls only, applied once in FernletUI's shared pieces.
@MainActor
struct WorldFrameRuleTests {

    /// The section's frame and the spacing around it are the approved numbers.
    @Test func theSectionFrameIsTheApprovedOne() {
        #expect(FernletFrameRule.frameWidth == 2)
        #expect(FernletFrameRule.cornerRadius == 12)
        #expect(FernletFrameRule.shadowOffset == 3)
        #expect(FernletFrameRule.verticalPadding == 14)
        #expect(FernletFrameRule.horizontalPadding == 15)
        #expect(FernletFrameRule.padding == EdgeInsets(top: 14, leading: 15, bottom: 14, trailing: 15))
        #expect(FernletFrameRule.sectionSpacing == 16)
        #expect(FernletFrameRule.labelGap == 6)
        // The look's card frame and the rule agree, so the two can never drift apart.
        #expect(FernletFramedLook.cardRadius == FernletFrameRule.cornerRadius)
        #expect(FernletFramedLook.frameWidth == FernletFrameRule.frameWidth)
    }

    /// Inside a section: 1-pt hairlines at 16 %, 40 % under Increase Contrast, 10 pt above and below a row.
    @Test func hairlinesAreOnePointAtSixteenPercent() {
        #expect(FernletFrameRule.hairlineWidth == 1)
        #expect(FernletFrameRule.rowSpacing == 10)
        #expect(FernletFrameRule.hairlineOpacity(increasedContrast: false) == 0.16)
        #expect(FernletFrameRule.hairlineOpacity(increasedContrast: true) == 0.4)
    }

    /// The World palette's hairline is ink at 16 % in light mode and cream at 16 % in dark, 40 % under
    /// Increase Contrast.
    @Test func theWorldHairlineFollowsDarkModeAndContrast() {
        let rule = UIColor(WorldPalette.rule)
        func rgba(_ style: UIUserInterfaceStyle, _ contrast: UIAccessibilityContrast) -> [CGFloat] {
            let traits = UITraitCollection { $0.userInterfaceStyle = style; $0.accessibilityContrast = contrast }
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            rule.resolvedColor(with: traits).getRed(&r, green: &g, blue: &b, alpha: &a)
            return [r * 255, g * 255, b * 255, a]
        }
        let light = rgba(.light, .normal), dark = rgba(.dark, .normal)
        #expect(abs(light[0] - 74) < 1 && abs(light[1] - 46) < 1 && abs(light[2] - 28) < 1, "light: the ink")
        #expect(abs(light[3] - 0.16) < 0.01)
        #expect(abs(dark[0] - 255) < 1 && abs(dark[1] - 241) < 1 && abs(dark[2] - 207) < 1, "dark: the cream")
        #expect(abs(dark[3] - 0.16) < 0.01)
        #expect(abs(rgba(.light, .high)[3] - 0.4) < 0.01)
        #expect(abs(rgba(.dark, .high)[3] - 0.4) < 0.01)
    }

    /// Controls keep their frames everywhere; rows never have one.
    @Test func controlsStayFramedAndRowsNeverAre() {
        let controls: [FernletFrameRule.Piece] = [.button, .chip, .field, .stepper, .toggle, .checkbox,
                                                  .progressBar, .photo, .addPhoto]
        for piece in controls {
            #expect(FernletFrameRule.isFramed(piece, insideSection: true), "\(piece) lost its frame in a section")
            #expect(FernletFrameRule.isFramed(piece, insideSection: false))
        }
        #expect(FernletFrameRule.treatment(of: .row, insideSection: true) == .bare)
        #expect(FernletFrameRule.treatment(of: .row, insideSection: false) == .bare)
    }

    /// Inside a section, tiles and notes keep their tint without a frame; icon squares and nested
    /// cards sit bare. On their own they are framed as before.
    @Test func piecesInsideASectionLoseTheirFrames() {
        #expect(FernletFrameRule.treatment(of: .tile, insideSection: true) == .tintOnly)
        #expect(FernletFrameRule.treatment(of: .note, insideSection: true) == .tintOnly)
        #expect(FernletFrameRule.treatment(of: .iconSquare, insideSection: true) == .bare)
        #expect(FernletFrameRule.treatment(of: .section, insideSection: true) == .bare)
        for piece in [FernletFrameRule.Piece.tile, .note, .iconSquare, .section] {
            #expect(FernletFrameRule.treatment(of: piece, insideSection: false) == .framed)
        }
        // Every piece has an answer; none is left to a screen's own judgement.
        #expect(FernletFrameRule.Piece.allCases.count == 14)
    }
}
