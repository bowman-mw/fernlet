import SwiftUI

/// Private: locked until you open it. Inside, "Where you've been" (the 30-day timeline and the
/// places you return to, sealed like the journal) beside Cycle, Journal and Progress photos.
/// A decoy session unlocks it without the key, so everything inside shows empty.
struct PrivatePanel: View {
    let model: WorldShellModel

    var body: some View {
        if !model.privateUnlocked {
            VStack(spacing: 8) {
                Image(systemName: "lock").font(.system(size: 34)).foregroundStyle(FernColors.moss)
                Text("Private").font(.headline)
                Text("Cycle, journal, photos, and where you've been.").font(.caption).foregroundStyle(FernColors.dim)
                PillButton(title: "Open Private") { model.privateUnlocked = true }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 50)
        } else if model.decoy {
            emptyCard("Cycle")
            emptyCard("Journal")
            emptyCard("Where you've been")
        } else {
            timelineCard
            placesCard
            ShellCard {
                LinkRow(title: "The last 30 days") { model.showToast("The 30-day timeline opens here.") }
                LinkRow(title: "Delete a day") { model.showToast("Deleting a day is a confirmation sheet in the app. Nothing is stored here.") }
                LinkRow(title: "Delete all of it") { model.showToast("Deleting all map history is a confirmation sheet in the app.") }
            }
            ShellCard {
                Text("Sealed like your journal. A decoy session shows nothing here.").font(.caption).foregroundStyle(FernColors.dim)
            }
            ShellCard {
                LinkRow(title: "Cycle") { model.showToast("Cycle opens here, as today.") }
                LinkRow(title: "Journal") { model.showToast("The journal opens here, as today.") }
                LinkRow(title: "Progress photos") { model.showToast("Progress photos open here, as today.") }
            }
        }
    }

    /// Today in the 30-day timeline (While Using: only walks and places you opened Fernlet).
    private var timelineCard: some View {
        let rows: [(String, String, String)] = [("12:10", "Hoshi Noodle Bar", "you logged lunch here"),
                                                ("17:30", "Oak Park", "walk · \(QuickStart.trailKilometres) km")]
        return ShellCard {
            HStack {
                Text("Where you've been").font(.subheadline.weight(.semibold))
                Spacer()
                Text("Thursday · kept 30 days").font(.caption).foregroundStyle(FernColors.dim)
            }
            ForEach(rows, id: \.0) { row in
                Divider()
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(row.0).font(.caption.monospacedDigit().weight(.semibold)).foregroundStyle(FernColors.dim).frame(width: 40, alignment: .leading)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(row.1).font(.footnote)
                        Text(row.2).font(.caption).foregroundStyle(FernColors.dim)
                    }
                }
            }
            RouteMini(route: RecordedRoutes.parkLoop)
            Text("Walks, runs and places you opened Fernlet. Turn on background mapping for the whole day.")
                .font(.caption2).foregroundStyle(FernColors.dim)
        }
    }

    /// Places you return to: a visit count only, no dates, allowed categories only.
    private var placesCard: some View {
        let places = [FixtureSpot.noodle, .gym, .trail].filter { model.level.visits(to: $0) > 0 }
        return ShellCard {
            HStack {
                Text("Places you return to").font(.subheadline.weight(.semibold))
                Spacer()
                Text("a count, no dates").font(.caption).foregroundStyle(FernColors.dim)
            }
            if places.isEmpty { Text("None yet.").font(.caption).foregroundStyle(FernColors.dim) }
            ForEach(places) { place in
                HStack {
                    Text(place == .trail ? "Oak Park" : place.label).font(.footnote.weight(.semibold))
                    Spacer()
                    Text("\(model.level.visits(to: place)) visits").font(.caption).foregroundStyle(FernColors.dim)
                }
            }
        }
    }

    private func emptyCard(_ title: String) -> some View {
        ShellCard {
            CardLabel(text: title)
            Text("Nothing here yet.").font(.caption).foregroundStyle(FernColors.dim)
        }
    }
}
