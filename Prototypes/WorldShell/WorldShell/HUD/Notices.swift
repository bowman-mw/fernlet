import SwiftUI

/// The toast above the item bar: crisp text on bark, as today's toasts, with an optional Undo.
struct ToastView: View {
    let toast: ShellToast
    let onAction: (ToastAction) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(toast.message)
                .font(.footnote)
                .foregroundStyle(FernColors.parchment)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let action = toast.action {
                Button(action.label) { onAction(action) }
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(FernColors.toastAction)
            }
        }
        .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
        .background(FernColors.toast, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }
}

/// A pixel banner under the status bar: a new stamp, or a change of ride.
struct BannerView: View {
    let banner: ShellBanner

    var body: some View {
        HStack(spacing: 8) {
            PixelSpriteView(sprite: sprite, scale: banner.badge == .cookie || banner.badge == .star ? 3 : 2)
                .frame(width: 36, height: 36)
                .background(FernColors.carbs, in: Circle())
                .overlay(Circle().strokeBorder(FernColors.ink, lineWidth: 2))
            VStack(alignment: .leading, spacing: 1) {
                Text(banner.title).font(.system(size: 13, weight: .bold, design: .rounded)).foregroundStyle(FernColors.ink)
                Text(banner.subtitle).font(.caption2).foregroundStyle(FernColors.rgb(0x7A5A3A))
            }
            Spacer(minLength: 0)
        }
        .padding(EdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 10))
        .frame(width: 280)
        .gamePlate(cornerRadius: 10)
        .accessibilityElement(children: .combine)
    }

    private var sprite: PixelSprite {
        switch banner.badge {
        case .cookie: PixelSprites.cookie
        case .bike: PixelSprites.bike
        case .car: PixelSprites.car
        case .star: PixelSprites.star
        }
    }
}

/// The bar across the top during a walk: distance so far, what this is, that precise location is
/// on for this walk only, and End.
struct WalkBar: View {
    let kilometres: String
    let hike: Bool
    let onEnd: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text("\(kilometres) km").font(.system(size: 14, weight: .bold, design: .monospaced)).foregroundStyle(FernColors.ink)
            VStack(alignment: .leading, spacing: 0) {
                Text(hike ? "Oak Park loop" : "Walking together").font(.caption.weight(.semibold))
                Text("Precise location on for this walk").font(.caption2.weight(.semibold)).foregroundStyle(FernColors.walkBlue)
            }
            .foregroundStyle(FernColors.speechInk)
            Spacer(minLength: 0)
            Button("End", action: onEnd)
                .font(.footnote.weight(.bold))
                .foregroundStyle(FernColors.woodLabel)
                .padding(EdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10))
                .background(FernColors.rgb(0xB05A3E), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(FernColors.ink, lineWidth: 2))
        }
        .padding(EdgeInsets(top: 5, leading: 10, bottom: 5, trailing: 6))
        .gamePlate(cornerRadius: 8)
    }
}

/// The companion's speech bubble: crisp text in a pixel-edged bubble with a tail toward it.
struct SpeechBubbleView: View {
    let text: String

    var body: some View {
        VStack(spacing: 0) {
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(FernColors.speechInk)
                .multilineTextAlignment(.leading)
                .padding(EdgeInsets(top: 5, leading: 8, bottom: 5, trailing: 8))
                .frame(maxWidth: 180)
                .fixedSize(horizontal: false, vertical: true)
                .background(FernColors.rgb(0xFFFBEF), in: RoundedRectangle(cornerRadius: 3))
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(FernColors.ink, lineWidth: 2))
                .shadow(color: FernColors.ink.opacity(0.35), radius: 0, x: 0, y: 2)
            Triangle().fill(FernColors.ink).frame(width: 10, height: 7)
        }
        .accessibilityLabel(text)
    }
}

/// A downward-pointing triangle: the speech bubble's tail.
struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.closeSubpath()
        }
    }
}
