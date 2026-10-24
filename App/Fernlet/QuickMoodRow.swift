//
//  QuickMoodRow.swift
//  Fernlet
//
//  The one-tap mood check-in: a single row of FeelingTag chips (quick-log affordance styling)
//  shared by Home and the Journal screen. A tap records a tag-only journal entry via
//  `FernletStore.logQuickMood` — no text required, ever — and re-tapping updates today's check-in
//  in place. The highlighted chip mirrors today's LAST entry's tag, which is exactly what scoring,
//  the calendar tint, and the ambient thought read, so the row always shows the mood the rest of
//  the app is acting on.
//

import SwiftUI
import FernletDomainModel
import FernletUI

/// The one-tap mood check-in row: a horizontal strip of `FeelingTag` chips shared by Home and
/// the Journal screen.
///
/// A tap records a tag-only journal entry via `FernletStore.logQuickMood` — no text required —
/// and re-tapping updates today's check-in in place. The highlighted chip mirrors today's LAST
/// entry's tag, which is exactly what scoring, the calendar tint, and the ambient thought read,
/// so the row always shows the mood the rest of the app is acting on.
struct QuickMoodRow: View {
    var store: FernletStore
    /// Optional header (Home shows one inside the quick-log card; the Journal screen provides its
    /// own section styling).
    var showsLabel = true
    /// The user's term of address, which the Quiet and Tired chips agree with (in what they draw,
    /// what VoiceOver says and what Voice Control answers to).
    @Environment(\.fernletTermOfAddress) private var termOfAddress
    /// The World look (set at the app root): framed chips with ink-ringed feeling dots.
    @Environment(\.fernletFramedLook) private var look

    private var currentTag: FeelingTag? {
        store.day.journals.last?.tag
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsLabel {
                Text("How's today feeling?")
                    .font(look != nil ? FernletFramedFont.field : .fernlet(.labelSmall))
                    .foregroundStyle(look?.dim ?? Color.slate)
            }
            // Wraps rather than scrolls: as a horizontal scroller only the first four chips fit and
            // the fourth ended flush with the card edge, so nothing hinted that the two HARDER
            // moods (Tired, Hard) were the ones off-screen. It also stops a horizontal drag here
            // competing with the page/scroll gestures around it.
            FlowLayout(spacing: 8) {
                ForEach(FeelingTag.allCases) { tag in
                    let isCurrent = currentTag == tag
                    Button {
                        let before = (count: store.day.journals.count, tag: store.day.journals.last?.tag)
                        withAnimation(.easeInOut(duration: 0.18)) {
                            store.logQuickMood(tag)
                        }
                        // Spoken only when the store actually wrote: re-tapping today's check-in is
                        // a no-op there, and an announcement for it would claim a log that did not
                        // happen. A new entry or a re-tag is a write.
                        let after = (count: store.day.journals.count, tag: store.day.journals.last?.tag)
                        if after != before {
                            // A9: felt at once, while the announcement waits for its moment.
                            FernletFeedback.system.play(.logged)
                            TaskConfirmation.moodLogged.announce()
                        }
                    } label: {
                        moodChipLabel(tag)
                    }
                    // T1-9: adopts the app's one chip treatment instead of hand-rolling a second —
                    // same fill/ink pair as every other chip, and the `.isSelected` trait now comes
                    // from the style itself rather than a second, easy-to-drift call-site line.
                    .buttonStyle(ChipButtonStyle(selected: isCurrent))
                    .accessibilityLabel("Mood: \(tag.label(addressing: termOfAddress))")
                    // On each chip, not the row: a hint on a `.contain` container is attached to
                    // no element VoiceOver lands on, so it was never spoken.
                    .accessibilityHint("One tap notes how today feels. No writing needed.")
                    // Voice Control: the chip draws only the feeling's name, so "Tap Bright" has to
                    // work on its own; "Mood Bright" keeps the label's own form sayable too.
                    .accessibilityInputLabels([Text(verbatim: tag.label(addressing: termOfAddress)), Text("Mood \(tag.label(addressing: termOfAddress))")])
                    .accessibilityIdentifier("quickMood.\(tag.rawValue)")
                }
            }
            .padding(.vertical, 1)
        }
        .accessibilityElement(children: .contain)
    }

    /// The chip's own content — the coloured dot plus the label — shared by every tag so Home and
    /// the Journal screen keep one mood-chip treatment. Shape, fill, ink and the selected trait all
    /// come from ``ChipButtonStyle`` now; this is content only.
    private func moodChipLabel(_ tag: FeelingTag) -> some View {
        HStack(spacing: look != nil ? 7 : 6) {
            // World (b2-journal, b2-log): the feeling's colour in an ink-ringed dot, as drawn.
            Circle()
                .fill(tag.color)
                .frame(width: look != nil ? 14 : 8, height: look != nil ? 14 : 8)
                .overlay { if let look { Circle().strokeBorder(look.ink, lineWidth: 2) } }
            Text(tag.label(addressing: termOfAddress))
                .font(look != nil ? FernletFramedFont.fieldBold : .fernlet(.label))
                .lineLimit(1)
        }
    }
}
