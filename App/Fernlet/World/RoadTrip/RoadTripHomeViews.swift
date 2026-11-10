import FernletDomainModel
import FernletUI
import SwiftUI

/// "Road trip · 3" (`rt-home`, owner-approved 2026-11-10): the chip under the status plate while a road trip is on, in
/// the airport tag's look (DM Sans bold 15 on paper in a 3-pt ink frame with a solid shadow). VoiceOver: "Road trip
/// with Rae and Sam, button". Tapping it opens Trip info (``RoadTripInfoSheet``). It draws nothing with no trip on, so
/// the stack it sits in keeps its spacing, and none in a decoy (the keeper shows none).
struct RoadTripChip: View {
    let store: FernletStore
    @State private var showsInfo = false

    var body: some View {
        if let trip = store.worldFog.roadTrip.active {
            Button { showsInfo = true } label: { label(members: trip.members.count) }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: RoadTripCopy.spokenChip(others: trip.others.map(\.firstName))))
                .accessibilityInputLabels([Text(RoadTripCopy.title)])
                .accessibilityIdentifier("roadTrip.chip")
                .sheet(isPresented: $showsInfo) {
                    RoadTripInfoSheet(store: store) { showsInfo = false }
                }
        }
    }

    /// The framed chip, its tap area at least 44 pt tall.
    private func label(members: Int) -> some View {
        Text(RoadTripCopy.chip(members: members))
            .font(Font.custom(FernletFontName.dmSansBold, size: 15, relativeTo: .subheadline))
            .dynamicTypeSize(...DynamicTypeSize.accessibility2)
            .foregroundStyle(WorldPalette.bark)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(WorldPalette.paper, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(WorldPalette.ink, lineWidth: 3))
            .background { RoundedRectangle(cornerRadius: 8).fill(WorldPalette.ink.opacity(0.35)).offset(y: 3) }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
    }
}

/// Trip info (`rt-info`, owner-approved 2026-11-10): titled with the trip's name, the rows "Mapping: Mike's iPhone ·
/// Last caught up 2:14 pm · 84 km · 6 photos", and the buttons Catch up now, Map from this iPhone, Leave the road trip
/// and End the road trip, in Hangout info's framed look.
///
/// PR 1 is local: Catch up now waits for the swap (PR 2) and stays disabled; Map from this iPhone (shown while another
/// iPhone maps) makes this one the mapper; Leave and End, each after a confirmation, end the trip on this iPhone, and
/// the chip and this sheet go. The rows are read once the sheet opens and after each change (the length reads the
/// line's earlier pieces once).
struct RoadTripInfoSheet: View {
    let store: FernletStore
    let onClose: () -> Void
    @State private var info: RoadTripInfo?
    @State private var asksLeave = false
    @State private var asksEnd = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let info { rows(info) }
                buttons
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.bottom, 28)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            SheetHeader(title: Text(verbatim: info?.title ?? AddressedCopy.plain(RoadTripCopy.title)), onDone: onClose)
        }
        .fernletSheet()
        .confirmDestructive(AddressedCopy.plain(RoadTripCopy.leaveTitle), isPresented: $asksLeave,
                            message: AddressedCopy.plain(RoadTripCopy.leaveMessage),
                            confirmLabel: AddressedCopy.plain(RoadTripCopy.leave)) { finish(store.leaveRoadTrip()) }
        .confirmDestructive(AddressedCopy.plain(RoadTripCopy.endTitle), isPresented: $asksEnd,
                            message: AddressedCopy.plain(RoadTripCopy.endMessage),
                            confirmLabel: AddressedCopy.plain(RoadTripCopy.end)) { finish(store.endRoadTrip()) }
        .task { info = store.roadTripInfo() }
        .accessibilityIdentifier("roadTrip.info")
    }

    /// The four rows, in one framed section.
    private func rows(_ info: RoadTripInfo) -> some View {
        FernletFramedSection(header: nil) {
            if let name = info.mapperName {
                FernletRowLabel(title: Text(RoadTripCopy.mapping(name)))
            }
            FernletRowLabel(title: Text(RoadTripCopy.caughtUp(RoadTripCopy.caughtUpTime(info.lastCatchUp, now: Date()))))
            FernletRowLabel(title: Text(verbatim: RoadTripCopy.distance(info.metres)))
            FernletRowLabel(title: Text(RoadTripCopy.photos(info.photos)))
        }
    }

    /// Catch up now (disabled until the swap, PR 2), Map from this iPhone while another iPhone maps, Leave and End.
    private var buttons: some View {
        VStack(spacing: 10) {
            Button {} label: { Text(RoadTripCopy.catchUpNow).frame(maxWidth: .infinity) }
                .buttonStyle(ActionPillButtonStyle(.primary))
                .disabled(true)
                .accessibilityIdentifier("roadTrip.catchUp")
            if info?.isMapping == false {
                Button { mapFromHere() } label: { Text(RoadTripCopy.mapFromHere).frame(maxWidth: .infinity) }
                    .buttonStyle(ActionPillButtonStyle(.secondary))
                    .accessibilityIdentifier("roadTrip.mapFromHere")
            }
            Button { asksLeave = true } label: { Text(RoadTripCopy.leave).frame(maxWidth: .infinity) }
                .buttonStyle(ActionPillButtonStyle(.destructive))
                .accessibilityIdentifier("roadTrip.leave")
            Button { asksEnd = true } label: { Text(RoadTripCopy.end).frame(maxWidth: .infinity) }
                .buttonStyle(ActionPillButtonStyle(.destructive))
                .accessibilityIdentifier("roadTrip.end")
        }
        .padding(.top, 4)
    }

    /// Map from this iPhone: this one maps, and the rows say so.
    private func mapFromHere() {
        FernletFeedback.system.play(store.mapRoadTripFromThisPhone() ? .done : .failed)
        info = store.roadTripInfo()
    }

    /// Leave or End answered: the sheet closes when it went (the chip goes with the trip).
    private func finish(_ done: Bool) {
        FernletFeedback.system.play(done ? .done : .failed)
        if done { onClose() }
    }
}

/// What Trip info's rows say, read once from the store (`FernletStore.roadTripInfo(now:)`).
nonisolated struct RoadTripInfo: Equatable, Sendable {
    /// The trip's name (the person's own, or "Road trip" and the day).
    let title: String
    /// The first name of the member whose iPhone maps; nil if they are not on the trip.
    let mapperName: String?
    /// When this iPhone last caught up.
    let lastCatchUp: Date
    /// The road so far on this iPhone, in metres.
    let metres: Double
    /// The trip photos so far (the trip roll is PR 3: none until then).
    let photos: Int
    /// Whether this iPhone maps.
    let isMapping: Bool
}
