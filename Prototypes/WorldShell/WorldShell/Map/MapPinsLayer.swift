import SwiftUI

/// The things on the map you can touch: starred places, your own meal and hike photos where you
/// took them, and the companion at your position (no blue dot) with its speech bubble.
///
/// Each is a SwiftUI view placed from the reported ``MapViewport``; the layer itself has no
/// background, so a touch anywhere else falls through to the base map.
struct MapPinsLayer: View {
    let model: WorldShellModel
    let viewport: MapViewport
    let size: CGSize
    @Environment(\.shellMetrics) private var metrics

    var body: some View {
        ZStack(alignment: .topLeading) {
            if !model.decoy {
                pins
            }
            companion
            if let speech = model.speech {
                // The bubble's tail ends just above the sprite's head, as in the mockup.
                let point = viewport.screenPoint(for: model.companionPosition, in: size)
                let box = CGSize(width: metrics.pt(190), height: metrics.pt(120))
                SpeechBubbleView(text: speech.text)
                    .frame(width: box.width, height: box.height, alignment: .bottom)
                    .position(x: min(max(point.x, box.width / 2 + 6), size.width - box.width / 2 - 6),
                              y: point.y - 21 * metrics.pixel - box.height / 2)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    /// The starred noodle bar and the saved trail's start flag (once known), and your own photos.
    @ViewBuilder
    private var pins: some View {
        if model.level.visits(to: .noodle) > 0 {
            pin(PixelSprites.star, at: FixtureSpot.noodle.location, label: "Hoshi Noodle Bar, starred") {
                model.showToast("Hoshi Noodle Bar · starred after your third meal here. Your usual is one tap away.")
            }
        }
        if model.level.visits(to: .trail) > 0 {
            pin(PixelSprites.flag, at: FixtureSpot.trail.location, label: "Oak Park loop, saved trail") {
                model.showToast("Oak Park loop · your saved trail starts here.")
            }
        }
        if model.level.hasPhotos {
            pin(PixelSprites.photo, at: WorldFixtures.lunchPhoto, label: "Your photo from lunch here") {
                model.showToast("Your photo from lunch here. Only your own meal and hike photos sit on the map.")
            }
            pin(PixelSprites.photoGreen, at: WorldFixtures.hikePhoto, label: "Your photo from the Oak Park loop") {
                model.showToast("Your photo from the Oak Park loop, where you took it.")
            }
        }
    }

    /// A pixel mark standing on its point, tappable.
    private func pin(_ sprite: PixelSprite, at point: GeoPoint, label: String, action: @escaping () -> Void) -> some View {
        let screen = viewport.screenPoint(for: point, in: size)
        return Button(action: action) {
            PixelSpriteView(sprite: sprite)
                .shadow(color: FernColors.ink.opacity(0.4), radius: 0, x: 0, y: 1)
                .padding(6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .position(x: screen.x, y: screen.y - CGFloat(sprite.height) * metrics.pixel / 2)
        .accessibilityLabel(label)
    }

    /// The companion: tap to pet, hold to customise. It hops on each pet and a pixel heart rises.
    private var companion: some View {
        let point = viewport.screenPoint(for: model.companionPosition, in: size)
        let replay = model.replay
        return TimelineView(.periodic(from: .now, by: 1)) { timeline in
            ZStack {
                PixelCompanionView(state: model.careState, ride: model.ride, outfit: model.outfit,
                                   walking: replay != nil, step: Int((replay?.travelled ?? 0) / 6),
                                   settled: model.isSettled(at: timeline.date) && replay == nil,
                                   facingLeft: model.facingLeft)
                    .modifier(PetHop(count: model.petCount))
                if model.petCount > 0 { PetHeart().id(model.petCount) }
            }
        }
        .frame(width: 24 * metrics.pixel, height: 24 * metrics.pixel)
        .contentShape(Rectangle())
        .onTapGesture { model.pet() }
        .onLongPressGesture(minimumDuration: 0.45) { model.toggle(.customize) }
        // The sprite's feet (its row 21) stand on the companion's position.
        .position(x: point.x, y: point.y - 9.5 * metrics.pixel)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Fernlet, \(model.careState.label.lowercased())")
        .accessibilityHint("Tap to pet")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { model.pet() }
        .accessibilityAction(named: "Customize") { model.toggle(.customize) }
    }
}

/// A short hop each time `count` changes, in whole-pixel steps (still under Reduce Motion).
private struct PetHop: ViewModifier {
    let count: Int
    @State private var lift: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.shellMetrics) private var metrics

    func body(content: Content) -> some View {
        content
            .offset(y: lift)
            .onChange(of: count) {
                guard !reduceMotion else { return }
                withAnimation(.easeOut(duration: 0.14)) { lift = -metrics.pt(12) }
                withAnimation(.easeIn(duration: 0.2).delay(0.14)) { lift = 0 }
            }
    }
}

/// A pixel heart that rises and fades from the companion; re-created (by id) on each pet.
private struct PetHeart: View {
    @State private var rise = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.shellMetrics) private var metrics

    var body: some View {
        PixelSpriteView(sprite: PixelSprites.heart)
            .offset(y: -11 * metrics.pixel - (rise ? metrics.pt(30) : 0))
            .opacity(rise || reduceMotion ? 0 : 1)
            .onAppear { withAnimation(.easeOut(duration: 1)) { rise = true } }
            .allowsHitTesting(false)
    }
}
