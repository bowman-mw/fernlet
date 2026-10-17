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

    private let cardRadius: CGFloat = 22
    private let pillRadius: CGFloat = 13

    // Surface-local warm hues: the card keeps every element in one amber-brown family.
    private static let headingInk = Color(light: Color(red: 0.353, green: 0.263, blue: 0.133),
                                          dark:  Color(red: 0.941, green: 0.875, blue: 0.706))
    private static let proseInk = Color(light: Color(red: 0.416, green: 0.325, blue: 0.200),
                                        dark:  Color(red: 0.796, green: 0.725, blue: 0.561))
    private static let outlineInk = Color(light: Color(red: 0.353, green: 0.263, blue: 0.133),
                                          dark:  Color(red: 0.878, green: 0.722, blue: 0.376))
    /// Secondary button outline stroke — brown @0.35 in light, goldenrod @0.4 in dark (mockup §1a).
    private static let outlineStroke = Color(light: Color(red: 0.353, green: 0.263, blue: 0.133).opacity(0.35),
                                             dark:  Color(red: 0.878, green: 0.722, blue: 0.376).opacity(0.40))
    /// On-accent ink for the filled Call button — parchment in light, near-black in dark.
    private static let filledInk = Color(light: Color(red: 0.961, green: 0.937, blue: 0.878),
                                         dark:  Color(red: 0.102, green: 0.082, blue: 0.055))

    var body: some View {
        let resource = CrisisResources.resource(for: Locale.current.region)
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                Image(systemName: "heart")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(Color.goldenrod)
                Text("If things feel heavy")
                    .font(.fernlet(.headerMedium))
                    .foregroundStyle(Self.headingInk)
                    // T2-19: the card's heading, so a distressed user reaches the crisis line by
                    // heading navigation instead of swiping through everything above it.
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityHeading(.h2)
            }
            Text(resource.blurb)
                .font(.fernlet(.body))
                .foregroundStyle(Self.proseInk)
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
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [Color.goldenrod.opacity(0.18), Color.goldenrod.opacity(0.11)],
                startPoint: .top,
                endPoint: .bottom
            ),
            in: RoundedRectangle(cornerRadius: cardRadius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: cardRadius, style: .continuous)
                .stroke(Color.goldenrod.opacity(0.32), lineWidth: 1)
        )
    }

    /// One call/text button. The URL is already resolved by ``CrisisResources``, so there is no
    /// optional-URL branch that could silently render nothing.
    private func supportLink(_ action: CrisisResourceAction, filled: Bool) -> some View {
        Link(destination: action.url) {
            HStack(spacing: 8) {
                Image(systemName: action.systemImage)
                    .font(.subheadline.weight(.semibold))
                Text(action.title)
                    .font(.fernlet(.label))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .foregroundStyle(filled ? Self.filledInk : Self.outlineInk)
            .background {
                if filled {
                    RoundedRectangle(cornerRadius: pillRadius, style: .continuous)
                        .fill(Color.moss)
                } else {
                    RoundedRectangle(cornerRadius: pillRadius, style: .continuous)
                        .stroke(Self.outlineStroke, lineWidth: 1.5)
                }
            }
        }
        .accessibilityIdentifier("\(identifierPrefix).\(action.id)")
    }
}
