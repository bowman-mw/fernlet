import SwiftUI
import UIKit
import FernletUI

// MARK: - The album post's shared parts (b2-album-post)

/// The photo pager every album post draws (`b2-album-post`): one page per photo at the post's
/// height, the "n / total" pill top right and the pixel dots at the bottom, both fading after a few
/// seconds.
///
/// Shared by a hangout's photos (`FriendPhotoCarouselPostView`) and a "Just you" set from the camera
/// used on your own (`SoloPhotoPostView`, `b4-mem-solo-open`), so the two read alike. The pages are
/// keyed by photo id; the caller draws each page and decides what loads (the current page ± 1).
struct AlbumPostPager<Page: View>: View {
    /// The photos' ids, in order.
    let ids: [UUID]
    /// The photo on screen.
    @Binding var selection: UUID
    /// The pager's height (4:5 of the width).
    let height: CGFloat
    /// One page.
    let page: (UUID) -> Page

    @State private var chromeVisible = true
    @State private var chromeTask: Task<Void, Never>?

    /// A pager over `ids`, `selection` the photo on screen, each page drawn by `page`.
    init(ids: [UUID], selection: Binding<UUID>, height: CGFloat, @ViewBuilder page: @escaping (UUID) -> Page) {
        self.ids = ids
        self._selection = selection
        self.height = height
        self.page = page
    }

    var body: some View {
        TabView(selection: $selection) {
            ForEach(ids, id: \.self) { id in
                page(id)
                    .tag(id)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .frame(height: height)
        .overlay(alignment: .topTrailing) { pageCounter }
        .overlay(alignment: .bottom) { pageDots }
        .onAppear { scheduleChromeFade() }
        .onChange(of: selection) { _, _ in scheduleChromeFade() }
        .onDisappear { chromeTask?.cancel() }
    }

    /// The position of the photo on screen (0 when it is not in the list).
    private var selectedIndex: Int {
        ids.firstIndex(of: selection) ?? 0
    }

    /// The "n / total" pill, shown with the auto-fading chrome on multi-photo posts.
    @ViewBuilder
    private var pageCounter: some View {
        if chromeVisible, ids.count > 1 {
            Text("\(selectedIndex + 1) / \(ids.count)")
                .font(FernletFramedFont.buttonSmall)
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.black.opacity(0.72), in: Capsule())
                .padding(14)
                .transition(.opacity)
        }
    }

    /// The page marks: one small framed square per photo, the current one filled white (the pixel
    /// dots of `b2-album-post`), shown with the auto-fading chrome on multi-photo posts.
    @ViewBuilder
    private var pageDots: some View {
        if chromeVisible, ids.count > 1 {
            HStack(spacing: 4) {
                ForEach(ids, id: \.self) { id in
                    Rectangle()
                        .fill(id == selection ? Color.white : Color.white.opacity(0.45))
                        .frame(width: 10, height: 10)
                        .overlay(Rectangle().strokeBorder(WorldPalette.ink, lineWidth: 1.5))
                }
            }
            .padding(.bottom, 14)
            .transition(.opacity)
        }
    }

    private func scheduleChromeFade() {
        chromeTask?.cancel()
        withAnimation(.easeInOut(duration: 0.2)) {
            chromeVisible = true
        }
        // `assistive: nil` — this fade REMOVES CONTROLS from the accessibility tree rather than
        // retiring a notice: the counter and the dots go with the chrome. A stretched timer would
        // only delay deleting them out from under a VoiceOver user mid-swipe, so while an assistive
        // technology is running the chrome simply stays.
        guard let window = FernletDismissalWindow.system
            .windowUnlessAssistive(standard: .seconds(5)) else { return }
        chromeTask = Task {
            // The sleep result IS the cancellation check: `Task.sleep` throws exactly when the task
            // is cancelled, so a cancelled fade simply returns (R7 — no swallowed error).
            do {
                try await Task.sleep(for: window)
            } catch {
                return
            }
            withAnimation(.easeInOut(duration: 0.3)) {
                chromeVisible = false
            }
        }
    }
}

/// One framed 44-pt pixel-icon action under an album photo (Save, Favorite, Delete, Report) on
/// raised paper (`b2-album-post`).
struct AlbumPostActionButton: View {
    /// The pixel icon.
    let sprite: WorldSprite
    /// The VoiceOver label: `LocalizedStringKey`, never `String`, so it is harvested and localized.
    let accessibilityLabel: LocalizedStringKey
    /// Whether the action is on (a filled heart): said aloud as the selected trait.
    var selected = false
    /// What the button does.
    let action: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        return Button(action: action) {
            WorldSpriteView(sprite: sprite, scale: 2)
                .frame(width: 44, height: 44)
                .background(WorldPalette.paperLight, in: shape)
                .overlay(shape.strokeBorder(WorldPalette.ink, lineWidth: FernletFramedLook.frameWidth))
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        // A filled heart is the ONLY thing that said "favorited"; the trait says it out loud.
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

extension View {
    /// The paper card under an album photo (`b2-album-post`): paper, the ink frame, a soft drop.
    func albumPostCard() -> some View {
        let shape = RoundedRectangle(cornerRadius: FernletFramedLook.cardRadius, style: .continuous)
        return self
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(EdgeInsets(top: 12, leading: 15, bottom: 12, trailing: 12))
            .background(WorldPalette.paper, in: shape)
            .overlay(shape.strokeBorder(WorldPalette.ink, lineWidth: FernletFramedLook.frameWidth))
            .background { shape.fill(WorldPalette.ink.opacity(0.22)).offset(y: 3) }
    }
}

/// Loads a photo's bytes lazily through a closure and shows a placeholder glyph until decoded.
///
/// `shouldLoad` lets the carousel defer decoding to the current page ± 1 so a long post never
/// decodes every image at once; the load task re-fires when the flag flips to true. Shared by the
/// Friends album's tiles and posts, and the solo camera's "Just you" sets.
struct LazyFriendPhotoImage: View {
    let loadData: () -> Data?
    let contentMode: ContentMode
    var shouldLoad = true

    @State private var image: UIImage?

    /// An image loaded through `loadData`, drawn with `contentMode`, decoded once `shouldLoad`.
    init(loadData: @escaping () -> Data?, contentMode: ContentMode, shouldLoad: Bool = true) {
        self.loadData = loadData
        self.contentMode = contentMode
        self.shouldLoad = shouldLoad
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    // T2-10: a photo inverted is a colour negative of a person's face. The `photo`
                    // placeholder below is a tinted glyph and is left to invert normally.
                    .accessibilityIgnoresInvertColors()
            } else {
                Image(systemName: "photo")
                    .font(.largeTitle)
                    .foregroundStyle(Color.white.opacity(0.7))
            }
        }
        .task(id: shouldLoad) {
            guard shouldLoad, image == nil, let data = loadData() else { return }
            image = UIImage(data: data)
        }
    }
}
