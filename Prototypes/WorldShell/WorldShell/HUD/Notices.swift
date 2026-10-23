import SwiftUI

/// The toast above the item bar: crisp text on bark, as today's toasts, with an optional Undo.
struct ToastView: View {
    let toast: ShellToast
    let onAction: (ToastAction) -> Void
    @Environment(\.shellMetrics) private var metrics

    var body: some View {
        HStack(spacing: metrics.pt(10)) {
            Text(toast.message)
                .font(.system(size: metrics.pt(12.5)))
                .foregroundStyle(FernColors.parchment)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let action = toast.action {
                Button(action.label) { onAction(action) }
                    .font(.system(size: metrics.pt(12.5), weight: .bold))
                    .foregroundStyle(FernColors.toastAction)
            }
        }
        .padding(EdgeInsets(top: metrics.pt(10), leading: metrics.pt(12), bottom: metrics.pt(10), trailing: metrics.pt(12)))
        .background(FernColors.toast, in: RoundedRectangle(cornerRadius: metrics.pt(14)))
        .accessibilityElement(children: .combine)
    }
}

/// A pixel banner under the status bar: a new stamp, or a change of ride.
struct BannerView: View {
    let banner: ShellBanner
    @Environment(\.shellMetrics) private var metrics

    var body: some View {
        HStack(spacing: metrics.pt(8)) {
            PixelSpriteView(sprite: sprite, scale: metrics.pixel + (banner.badge == .cookie || banner.badge == .star ? 1 : 0))
                .frame(width: metrics.pt(36), height: metrics.pt(36))
                .background(FernColors.carbs, in: Circle())
                .overlay(Circle().strokeBorder(FernColors.ink, lineWidth: metrics.pt(2)))
            VStack(alignment: .leading, spacing: 1) {
                Text(banner.title).font(.system(size: metrics.pt(13), weight: .bold, design: .rounded)).foregroundStyle(FernColors.ink)
                Text(banner.subtitle).font(.system(size: metrics.pt(11))).foregroundStyle(FernColors.noteInk)
            }
            Spacer(minLength: 0)
        }
        .padding(EdgeInsets(top: metrics.pt(6), leading: metrics.pt(6), bottom: metrics.pt(6), trailing: metrics.pt(10)))
        .frame(width: metrics.pt(280))
        .gamePlate(cornerRadius: metrics.pt(10), border: metrics.pt(3))
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
    @Environment(\.shellMetrics) private var metrics

    var body: some View {
        HStack(spacing: metrics.pt(8)) {
            Text("\(kilometres) km").font(.system(size: metrics.pt(14), weight: .bold, design: .monospaced)).foregroundStyle(FernColors.ink)
            VStack(alignment: .leading, spacing: 0) {
                Text(hike ? "Oak Park loop" : "Walking together").font(.system(size: metrics.pt(12), weight: .semibold))
                Text("Precise location on for this walk").font(.system(size: metrics.pt(10.5), weight: .semibold)).foregroundStyle(FernColors.walkBlue)
            }
            .foregroundStyle(FernColors.speechInk)
            Spacer(minLength: 0)
            Button("End", action: onEnd)
                .font(.system(size: metrics.pt(12), weight: .bold))
                .foregroundStyle(Color.white)
                .padding(EdgeInsets(top: metrics.pt(4), leading: metrics.pt(10), bottom: metrics.pt(4), trailing: metrics.pt(10)))
                .background(FernColors.endButton, in: RoundedRectangle(cornerRadius: metrics.pt(6)))
                .overlay(RoundedRectangle(cornerRadius: metrics.pt(6)).strokeBorder(FernColors.ink, lineWidth: metrics.pt(2)))
        }
        .padding(EdgeInsets(top: metrics.pt(5), leading: metrics.pt(10), bottom: metrics.pt(5), trailing: metrics.pt(6)))
        .gamePlate(cornerRadius: metrics.pt(8), border: metrics.pt(2))
    }
}

/// The companion's speech bubble: crisp text in a pixel-edged bubble with a tail toward it.
struct SpeechBubbleView: View {
    let text: String
    @Environment(\.shellMetrics) private var metrics

    var body: some View {
        VStack(spacing: 0) {
            Text(text)
                .font(.system(size: metrics.pt(11.5)))
                .foregroundStyle(FernColors.speechInk)
                .multilineTextAlignment(.leading)
                .padding(EdgeInsets(top: metrics.pt(5), leading: metrics.pt(8), bottom: metrics.pt(5), trailing: metrics.pt(8)))
                .frame(maxWidth: metrics.pt(170))
                .fixedSize(horizontal: false, vertical: true)
                .background {
                    RoundedRectangle(cornerRadius: metrics.pt(3)).fill(FernColors.rgb(0xFFFBEF))
                        .background {
                            RoundedRectangle(cornerRadius: metrics.pt(3)).fill(FernColors.ink.opacity(0.35)).offset(y: metrics.pt(2))
                        }
                }
                .overlay(RoundedRectangle(cornerRadius: metrics.pt(3)).strokeBorder(FernColors.ink, lineWidth: metrics.pt(2)))
            Triangle().fill(FernColors.ink).frame(width: metrics.pt(10), height: metrics.pt(7))
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
