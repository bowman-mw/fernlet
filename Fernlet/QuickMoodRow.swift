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
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(FeelingTag.allCases) { tag in
                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                store.logQuickMood(tag)
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(tag.color)
                                    .frame(width: 8, height: 8)
                                Text(tag.label)
                                    .font(.fernlet(.label))
                            }
                            .foregroundStyle(currentTag == tag ? Color.parchment : Color.bark)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(
                                currentTag == tag ? Color.bark : Color.cream,
                                in: Capsule()
                            )
                            .overlay(
                                Capsule().stroke(Color.bark.opacity(currentTag == tag ? 0 : 0.12), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Mood: \(tag.label)")
                        .accessibilityAddTraits(currentTag == tag ? .isSelected : [])
                        .accessibilityIdentifier("quickMood.\(tag.rawValue)")
                    }
                }
                .padding(.vertical, 1)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityHint("One tap notes how today feels. No writing needed.")
    }
}
