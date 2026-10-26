import SwiftUI
import UIKit
import FernletDomainModel
import FernletFoundation
import ProximityKit
import FernletConnections
import FernletSocial
import AppServices
import FernletUI
import FernletProximityUI

/// The session on Home (`b3-home-session` draft 2, `b3-session-menu`, `b3-leave`; owner 2026-10-24):
/// no session bar — a green session button sits bottom left, the mirror of the blue button, with a
/// badge for how many friends are here. It opens a card with Messages, Session info and Leave session;
/// Leave asks "End session?" in a framed dialog over the map, and a session with photos then shows the
/// app-wide photo review (``SessionPhotoReviewCoordinator``) as it always has.
///
/// It is the session's host while the map is in front: Session info and Messages present from here,
/// the session's prompts (join requests, the session alert, removal requests) ride it while
/// `isFrontmost` (``SessionPromptsModifier``), and an inbound message is felt here (a soft knock while
/// active, a best-effort notification while not) — the camera and the Friends panel host the same
/// prompts while they are the surface on screen. Draws nothing outside a session.
///
/// Layout: it fills the frame it is given and anchors the button to that frame's bottom-left corner;
/// the shell lays it over the map so the button sits beside the item bar's left end, level with the
/// blue button on the right (lane HOME's insertion).
struct WorldSessionButton: View {
    var store: FernletStore
    /// Whether the map is what the person sees (no panel, sheet or the blue button's camera over it).
    let isFrontmost: Bool

    @State private var menuOpen = false
    @State private var showInfo = false
    @State private var showChat = false
    @State private var leaveConfirm = false
    /// Session info's End session closed the sheet; ask "End session?" once it has gone.
    @State private var endAfterInfo = false
    @State private var activeRemovalProposal: MeshRemovalProposalPayload?
    /// At most one in-flight session-message notification post (R3: the trigger is peer-driven).
    @State private var messageNotificationTask: Task<Void, Never>?
    @Environment(\.scenePhase) private var scenePhase

    private var manager: MeshNetworkManager { store.meshNetworkManager }
    private var features: FernletMeshFeatures { store.meshFeatures }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if manager.isInSession {
                if menuOpen { menuLayer }
                sessionButton
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .animation(.easeOut(duration: 0.18), value: menuOpen)
        .sheet(isPresented: $showInfo, onDismiss: askToEndIfInfoEnded) {
            SessionInfoSheet(store: store, onEndSession: {
                endAfterInfo = true
                showInfo = false
            }, onDone: { showInfo = false })
        }
        .sheet(isPresented: $showChat) {
            SessionChatPanel(chat: features.chat, onReport: { store.reportSessionPeer($0, reason: $1) },
                             onDone: { showChat = false })
        }
        .fullScreenCover(isPresented: $leaveConfirm) {
            SessionLeaveDialog(onEnd: endSession, onCancel: { leaveConfirm = false })
                .presentationBackground(.clear)
        }
        .modifier(SessionPromptsModifier(
            manager: manager,
            isActive: isFrontmost && manager.isInSession && !showInfo && !showChat && !leaveConfirm,
            activeRemovalProposal: $activeRemovalProposal,
            leaveSessionConfirm: .constant(false),
            onConfirmEnd: {}
        ))
        .onChange(of: manager.pendingRemovalProposals) { _, _ in presentNextRemovalProposalIfNeeded() }
        .onChange(of: features.chat.sessionMessages.unreadCount) { oldValue, newValue in
            guard newValue > oldValue else { return }
            handleUnreadMessageArrival()
        }
        .onChange(of: manager.isInSession) { _, inSession in if !inSession { closeEverything() } }
        .task(id: manager.isInSession) { openDebugSurfaceIfAsked() }
    }

    // MARK: - The button

    /// The other people in the session, first names only (never an identifier).
    private var friendNames: [String] {
        manager.sessionParticipants.filter { !$0.isLocal }.map {
            PeerNameDisplay.firstName($0.displayName, fingerprint: $0.fingerprint, placeholder: .met, in: .fernlet)
        }
    }

    /// The green 58-pt framed square with two people on it and the gold count badge.
    private var sessionButton: some View {
        Button { menuOpen.toggle() } label: {
            // The accent's own text ink: white on the light faces, a dark ink on the lighter dark-mode face.
            WorldSpriteView(sprite: FriendsSprites.people, scale: 4, tint: WorldPalette.onAccent)
                .frame(width: 58, height: 58)
                .background(WorldPalette.accent, in: RoundedRectangle(cornerRadius: 12))
                .overlay(alignment: .bottom) { Color.black.opacity(0.2).frame(height: 4).padding(.horizontal, 3).padding(.bottom, 3) }
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(WorldPalette.ink, lineWidth: 3))
                .background { RoundedRectangle(cornerRadius: 12).fill(WorldPalette.ink.opacity(0.3)).offset(y: 3) }
                .overlay(alignment: .topTrailing) { countBadge.offset(x: 10, y: -10) }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, 14)
        .accessibilityLabel(buttonLabel)
        .accessibilityHint(Text("Messages, session info and leave"))
        .accessibilityInputLabels([Text("Session"), buttonLabel])
        .accessibilityIdentifier("world.session.button")
    }

    /// "Session with Sam and Rae", or "Session" before anyone's name is known.
    private var buttonLabel: Text {
        let names = friendNames
        return names.isEmpty ? Text("Session") : Text("Session with \(FriendsSessionNames.sentence(names))")
    }

    @ViewBuilder
    private var countBadge: some View {
        let count = friendNames.count
        if count > 0 {
            Text(verbatim: count.formatted(.number))
                .font(FernletFramedFont.buttonSmall)
                .dynamicTypeSize(...DynamicTypeSize.xLarge)
                .foregroundStyle(WorldPalette.rgb(0x3A2414))
                .frame(minWidth: 26, minHeight: 26)
                .background(WorldPalette.rgb(0xF2D58A), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(WorldPalette.ink, lineWidth: 2))
                .accessibilityHidden(true)
        }
    }

    // MARK: - The menu

    /// The card above the button, with a light dim behind that closes it.
    private var menuLayer: some View {
        ZStack(alignment: .bottomLeading) {
            Color.black.opacity(0.12)
                .contentShape(Rectangle())
                .onTapGesture { menuOpen = false }
                .accessibilityHidden(true)
            SessionMenuCard(
                title: buttonLabel,
                subtitle: menuSubtitle,
                showsMessages: features.chat.isChatAllowed,
                unreadCount: features.chat.sessionMessages.unreadCount,
                onMessages: { menuOpen = false; showChat = true },
                onInfo: { menuOpen = false; showInfo = true },
                onLeave: { menuOpen = false; leaveConfirm = true },
                onClose: { menuOpen = false }
            )
            .padding(.horizontal, 14)
            .padding(.bottom, 76)
        }
    }

    /// "Picnic · 3 people", or the count alone before the session has a name.
    private var menuSubtitle: Text {
        let people = manager.sessionParticipants.count
        guard let name = manager.currentMesh?.name, !name.isEmpty else { return Text("\(people) people connected") }
        return Text("\(name) · \(people) people")
    }

    // MARK: - Leaving

    /// End Session in the dialog: the session ends for this phone, its photos go to the review that
    /// follows every ending, and the people met without photos are asked about on the Friends panel.
    private func endSession() {
        leaveConfirm = false
        Task { await manager.leaveSessionAfterNotifyingPeers() }
    }

    private func askToEndIfInfoEnded() {
        guard endAfterInfo else { return }
        endAfterInfo = false
        leaveConfirm = true
    }

    private func closeEverything() {
        menuOpen = false
        showInfo = false
        showChat = false
        leaveConfirm = false
        endAfterInfo = false
    }

    private func presentNextRemovalProposalIfNeeded() {
        activeRemovalProposal = SessionRemovalQueue.next(current: activeRemovalProposal,
                                                         pending: manager.pendingRemovalProposals,
                                                         localFingerprint: manager.localFingerprint)
    }

    // MARK: - Incoming message signal (TF b19 item 6)

    /// An inbound message arrived while the chat sheet was closed. While the app is active, a soft
    /// knock (`messageIn`, at most one per ten seconds however fast peers send) is the in-app nudge
    /// (the menu's Messages row says how many are new). While it isn't active, a best-effort local
    /// notification instead. Never fires while the chat sheet is open (the store doesn't count those
    /// as unread).
    private func handleUnreadMessageArrival() {
        switch scenePhase {
        case .active:
            FernletFeedback.system.play(.messageIn)
        default:
            postSessionMessageNotification()
        }
    }

    private func postSessionMessageNotification() {
        // The most recent inbound message drives the notification's sender name. It was already
        // sanitized by SessionMessageStore.receiveIncoming; NotificationService re-sanitizes defensively.
        guard let latest = features.chat.sessionMessages.messages.last(where: { !$0.isOutgoing }) else { return }
        // R3: one in-flight post at a time; peers drive this event, so coalesce to the newest.
        guard messageNotificationTask == nil else { return }
        let name = latest.senderDisplayName
        messageNotificationTask = Task {
            await NotificationService.postSessionMessage(from: name)
            messageNotificationTask = nil
        }
    }

    /// DEBUG screenshots (nothing in Release): open the asked-for piece over a canned session.
    private func openDebugSurfaceIfAsked() {
        guard manager.isInSession, let surface = FriendsUITestHooks.initialSessionSurface else { return }
        switch surface {
        case "menu": menuOpen = true
        case "info": showInfo = true
        case "chat": showChat = true
        case "leave": leaveConfirm = true
        default: break
        }
    }
}

/// The session button's card (`b3-session-menu`): "Session with Sam and Rae" with a framed ✕, the
/// session's name and head count, then Messages (with how many are new, and only offered past the
/// 13+ gate), Session info and Leave session as framed rows with teal icon squares, as drawn.
struct SessionMenuCard: View {
    let title: Text
    let subtitle: Text
    let showsMessages: Bool
    let unreadCount: Int
    let onMessages: () -> Void
    let onInfo: () -> Void
    let onLeave: () -> Void
    let onClose: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        // At the largest text sizes the card is taller than the map; it scrolls rather than squeezing
        // its rows into each other.
        ViewThatFits(in: .vertical) {
            cardContent
            ScrollView { cardContent }
        }
        .frame(maxWidth: 420, alignment: .leading)
        // The frame rule (ref-frames-rule): pieces inside this card draw flat (its rows are buttons,
        // which keep their frames); the rows' teal icon squares are the owner's exception (form answer 45).
        .environment(\.fernletInFramedSection, true)
        .background(WorldPalette.paper, in: shape)
        .overlay(shape.strokeBorder(WorldPalette.ink, lineWidth: 3))
        .background { shape.fill(WorldPalette.ink.opacity(0.25)).offset(y: 4) }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    /// The title row, then the three rows.
    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    title
                        .font(FernletFramedFont.cardTitle)
                        .foregroundStyle(WorldPalette.bark)
                        .accessibilityAddTraits(.isHeader)
                    subtitle
                        .font(FernletFramedFont.body)
                        .foregroundStyle(WorldPalette.dim)
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
                FernletCloseButton(action: onClose)
            }
            if showsMessages {
                menuRow(sprite: FriendsSprites.bubble, title: Text("Messages"), detail: messagesDetail,
                        highlighted: unreadCount > 0, action: onMessages)
                    .accessibilityIdentifier("world.session.messages")
            }
            menuRow(sprite: FriendsSprites.info, title: Text("Session info"),
                    detail: Text("Who's here, rename, open or closed"), highlighted: false, action: onInfo)
                .accessibilityIdentifier("world.session.info")
            menuRow(sprite: FriendsSprites.prints, title: Text("Leave session"),
                    detail: Text("Asks first; your photos develop as they would"), highlighted: false, action: onLeave)
                .accessibilityIdentifier("world.session.leave")
        }
        .padding(16)
    }

    /// "1 new · only in this session", or "Only in this session".
    private var messagesDetail: Text {
        unreadCount > 0 ? Text("\(unreadCount) new · only in this session") : Text("Only in this session")
    }

    /// One row, drawn as the blue button's card draws its choices (`b3-session-menu` is that card on the
    /// left): its icon in a teal square, an approved exception to the frame rule's bare tiles (owner's
    /// form answer 45, 2026-10-25); Messages with new ones leads in teal, its square the deeper teal.
    private func menuRow(sprite: WorldSprite, title: Text, detail: Text, highlighted: Bool,
                         action: @escaping () -> Void) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return Button(action: action) {
            HStack(spacing: 14) {
                WorldSpriteView(sprite: sprite, scale: 3)
                    .frame(width: 44, height: 44)
                    .background(highlighted ? WorldQuickStartPalette.tileOnTeal : WorldQuickStartPalette.teal,
                                in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 2) {
                    title
                        .font(FernletFramedFont.rowTitleBold)
                        .foregroundStyle(highlighted ? WorldQuickStartPalette.onTeal : WorldPalette.bark)
                    detail
                        .font(FernletFramedFont.rowDetail)
                        .foregroundStyle(highlighted ? WorldQuickStartPalette.onTeal : WorldPalette.dim)
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .background(highlighted ? WorldQuickStartPalette.teal : WorldPalette.paperLight, in: shape)
            .overlay(alignment: .bottom) {
                if highlighted { WorldQuickStartPalette.tealLow.frame(height: 4).padding(.horizontal, 3).padding(.bottom, 3) }
            }
            .overlay(shape.strokeBorder(WorldPalette.ink, lineWidth: FernletFramedLook.frameWidth))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
    }
}

/// "End session?" over the map (`b3-leave`): a framed paper dialog on a dim, with End Session and
/// Cancel. The words are today's.
struct SessionLeaveDialog: View {
    let onEnd: () -> Void
    let onCancel: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        ZStack {
            Color.black.opacity(0.32)
                .ignoresSafeArea()
                .onTapGesture(perform: onCancel)
                .accessibilityHidden(true)
            VStack(spacing: 14) {
                Text("End session?")
                    .font(FernletFramedFont.sheetTitle)
                    .foregroundStyle(WorldPalette.bark)
                    .accessibilityAddTraits(.isHeader)
                Text("You will stop sharing with everyone in this session.")
                    .font(FernletFramedFont.body)
                    .foregroundStyle(WorldPalette.dim)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: onEnd) { Text("End Session").frame(maxWidth: .infinity) }
                    .buttonStyle(ActionPillButtonStyle(.destructive))
                    .accessibilityIdentifier("world.session.leave.end")
                Button(action: onCancel) { Text("Cancel").frame(maxWidth: .infinity) }
                    .buttonStyle(ActionPillButtonStyle(.secondary))
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("world.session.leave.cancel")
            }
            .padding(22)
            .frame(maxWidth: 380)
            .background(WorldPalette.paper, in: shape)
            .overlay(shape.strokeBorder(WorldPalette.ink, lineWidth: 3))
            .background { shape.fill(WorldPalette.ink.opacity(0.25)).offset(y: 4) }
            .padding(.horizontal, 28)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
        }
        .accessibilityAction(.escape, onCancel)
    }
}
