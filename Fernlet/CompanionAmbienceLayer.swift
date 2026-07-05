//
//  CompanionAmbienceLayer.swift
//  Fernlet
//
//  The subtle environment layer behind the companion on Home (and only there): a very
//  soft time-of-day tint that is always on (local hour only — no location, no network),
//  plus a couple of gentle sky accents (sun glow / drifting clouds / rain streaks /
//  snowfall) when weather prompts are enabled AND WeatherKit has cached conditions.
//
//  ┌─ NOTE FOR THE DESIGN-MOCKUP PASS ──────────────────────────────────────────────┐
//  │ Every shape, opacity, gradient stop, and drift speed in this file is           │
//  │ placeholder-calibrated: deliberately conservative so the layer never fights    │
//  │ the parchment theme or the companion. The whole treatment lives behind this    │
//  │ single view, so it can be restyled (or replaced wholesale) without touching    │
//  │ HomeView or CompanionView.                                                     │
//  └────────────────────────────────────────────────────────────────────────────────┘
//

import SwiftUI
import AppServices

/// Time-of-day phase for the ambience tint. A pure hour → phase mapping so tests can
/// pin the boundaries.
enum CompanionDayPhase: Equatable, CaseIterable {
    case dawn
    case day
    case dusk
    case night

    static func phase(forHour hour: Int) -> CompanionDayPhase {
        switch hour {
        case 5..<8: .dawn
        case 8..<17: .day
        case 17..<21: .dusk
        default: .night
        }
    }

    static func current(date: Date = Date(), calendar: Calendar = .current) -> CompanionDayPhase {
        phase(forHour: calendar.component(.hour, from: date))
    }
}

/// The single environment view behind the companion. Purely decorative: it never
/// intercepts touches and is hidden from the accessibility tree, so the tap-to-pet
/// gesture and the UX-appearance probes are unaffected.
struct CompanionAmbienceLayer: View {
    var phase: CompanionDayPhase
    /// `nil` ⇒ time-of-day tint only (weather off, unauthorized, or unavailable).
    var ambient: WeatherAmbient?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 26)
                .fill(
                    LinearGradient(
                        colors: Self.tintColors(for: phase),
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            if let ambient {
                // Slow, deterministic drift driven by wall-clock time; a lazy update
                // interval keeps this far cheaper than the companion's own breath loop.
                TimelineView(.animation(minimumInterval: 0.25)) { timeline in
                    Canvas { context, size in
                        Self.drawAccents(
                            context: &context,
                            size: size,
                            ambient: ambient,
                            time: timeline.date.timeIntervalSinceReferenceDate
                        )
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 26))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The parchment-compatible tint per phase — low-opacity theme colors so the shift
    /// reads as "the light changed", never as a new background. Static + internal so
    /// tests can assert each phase yields a usable gradient.
    static func tintColors(for phase: CompanionDayPhase) -> [Color] {
        switch phase {
        case .dawn:
            [Color.dustyRose.opacity(0.10), Color.goldenrod.opacity(0.05)]
        case .day:
            [Color.sun.opacity(0.07), Color.sun.opacity(0.01)]
        case .dusk:
            [Color.goldenrod.opacity(0.11), Color.dustyRose.opacity(0.06)]
        case .night:
            [Color.slate.opacity(0.13), Color.slate.opacity(0.04)]
        }
    }

    // MARK: - Sky accents (placeholder-calibrated vector shapes)

    private static func drawAccents(
        context: inout GraphicsContext,
        size: CGSize,
        ambient: WeatherAmbient,
        time: TimeInterval
    ) {
        switch ambient.sky {
        case .clear:
            if ambient.isDaytime {
                drawSunGlow(context: &context, size: size)
            } else {
                drawStars(context: &context, size: size)
            }
        case .clouds:
            drawClouds(context: &context, size: size, time: time)
        case .rain:
            drawClouds(context: &context, size: size, time: time, count: 1)
            drawRain(context: &context, size: size, time: time)
        case .snow:
            drawSnow(context: &context, size: size, time: time)
        }
    }

    /// A soft warm glow in the upper-trailing corner — "the sun is out", not a sun icon.
    private static func drawSunGlow(context: inout GraphicsContext, size: CGSize) {
        let center = CGPoint(x: size.width * 0.82, y: size.height * 0.16)
        let radius = min(size.width, size.height) * 0.42
        let rect = CGRect(
            x: center.x - radius, y: center.y - radius,
            width: radius * 2, height: radius * 2
        )
        context.fill(
            Path(ellipseIn: rect),
            with: .radialGradient(
                Gradient(colors: [Color.sun.opacity(0.20), Color.sun.opacity(0)]),
                center: center,
                startRadius: 0,
                endRadius: radius
            )
        )
    }

    /// A handful of fixed, tiny star dots for clear nights.
    private static func drawStars(context: inout GraphicsContext, size: CGSize) {
        let positions: [(CGFloat, CGFloat)] = [
            (0.16, 0.18), (0.32, 0.10), (0.70, 0.14), (0.84, 0.26), (0.55, 0.08)
        ]
        for (fx, fy) in positions {
            let rect = CGRect(x: size.width * fx, y: size.height * fy, width: 2.5, height: 2.5)
            context.fill(Path(ellipseIn: rect), with: .color(Color.goldenrod.opacity(0.35)))
        }
    }

    /// A couple of soft cloud blobs drifting very slowly side to side.
    private static func drawClouds(
        context: inout GraphicsContext,
        size: CGSize,
        time: TimeInterval,
        count: Int = 2
    ) {
        for index in 0..<count {
            let baseX = size.width * (index == 0 ? 0.28 : 0.72)
            let drift = sin(time * 0.07 + Double(index) * 2.4) * size.width * 0.05
            let y = size.height * (index == 0 ? 0.20 : 0.14)
            let cloudWidth = size.width * 0.24
            let cloudHeight = cloudWidth * 0.36
            let origin = CGPoint(x: baseX + drift - cloudWidth / 2, y: y)
            var cloud = Path()
            // Three overlapping ellipses read as one soft cloud.
            cloud.addEllipse(in: CGRect(x: origin.x, y: origin.y, width: cloudWidth * 0.55, height: cloudHeight))
            cloud.addEllipse(in: CGRect(x: origin.x + cloudWidth * 0.28, y: origin.y - cloudHeight * 0.32, width: cloudWidth * 0.55, height: cloudHeight * 1.15))
            cloud.addEllipse(in: CGRect(x: origin.x + cloudWidth * 0.45, y: origin.y, width: cloudWidth * 0.55, height: cloudHeight))
            context.fill(cloud, with: .color(Color.slate.opacity(0.10)))
        }
    }

    /// A few short streaks drifting steadily downward.
    private static func drawRain(context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        let columns: [CGFloat] = [0.18, 0.34, 0.52, 0.68, 0.84]
        for (index, fx) in columns.enumerated() {
            let phaseOffset = Double(index) * 0.37
            let progress = (time * 0.22 + phaseOffset).truncatingRemainder(dividingBy: 1)
            let y = size.height * CGFloat(progress)
            let streak = CGRect(x: size.width * fx, y: y, width: 1.8, height: 10)
            context.fill(
                Path(roundedRect: streak, cornerRadius: 1),
                with: .color(Color.slate.opacity(0.22))
            )
        }
    }

    /// A few small flakes drifting down slowly with a gentle sway.
    private static func drawSnow(context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        let columns: [CGFloat] = [0.15, 0.32, 0.50, 0.67, 0.85]
        for (index, fx) in columns.enumerated() {
            let phaseOffset = Double(index) * 0.41
            let progress = (time * 0.07 + phaseOffset).truncatingRemainder(dividingBy: 1)
            let sway = sin(time * 0.5 + Double(index)) * size.width * 0.015
            let flake = CGRect(
                x: size.width * fx + sway,
                y: size.height * CGFloat(progress),
                width: 3.5,
                height: 3.5
            )
            context.fill(Path(ellipseIn: flake), with: .color(Color.slate.opacity(0.24)))
        }
    }
}
