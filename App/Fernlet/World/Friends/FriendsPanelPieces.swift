import SwiftUI
import FernletUI
import FernletDomainModel

/// The pixel sprites the Friends panel, its session pieces and the camera draw (World Review Batches 2
/// and 3: `b2-friends-root`, `b3-friends-session`, `b3-home-session`, `b3-session-menu`,
/// `b3-camera-session`). Kept beside the screens that use them; the shared set lives in
/// ``WorldSprites``.
///
/// One-colour ink sprites (``WorldSprite/isMonoInk``) take the ink token in dark mode through
/// ``WorldSpriteView``; the two-colour ones keep their own colours on a photo or an accent fill.
nonisolated enum FriendsSprites {
    /// The carousel mark on an album tile: two stacked frames, ink with a white face, readable on any
    /// photo (`b2-friends-root` draft 3).
    static let stack = WorldSprite(
        rows: ["..kkkkkk", "..kwwwwk", "kkkkkkwk", "kwwwwkwk", "kwwwwkwk", "kwwwwkkk", "kwwwwk..", "kkkkkk.."],
        palette: ["k": WorldSprite.ink, "w": 0xFFFFFF])
    /// Two people side by side: the session row and the session button.
    static let people = WorldSprite(
        rows: [".kk...kk.", "kkkk.kkkk", ".kk...kk.", "kkkk.kkkk", "kkkk.kkkk", "k..k.k..k"],
        palette: ["k": WorldSprite.ink])
    /// A speech bubble: Messages.
    static let bubble = WorldSprite(
        rows: ["kkkkkkkkk", "k.......k", "k.kk.kk.k", "k.......k", "kkkkkkkkk", "kk.......", "k........"],
        palette: ["k": WorldSprite.ink])
    /// An "i" in a frame: Session info.
    static let info = WorldSprite(
        rows: ["kkkkkkk", "k..k..k", "k.....k", "k..k..k", "k..k..k", "k..k..k", "kkkkkkk"],
        palette: ["k": WorldSprite.ink])
    /// Two overlapping prints: Develop & finish, and Leave session (your photos develop).
    static let prints = WorldSprite(
        rows: ["...kkkkk", "...k...k", "kkkkk..k", "k...k..k", "k...kkkk", "k...k...", "kkkkk..."],
        palette: ["k": WorldSprite.ink])
    /// The disposable camera: the Camera button in the session row.
    static let camera = WorldSprite(
        rows: ["..kkk.....", "kkkkkkkkkk", "k........k", "k..kkkk..k", "k.k....k.k", "k..kkkk..k", "kkkkkkkkkk"],
        palette: ["k": WorldSprite.ink])
    /// The film counter's frame of film.
    static let film = WorldSprite(
        rows: ["kkkkkkkk", "k.k..k.k", "kkkkkkkk", "k......k", "kkkkkkkk", "k.k..k.k", "kkkkkkkk"],
        palette: ["k": WorldSprite.ink])
    /// A tray with an arrow into it: Save to Photos.
    static let download = WorldSprite(
        rows: ["...k...", "...k...", ".k.k.k.", "..kkk..", "...k...", "k.....k", "kkkkkkk"],
        palette: ["k": WorldSprite.ink])
    /// An empty heart: Favorite, not yet chosen.
    static let heartOutline = WorldSprite(
        rows: [".kk.kk.", "k..k..k", "k.....k", ".k...k.", "..k.k..", "...k..."],
        palette: ["k": WorldSprite.ink])
    /// A bin: Delete.
    static let trash = WorldSprite(
        rows: ["..kkk..", "kkkkkkk", ".k...k.", ".k.k.k.", ".k.k.k.", ".k...k.", ".kkkkk."],
        palette: ["k": WorldSprite.ink])
    /// A flag: Report.
    static let flag = WorldSprite(
        rows: ["kkkkkk", "kkkkk.", "kkkkkk", "k.....", "k.....", "k.....", "k....."],
        palette: ["k": WorldSprite.ink])
    /// An arrow up: Send.
    static let sendArrow = WorldSprite(
        rows: ["...k...", "..kkk..", ".kkkkk.", "kk.k.kk", "...k...", "...k...", "...k..."],
        palette: ["k": WorldSprite.ink])
    /// A small moss heart: Safety & reporting.
    static let heartMoss = WorldSprite(
        rows: [".kk.kk.", "kGGkGGk", "kGGGGGk", ".kGGGk.", "..kGk..", "...k..."],
        palette: ["k": WorldSprite.ink, "G": 0x5E844D])
    /// A shop's awning box: the Your shop row.
    static let shop = WorldSprite(
        rows: ["kkkkkkkkk", "k.......k", "kkkkkkkkk", ".k.....k.", ".k.kkk.k.", ".k.....k.", ".kkkkkkk."],
        palette: ["k": WorldSprite.ink])
}

/// A framed slim row on the Friends panel (`b2-friends-root` draft 3, `b3-friends-session` draft 2):
/// one line of status with a small sprite in front and an optional control at the end, on raised paper
/// in a 2-pt frame. `accent` frames it in the look's mark colour (the session row).
struct FriendsSlimRow<Leading: View, Trailing: View>: View {
    var accent = false
    @ViewBuilder let leading: Leading
    @ViewBuilder let trailing: Trailing
    @Environment(\.fernletFramedLook) private var look
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        // At accessibility sizes the control drops under the line, so neither breaks mid-word.
        let stacked = dynamicTypeSize.isAccessibilitySize
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                             : AnyLayout(HStackLayout(spacing: 10))
        layout {
            HStack(spacing: 10) { leading }
            if !stacked { Spacer(minLength: 6) }
            trailing
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, stacked ? 10 : 6)
        .frame(minHeight: 52)
        .background(look?.raised ?? Color.cream, in: shape)
        .overlay(shape.strokeBorder(accent ? (look?.mark ?? Color.moss) : (look?.ink ?? Color.bark.opacity(0.12)),
                                    lineWidth: accent ? 3 : FernletFramedLook.frameWidth))
    }
}

/// The Friends panel's slot during a session (`b3-friends-session` draft 2): one slim moss-framed row,
/// "In a session · Sam, Rae", with the Camera button that opens the disposable camera. Messages,
/// Session info and Leave are on Home's session button, not here.
struct FriendsSessionRow: View {
    /// The other people's first names, already filtered (never an identifier).
    let names: [String]
    let onCamera: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        FriendsSlimRow(accent: true) {
            WorldSpriteView(sprite: FriendsSprites.people, scale: 2)
            label
        } trailing: {
            Button(action: onCamera) { Text("Camera") }
                .buttonStyle(ActionPillButtonStyle(.primary, size: .small))
                .accessibilityIdentifier("friends.session.camera")
                .accessibilityLabel("Open the disposable camera")
                .accessibilityInputLabels([Text("Camera"), Text("Disposable camera")])
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("friends.session.row")
    }

    /// "In a session" in bold, then the names; the names drop under it at accessibility sizes.
    private var label: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2)) : AnyLayout(HStackLayout(spacing: 6))
        return layout {
            Text("In a session")
                .font(FernletFramedFont.body.weight(.bold))
                .foregroundStyle(WorldPalette.bark)
            if !names.isEmpty {
                Text(verbatim: "· " + FriendsSessionNames.narrow(names))
                    .font(FernletFramedFont.body)
                    .foregroundStyle(WorldPalette.bark)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
            }
        }
    }
}

/// The two framed buttons under the Friends subtitle, Activities and Friends (`b2-friends-root`
/// draft 3): each half the width, side by side, stacked at accessibility sizes. They push the album
/// stack's routes, so a re-tap of the panel pops them as before.
struct FriendsHeaderButtons: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))
        layout {
            NavigationLink(value: FriendsRoute.activities) {
                Text("Activities").frame(maxWidth: .infinity)
            }
            .accessibilityIdentifier("friends.activities")
            NavigationLink(value: FriendsRoute.friendList) {
                Text("Friends").frame(maxWidth: .infinity)
            }
            .accessibilityIdentifier("friends.manageFriends")
            .accessibilityLabel("Friends and blocks")
            .accessibilityInputLabels([Text("Friends"), Text("Friends and blocks")])
        }
        .buttonStyle(ActionPillButtonStyle(.secondary, size: .small))
    }
}

/// The search field above the album (and on Friends & Blocks): the pixel magnifier inside a framed
/// field, as the approved kit draws it (`.fld` with an icon).
struct FriendsSearchField: View {
    let prompt: LocalizedStringKey
    @Binding var text: String
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        HStack(spacing: 10) {
            FernletIcon(.search, scale: 2)
            TextField(prompt, text: $text, prompt: .fieldPrompt(prompt))
                .font(look == nil ? .fernlet(.body) : FernletFramedFont.field)
                .foregroundStyle(look?.text ?? Color.bark)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 52)
        .background(look?.raised ?? Color.cream, in: shape)
        .overlay(shape.strokeBorder(look?.ink ?? Color.bark.opacity(0.10), lineWidth: FernletFramedLook.frameWidth))
    }
}

/// An empty section's line in the World look: a small pixel face over the sentence, centred, in the
/// page's dim ink (`b2-activities`' "No activities yet"). Without the look it is today's
/// ``EmptyState``.
struct FriendsEmptyNote: View {
    let text: Text
    var systemImage: String?
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        if let look {
            VStack(spacing: 10) {
                WorldSpriteView(sprite: WorldSprites.face, scale: 3)
                text
                    .font(FernletFramedFont.body)
                    .foregroundStyle(look.dim)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        } else {
            VStack(spacing: 10) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(Color.slate)
                        .accessibilityHidden(true)
                }
                text
                    .font(.fernlet(.bubble))
                    .foregroundStyle(Color.slate)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
        }
    }
}

/// A framed card that names a place to go (`b2-friend-list`'s Safety & reporting, `b2-friend-shop`'s
/// Your shop, `b2-shop-editor`'s Design a new item): a framed icon tile, the title and an optional
/// detail line, and the pixel chevron, on paper in a 2-pt frame. The caller wraps it in its link or
/// button.
struct FriendsLinkCard: View {
    let title: Text
    var detail: Text?
    let sprite: WorldSprite
    var spriteScale: CGFloat = 3
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: FernletFramedLook.cardRadius, style: .continuous)
        HStack(spacing: 14) {
            FernletIconTile(size: 42) { WorldSpriteView(sprite: sprite, scale: spriteScale) }
            VStack(alignment: .leading, spacing: 2) {
                title
                    .font(FernletFramedFont.rowTitle.weight(.semibold))
                    .foregroundStyle(look?.text ?? Color.bark)
                if let detail {
                    detail
                        .font(FernletFramedFont.rowDetail)
                        .foregroundStyle(look?.dim ?? Color.slate)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            FernletIcon(.chevron, scale: 2)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 12)
        .frame(minHeight: 64)
        .background(look?.paper ?? Color.cream, in: shape)
        .overlay(shape.strokeBorder(look?.ink ?? Color.bark.opacity(0.08), lineWidth: FernletFramedLook.frameWidth))
        .background { shape.fill(look?.shadow ?? Color.clear).offset(y: 3) }
        .contentShape(shape)
    }
}

/// A framed notice card on the Friends panel (the restore card, the background-time card, the
/// discovery failure, the photo shelf): paper tinted by tone — the look's warn or sage — in a 2-pt
/// frame, the lines stacked. Under the look it draws no glyph (every icon is pixel art, and these
/// cards' SF Symbols come from copy tables); without it, today's card with its symbol.
struct FriendsNoticeCard<Content: View>: View {
    /// Which tint the card takes.
    enum Tone { case info, warn }

    let tone: Tone
    let symbolName: String
    @ViewBuilder let content: Content
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        if let look {
            let shape = RoundedRectangle(cornerRadius: FernletFramedLook.cardRadius, style: .continuous)
            VStack(alignment: .leading, spacing: 6) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(EdgeInsets(top: 13, leading: 15, bottom: 13, trailing: 44))
                .background(tone == .warn ? look.warn : look.sage, in: shape)
                .overlay(shape.strokeBorder(look.ink, lineWidth: FernletFramedLook.frameWidth))
        } else {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbolName)
                    .foregroundStyle(tone == .warn ? Color.terracotta : Color.goldenrod)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) { content }
                Spacer(minLength: 4)
            }
            .padding(14)
            .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

/// A designed item's preview in the shops (`b2-friend-shop`, `b2-shop-editor`): its texture centred in a
/// recessed framed box, full width (or `width` when given).
struct FriendsItemPreview: View {
    let texture: ItemGridTexture
    var width: CGFloat?
    let height: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        CustomItemThumbnail(texture: texture, size: height - 12)
            .frame(maxWidth: width ?? .infinity)
            .frame(width: width, height: height)
            .background(WorldPalette.paperShade, in: shape)
            .overlay(shape.strokeBorder(WorldPalette.ink, lineWidth: FernletFramedLook.frameWidth))
    }
}

/// The coin balance in a framed pill (`b2-friend-shop` draft 2): the pixel coin and the number, read
/// as "25 coins".
struct FriendsCoinPill: View {
    let balance: Int

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        HStack(spacing: 6) {
            WorldSpriteView(sprite: WorldSprites.coin, scale: 2)
            Text(verbatim: balance.formatted(.number))
                .font(FernletFramedFont.button)
                .foregroundStyle(WorldPalette.bark)
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 40)
        .background(WorldPalette.paperLight, in: shape)
        .overlay(shape.strokeBorder(WorldPalette.ink, lineWidth: FernletFramedLook.frameWidth))
        .background { shape.fill(WorldPalette.ink.opacity(0.22)).offset(y: 3) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: FernletUICopy.coinBalance(balance)))
    }
}

/// The names of the other people in a session, first names only, as one list ("Sam and Rae"; "Sam,
/// Rae" in the narrow form), in this device's language. Never a fingerprint: the names are already
/// `PeerNameDisplay`-filtered by the caller.
nonisolated enum FriendsSessionNames {
    /// "Sam, Rae" — the slim row's short form.
    static func narrow(_ names: [String]) -> String {
        names.formatted(.list(type: .and, width: .narrow))
    }

    /// "Sam and Rae" — the session button's and menu's sentence form.
    static func sentence(_ names: [String]) -> String {
        names.formatted(.list(type: .and, width: .standard))
    }
}
