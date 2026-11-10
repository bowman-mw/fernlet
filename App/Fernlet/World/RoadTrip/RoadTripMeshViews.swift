import FernletDomainModel
import FernletFoundation
import FernletSocial
import FernletUI
import ProximityKit
import SwiftUI

/// "Road trip with Rae and Sam" (`rt-start`, owner-approved 2026-11-10): the framed dialog Start a road trip opens over
/// the map, with the approved line, the optional name ("Road trip" as its placeholder; the default is "Road trip" and
/// the date) and **Start the road trip** · **Not now**. Starting begins the trip on this iPhone and asks each friend
/// in the hangout to join on their own phone.
struct RoadTripStartDialog: View {
    let store: FernletStore
    /// The friends it would invite (``FernletStore/roadTripStartCandidates()`` when the menu was opened).
    let members: [RoadTripMember]
    let onClose: () -> Void
    @State private var name = ""

    var body: some View {
        RoadTripDialogFrame(onCancel: onClose) {
            Text(RoadTripCopy.with(RoadTripCopy.names(members.map(\.firstName))))
                .font(FernletFramedFont.sheetTitle)
                .foregroundStyle(WorldPalette.bark)
                .accessibilityAddTraits(.isHeader)
            Text(RoadTripCopy.startLine)
                .font(FernletFramedFont.body)
                .foregroundStyle(WorldPalette.dim)
            TextField(text: Binding(get: { name }, set: { name = String($0.prefix(RoadTrip.maxNameLength)) }),
                      prompt: .fieldPrompt(verbatim: AddressedCopy.plain(RoadTripCopy.title))) {
                Text(RoadTripCopy.title)
            }
            .sheetTextInput()
            .accessibilityIdentifier("roadTrip.start.name")
            Button(action: start) { Text(RoadTripCopy.startButton).frame(maxWidth: .infinity) }
                .buttonStyle(ActionPillButtonStyle(.primary))
                .accessibilityIdentifier("roadTrip.start.go")
            Button(action: onClose) { Text(RoadTripCopy.notNow).frame(maxWidth: .infinity) }
                .buttonStyle(ActionPillButtonStyle(.secondary))
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("roadTrip.start.notNow")
        }
        .accessibilityIdentifier("roadTrip.start")
    }

    /// Start the road trip: it begins here and the invites go; the dialog closes either way, saying how it went.
    private func start() {
        let started = store.startRoadTrip(name: name, members: members)
        FernletFeedback.system.play(started ? .done : .failed)
        onClose()
    }
}

/// "Mike started a road trip" (`rt-join`, owner-approved 2026-11-10): the framed dialog each friend's phone shows,
/// with the approved line naming the trip's other people and **Join** · **Not this time** ("no means the hangout stays
/// as it was"). Either answer goes back to the people on the trip.
struct RoadTripJoinDialog: View {
    let store: FernletStore
    let pending: RoadTripPendingInvite
    let onClose: () -> Void

    var body: some View {
        RoadTripDialogFrame(onCancel: { answer(false) }) {
            Text(RoadTripCopy.joinTitle(starterName))
                .font(FernletFramedFont.sheetTitle)
                .foregroundStyle(WorldPalette.bark)
                .accessibilityAddTraits(.isHeader)
            Text(RoadTripCopy.joinLine(RoadTripCopy.names(otherNames)))
                .font(FernletFramedFont.body)
                .foregroundStyle(WorldPalette.dim)
            Button { answer(true) } label: { Text(RoadTripCopy.join).frame(maxWidth: .infinity) }
                .buttonStyle(ActionPillButtonStyle(.primary))
                .accessibilityIdentifier("roadTrip.join.yes")
            Button { answer(false) } label: { Text(RoadTripCopy.notThisTime).frame(maxWidth: .infinity) }
                .buttonStyle(ActionPillButtonStyle(.secondary))
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("roadTrip.join.no")
        }
        .accessibilityIdentifier("roadTrip.join")
    }

    /// The starter's first name, as the invite gives it.
    private var starterName: String {
        pending.invite.members.first { $0.id == pending.invite.starterID }?.firstName ?? ""
    }

    /// Everyone else on the trip, this iPhone left out: the starter first.
    private var otherNames: [String] {
        let selfID = store.roadTripSelfID
        let others = pending.invite.members.filter { $0.id != selfID }
        return (others.filter { $0.id == pending.invite.starterID } + others.filter { $0.id != pending.invite.starterID }).map(\.firstName)
    }

    /// Join or Not this time, answered once.
    private func answer(_ join: Bool) {
        let answered = store.answerRoadTripInvite(join: join)
        FernletFeedback.system.play(answered ? (join ? .done : .tick) : .failed)
        onClose()
    }
}

/// The paper dialog over a dim that Start and Join share, as "End hangout?" is drawn (`b3-leave`).
struct RoadTripDialogFrame<Content: View>: View {
    let onCancel: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        ZStack {
            Color.black.opacity(0.32)
                .ignoresSafeArea()
                .accessibilityHidden(true)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) { content() }
                    .fernletWrappingText()
                    .padding(22)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxWidth: 400)
            .fixedSize(horizontal: false, vertical: true)
            .background(WorldPalette.paper, in: shape)
            .overlay(shape.strokeBorder(WorldPalette.ink, lineWidth: 3))
            .background { shape.fill(WorldPalette.ink.opacity(0.25)).offset(y: 4) }
            .padding(.horizontal, 24)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
        }
        .accessibilityAction(.escape, onCancel)
    }
}

/// Home's road trip notes (`rt-catchup`, owner-approved 2026-11-10), under the trip's chip: "Rae is here. Catch up the
/// road trip?" with **Catch up**, asked once while a member presence hears nearby stays near, with Fernlet open and Home
/// in front (never a notification); and after a swap, "Caught up: 84 km of road, 6 photos." for four seconds, or the
/// assistive window, also said to VoiceOver. Draws nothing otherwise (so the column it sits in keeps its spacing), and
/// nothing in a decoy. Who it asks about is re-decided by ``RoadTripQuestionRefresh`` on the column.
struct RoadTripHomeNotes: View {
    let store: FernletStore

    var body: some View {
        let state = store.roadTripMesh
        if !store.duressSessionActive, state.question != nil || state.caughtUp != nil {
            VStack(alignment: .leading, spacing: 8) {
                if let member = state.question, let name = store.roadTripMemberName(member) {
                    RoadTripCatchUpQuestion(name: name, onCatchUp: { catchUp(member) }, onClose: state.clearQuestion)
                }
                if let note = state.caughtUp {
                    WorldLoggedNote(line: Text(verbatim: RoadTripCopy.caughtUpLine(note)), identifier: .roadTripCaughtUp, onUndo: nil)
                        .task(id: note.id) { await hold(note) }
                }
            }
            .transition(.opacity)
        }
    }

    /// Catch up: the short hangout begins (the note goes), or the failure is felt.
    private func catchUp(_ member: String) {
        store.roadTripMesh.clearQuestion()
        FernletFeedback.system.play(store.catchUpRoadTrip(with: member) ? .tick : .failed)
    }

    /// Says the note, holds it for its window, then lets it go.
    private func hold(_ note: RoadTripCaughtUpNote) async {
        FernletAnnouncer.system.announce(.status, resolved: RoadTripCopy.caughtUpLine(note))
        let window = FernletDismissalWindow.system.window(standard: .seconds(4), assistive: FernletDismissalWindow.assistiveActionWindow)
        do {
            try await Task.sleep(for: window)
        } catch {
            return
        }
        store.roadTripMesh.clearCaughtUp(note.id)
    }
}

/// Re-decides who Home's catch-up note asks about (`rt-catchup`, ask once) whenever what it reads moves: Home coming
/// to the front or leaving it, presence hearing a kept friend arrive or go, and a hangout starting or ending.
struct RoadTripQuestionRefresh: ViewModifier {
    let store: FernletStore
    /// Home in front of an active app.
    let isFrontmost: Bool

    func body(content: Content) -> some View {
        content
            .animation(.easeOut(duration: 0.18), value: store.roadTripMesh.question)
            .animation(.easeOut(duration: 0.18), value: store.roadTripMesh.caughtUp)
            .onAppear(perform: refresh)
            .onChange(of: isFrontmost) { _, _ in refresh() }
            .onChange(of: store.presenceManager.nearbyFriendFingerprints) { _, _ in refresh() }
            .onChange(of: store.meshNetworkManager.isInSession) { _, _ in refresh() }
    }

    /// Asks the store who to ask about now.
    private func refresh() {
        store.refreshRoadTripQuestion(isFrontmost: isFrontmost)
    }
}

/// "Rae is here. Catch up the road trip?" with **Catch up** and a framed close, in the car question's paper note.
struct RoadTripCatchUpQuestion: View {
    let name: String
    let onCatchUp: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(RoadTripCopy.catchUpQuestion(name))
                .font(Font.custom(FernletFontName.dmSansBold, size: 15, relativeTo: .subheadline))
                .foregroundStyle(WorldPalette.bark)
                .fernletWrappingText()
            Spacer(minLength: 4)
            Button(action: onCatchUp) {
                Text(RoadTripCopy.catchUp)
                    .font(Font.custom(FernletFontName.dmSansBold, size: 14, relativeTo: .subheadline))
                    .foregroundStyle(WorldPalette.paperLight)
                    .padding(.horizontal, 14)
                    .frame(minWidth: 44, minHeight: 44)
                    .background(WorldPalette.ink, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("roadTrip.catchUp.go")
            FernletCloseButton(action: onClose)
        }
        .padding(12)
        .frame(maxWidth: 360, alignment: .leading)
        .background(WorldPalette.paperLight, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(WorldPalette.ink, lineWidth: 2))
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("roadTrip.catchUp.note")
    }
}
