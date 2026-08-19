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

    private var currentTag: FeelingTag? {
        store.day.journals.last?.tag
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsLabel {
                Text("How's today feeling?")
                    .font(.fernlet(.labelSmall))
                    .foregroundStyle(Color.slate)
            }
            // Wraps rather than scrolls: as a horizontal scroller only the first four chips fit and
            // the fourth ended flush with the card edge, so nothing hinted that the two HARDER
            // moods (Tired, Hard) were the ones off-screen. It also stops a horizontal drag here
            // competing with the page/scroll gestures around it.
            FlowLayout(spacing: 8) {
                ForEach(FeelingTag.allCases) { tag in
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            store.logQuickMood(tag)
                        }
                    } label: {
                        moodChipLabel(tag)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Mood: \(tag.label)")
                    .accessibilityAddTraits(currentTag == tag ? .isSelected : [])
                    .accessibilityIdentifier("quickMood.\(tag.rawValue)")
                }
            }
            .padding(.vertical, 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityHint("One tap notes how today feels. No writing needed.")
    }

    /// The chip itself — the coloured dot plus the label — shared by every tag so Home and the
    /// Journal screen keep one mood-chip treatment.
    private func moodChipLabel(_ tag: FeelingTag) -> some View {
        let isCurrent = currentTag == tag
        return HStack(spacing: 6) {
            Circle()
                .fill(tag.color)
                .frame(width: 8, height: 8)
            Text(tag.label)
                .font(.fernlet(.label))
                .lineLimit(1)
        }
        .foregroundStyle(isCurrent ? Color.parchment : Color.bark)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(isCurrent ? Color.bark : Color.cream, in: Capsule())
        .overlay(
            Capsule().stroke(Color.bark.opacity(isCurrent ? 0 : 0.12), lineWidth: 1)
        )
    }
}
