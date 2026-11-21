import FernletFoundation
import FernletUI
import SwiftUI

/// One line of the tracker diary as the screen shows it: when, what happened in words, and a second line for a
/// minute's readings. Plain values, so tests can read them.
nonisolated struct TrackerDiaryRow: Identifiable, Equatable, Sendable {
    /// Its place in the list (0 is the newest).
    let id: Int
    let at: Date
    let title: LocalizedStringResource
    /// A minute's readings by accuracy; nil for any other line.
    let detail: LocalizedStringResource?

    static func == (lhs: TrackerDiaryRow, rhs: TrackerDiaryRow) -> Bool {
        lhs.id == rhs.id && lhs.at == rhs.at && lhs.title.key == rhs.title.key && lhs.detail?.key == rhs.detail?.key
    }

    /// The rows for `events` (oldest first, as the diary keeps them), newest first.
    static func rows(from events: [WorldDiaryEvent]) -> [TrackerDiaryRow] {
        events.suffix(WorldDiaryLog.maxEvents).reversed().enumerated().map { index, event in
            TrackerDiaryRow(id: index, at: event.at, title: TrackerDiaryCopy.title(event), detail: TrackerDiaryCopy.detail(event))
        }
    }
}

/// Settings → Home map's tracker diary rows (owner 2026-11-21): the switch, off by default, and, while it is on, the
/// row that opens the diary. Turning it off forgets the diary at once. The wording is a draft for the owner.
struct TrackerDiarySection: View {
    @Bindable var store: FernletStore
    @State private var isOn = WorldMapPreferences.trackerDiary()

    var body: some View {
        FernletFramedSection("Tracker diary") {
            Toggle(isOn: $isOn) {
                FernletRowLabel("Keep a tracker diary", detail: "48 hours of what background mapping did, on this iPhone. No places.")
                    .padding(.vertical, 7)
            }
            .onChange(of: isOn) { _, on in set(on) }
            .accessibilityIdentifier("settings.homeMap.trackerDiary")
            if isOn {
                NavigationLink {
                    TrackerDiaryView(store: store)
                } label: {
                    FernletRowLabel("View the diary")
                }
                .buttonStyle(FernletRowButtonStyle(showsChevron: true))
                .accessibilityIdentifier("settings.homeMap.trackerDiary.view")
            }
        }
    }

    /// Sets the switch; off forgets every line, in memory and on disk (never in a decoy, whose real diary stays).
    private func set(_ on: Bool) {
        WorldMapPreferences.setTrackerDiary(on)
        guard !on, !store.duressSessionActive else { return }
        store.worldLocation.diary.forget()
    }
}

/// The tracker diary's page: what it is, then its lines, newest first. A decoy session sees none.
struct TrackerDiaryView: View {
    @Bindable var store: FernletStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                FernletScrollSection("What this is") {
                    VStack(alignment: .leading, spacing: 8) {
                        note("What Fernlet's background mapping did over the last 48 hours, newest first.")
                        note("Times and counts only. No place is ever written here.")
                        note("It stays on this iPhone, encrypted with your map. Delete map history erases it, and so does turning the diary off.")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                lines
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 30)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        .fernletPageBackground()
        .fernletPushedPage("Tracker diary")
        .task { store.worldLocation.diary.refresh() }
        .accessibilityIdentifier("screen.settings.trackerDiary")
    }

    private var rows: [TrackerDiaryRow] {
        store.duressSessionActive ? [] : TrackerDiaryRow.rows(from: store.worldLocation.diary.events)
    }

    @ViewBuilder
    private var lines: some View {
        let rows = rows
        if rows.isEmpty {
            FernletCard { EmptyState(text: "Nothing yet. Lines appear as background mapping works.") }
                .accessibilityIdentifier("trackerDiary.empty")
        } else {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(rows) { row in
                    FernletCard {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(row.at.formatted(.dateTime.month(.abbreviated).day().hour().minute().second()))
                                .font(.fernlet(.labelSmall))
                                .foregroundStyle(Color.slate)
                            Text(row.title)
                                .font(.fernlet(.label))
                                .foregroundStyle(Color.bark)
                                .fernletWrappingText()
                            if let detail = row.detail { line(detail) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func note(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.fernlet(.bodySmall))
            .foregroundStyle(Color.slate)
            .fernletWrappingText()
    }

    private func line(_ text: LocalizedStringResource) -> some View {
        Text(text)
            .font(.fernlet(.bodySmall))
            .foregroundStyle(Color.slate)
            .fernletWrappingText()
    }
}
