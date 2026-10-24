//
//  CrisisSupportCard.swift
//  Fernlet
//
//  The gentle-support card: the crisis line for the device's region, with its call/text buttons.
//  Extracted from First Aid's support row so a second surface can carry the SAME card rather than a
//  copy that could drift — Settings → Safety & reporting, where a search for "crisis" lands
//  (bug confirmation 2026-10-15, safety §2b).
//

import SwiftUI
import FernletUI

/// The static gentle-support card — always visible where it is placed, never conditional, never
/// tracking anything — set apart from the content around it with a warm, goldenrod-tinted fill.
///
/// The line is chosen by ``CrisisResources`` from the device's *region*, read at render time rather
/// than cached, so travelling changes the number. A region Fernlet has no verified line for renders
/// the supportive copy with no buttons at all — never a number that does not connect there.
///
/// Shown at the foot of ``FirstAidView`` and at the top of ``SafetyReportingView``. Each host names
/// its own accessibility-identifier prefix (`firstAid.support`, `safety.support`), so a UI test can
/// tell the two placements apart; the call and text buttons append their action id (`.call`,
/// `.text`).
struct CrisisSupportCard: View {
    /// The host's accessibility-identifier prefix; each button appends `.<action id>`.
    let identifierPrefix: String

    var body: some View {
        let resource = CrisisResources.resource(for: Locale.current.region)
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                // World (b3-first-aid): the small pixel heart, decorative beside the heading.
                WorldSpriteView(sprite: WorldSprites.heartSm, scale: 2)
                    .accessibilityHidden(true)
                Text("If things feel heavy")
                    .font(FernletFramedFont.rowTitle.weight(.bold))
                    .foregroundStyle(WorldPalette.bark)
                    // T2-19: the card's heading, so a distressed user reaches the crisis line by
                    // heading navigation instead of swiping through everything above it.
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityHeading(.h2)
            }
            Text(resource.blurb)
                .font(FernletFramedFont.field)
                .foregroundStyle(WorldPalette.dim)
                .lineSpacing(2)
                .fernletWrappingText()
                .padding(.bottom, FernletMetrics.spaceXs)
            if resource.actions.isEmpty == false {
                HStack(spacing: 10) {
                    ForEach(Array(resource.actions.enumerated()), id: \.element.id) { index, action in
                        supportLink(action, filled: index == 0)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        // World (b3-first-aid): the framed card of the design language.
        .fernletFramed(WorldTheme.framedLook, fill: WorldPalette.paper, cornerRadius: FernletFramedLook.cardRadius)
    }

    /// One call/text button. The URL is already resolved by ``CrisisResources``, so there is no
    /// optional-URL branch that could silently render nothing. World: the first (Call) is the framed
    /// moss primary, the rest framed secondaries.
    private func supportLink(_ action: CrisisResourceAction, filled: Bool) -> some View {
        Link(destination: action.url) {
            HStack(spacing: 8) {
                Image(systemName: action.systemImage)
                    .font(.subheadline.weight(.semibold))
                Text(action.title)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(ActionPillButtonStyle(filled ? .primary : .secondary))
        .accessibilityIdentifier("\(identifierPrefix).\(action.id)")
    }
}
