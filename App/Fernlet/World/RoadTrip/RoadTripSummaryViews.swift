import FernletDomainModel
import FernletFoundation
import FernletUI
import SwiftUI

/// What Home's summary card shows for one trip (`FernletStore.roadTripSummaryCard`): the trip, its title (the person's
/// name for it, or "Road trip" and the day) and its numbers.
nonisolated struct RoadTripSummaryCard: Equatable, Identifiable, Sendable {
    /// The trip's id.
    let id: UUID
    /// The trip's name.
    let title: String
    /// Its numbers, worked out at its end.
    let summary: RoadTripSummary

    /// The approved one-line form, which VoiceOver reads for the card.
    var spoken: String { RoadTripCopy.summarySpoken(title: title, summary) }
}

/// The road trip's summary card (`rt-end`, owner-approved 2026-11-10; the review page's mockup): the trip's name as
/// its title, then "3 days" and "412 km", then three labelled rows ("New tiles 1,280", "Towns passed 4", "Photos 23")
/// and **Done**, in the Start and Join dialogs' paper frame over the map. A row whose number isn't known (the tiles
/// when the map couldn't be read at the start, the towns without the atlas) is left out. VoiceOver reads the card as
/// the one line "Road trip to the coast · 3 days · 412 km · 1,280 new tiles · 4 towns · 23 photos"; Voice Control
/// takes "Done". It wraps and scrolls at the largest text sizes, the label over its number there.
struct RoadTripSummaryDialog: View {
    let card: RoadTripSummaryCard
    let onDone: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        RoadTripDialogFrame(onCancel: onDone) {
            VStack(alignment: .leading, spacing: 10) {
                Text(verbatim: card.title)
                    .font(FernletFramedFont.sheetTitle)
                    .foregroundStyle(WorldPalette.bark)
                row(Text(RoadTripCopy.summaryDays(card.summary.days)), value: RoadTripCopy.distance(card.summary.metres))
                if let tiles = card.summary.newTiles {
                    row(Text(RoadTripCopy.summaryNewTiles), value: RoadTripCopy.grouped(tiles))
                }
                if let towns = card.summary.towns {
                    row(Text(RoadTripCopy.summaryTowns), value: RoadTripCopy.grouped(towns))
                }
                row(Text(RoadTripCopy.summaryPhotos), value: RoadTripCopy.grouped(card.summary.photos), last: true)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: card.spoken))
            .accessibilityIdentifier("roadTrip.summary.numbers")
            Button(action: onDone) { Text(RoadTripCopy.summaryDone).frame(maxWidth: .infinity) }
                .buttonStyle(ActionPillButtonStyle(.primary))
                .keyboardShortcut(.defaultAction)
                .accessibilityInputLabels([Text(RoadTripCopy.summaryDone)])
                .accessibilityIdentifier("roadTrip.summary.done")
        }
        .accessibilityIdentifier("roadTrip.summary")
    }

    /// One labelled row, its number at the trailing edge (under its label at the largest sizes), a hairline under all
    /// but the last.
    private func row(_ label: Text, value: String, last: Bool = false) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2)) : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
        return layout {
            label.font(FernletFramedFont.rowTitle).foregroundStyle(WorldPalette.bark)
            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 8) }
            Text(verbatim: value)
                .font(Font.custom(FernletFontName.dmSansBold, size: 16.5, relativeTo: .body))
                .monospacedDigit()
                .foregroundStyle(WorldPalette.bark)
        }
        .padding(.bottom, 6)
        .overlay(alignment: .bottom) { if !last { WorldPalette.rule.frame(height: 1) } }
    }
}

/// Home's road trip end (`rt-end`): the checks that end a trip and work out its numbers, run when Home appears, comes
/// back to the front, a trip stops being on, and a catch-up's photos have settled
/// (``FernletStore/refreshRoadTripEnd(now:)``), and the summary card shown once, while Home is in front, over the map,
/// a moment after what covered Home has gone (Trip info closing after End). Done closes it for good. Nothing in a
/// decoy (the store hands out no card).
struct RoadTripSummaryPresenter: ViewModifier {
    /// The pause before the card shows, so a sheet closing over Home (Trip info's End) is gone first.
    static let settle: Duration = .milliseconds(600)

    let store: FernletStore
    /// Home in front of an active app.
    let isFrontmost: Bool
    @State private var shown: RoadTripSummaryCard?

    func body(content: Content) -> some View {
        content
            .onAppear(perform: refresh)
            .onChange(of: isFrontmost) { _, _ in refresh() }
            .onChange(of: store.worldFog.roadTrip.active?.id) { _, _ in refresh() }
            .onChange(of: store.roadTripMesh.caughtUp?.id) { _, _ in refresh() }
            .task(id: isFrontmost ? store.roadTripSummaryCard?.id : nil) { await present() }
            // A decoy beginning or a wipe takes the card away at once (the store hands out none then).
            .onChange(of: store.roadTripSummaryCard?.id) { _, id in if id != shown?.id { shown = nil } }
            .fullScreenCover(item: $shown) { card in
                RoadTripSummaryDialog(card: card) { done(card) }
                    .presentationBackground(.clear)
            }
    }

    /// Ends a quiet trip and works out what is owed, while Home is in front.
    private func refresh() {
        guard isFrontmost else { return }
        store.refreshRoadTripEnd()
    }

    /// Shows the card due now, after ``settle``, if it is still due then.
    private func present() async {
        guard isFrontmost, shown == nil, let card = store.roadTripSummaryCard else { return }
        do {
            try await Task.sleep(for: Self.settle)
        } catch {
            return   // cancelled: Home went behind, or the card changed
        }
        guard isFrontmost, store.roadTripSummaryCard?.id == card.id else { return }
        shown = card
    }

    /// Done: the card has shown and won't again.
    private func done(_ card: RoadTripSummaryCard) {
        let marked = store.markRoadTripSummaryShown(card.id)
        FernletFeedback.system.play(marked ? .tick : .failed)
        if !marked { FernletAuditLog.log("worldMap.roadTrip.summaryShownUnsaved") }
        shown = nil
    }
}
