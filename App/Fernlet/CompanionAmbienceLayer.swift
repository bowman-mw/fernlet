//
//  CompanionAmbienceLayer.swift
//  Fernlet
//
//  The subtle environment layer behind the companion on Home (and only there): a very
//  soft time-of-day tint that is always on (local hour only — no location, no network),
//  plus a couple of gentle sky accents (drifting clouds / rain streaks / snowfall) when
//  weather prompts are enabled AND WeatherKit has cached conditions.
//
//  ┌─ DESIGN SOURCE ─────────────────────────────────────────────────────────────────┐
//  │ Restyled from the "Home Ambiance" mockup · badge 6a (the compose matrix:          │
//  │ time-of-day tint × weather accent, at true strength). The gradient directions,    │
//  │ colors, and opacities below trace that matrix cell-for-cell:                      │
//  │   · Dawn — warm radial from the TOP, a small rising sun glow.                     │
//  │   · Day  — cool clean radial from the TOP, a faint high sun.                      │
//  │   · Dusk — amber radial from the BOTTOM, a low warm sun.                          │
//  │   · Night— deep-blue vertical wash + upper-right sky glow, crescent moon + stars. │
//  │ Weather accents stay under half-opacity and are tuned per phase (warmer clouds    │
//  │ at dawn/dusk, cooler by day, muted/blue at night). Everything is dialed low so    │
//  │ the companion stays the hero.                                                     │
//  │                                                                                   │
//  │ Per the mockup's "a sky felt more than seen" direction, this is a FULL-BLEED      │
//  │ wash: no rounded-rect card clip. A soft radial feather dissolves the whole        │
//  │ treatment into the parchment (or dark theme) on every edge, all geometry is a     │
//  │ fraction of the slot so it composes in the wide Home strip, and night bends       │
//  │ slightly with the app appearance so it registers in either scheme.                │
//  └────────────────────────────────────────────────────────────────────────────────┘
//

import SwiftUI
import AppServices

/// Time-of-day phase for the ambience tint.
///
/// A pure hour → phase mapping (dawn 5–8, day 8–17, dusk 17–21, night otherwise) so tests can
/// pin the boundaries; ``CompanionAmbienceLayer`` keys its whole palette off it.
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

/// The single environment view behind the companion on Home: a full-bleed time-of-day sky wash
/// with celestial glow and optional weather accents.
///
/// Purely decorative: it never intercepts touches and is hidden from the accessibility tree, so
/// the tap-to-pet gesture and the UX-appearance probes are unaffected. Layers a directional
/// ``CompanionDayPhase`` tint, an always-on Canvas celestial pass (sun / crescent moon + stars),
/// and — only when a `WeatherAmbient` snapshot is supplied — slow drifting cloud/rain/snow
/// accents, all masked by an elliptical edge feather so the sky dissolves into the parchment.
/// Uses local hour only; no location or network of its own.
struct CompanionAmbienceLayer: View {
    var phase: CompanionDayPhase
    /// `nil` ⇒ time-of-day tint only (weather off, unauthorized, or unavailable).
    var ambient: WeatherAmbient?

    /// The app appearance. The sky wash is dialed low either way, but night in particular
    /// wants a touch more presence over the dark theme and a touch less over parchment, so
    /// the tint strength and the feather profile both bend slightly with the scheme.
    @Environment(\.colorScheme) private var colorScheme

    /// T1-6: pauses both `TimelineView` clocks below rather than hiding the sky — the celestial
    /// pass and the weather drift both freeze on their current frame, so the wash still renders,
    /// just without the slow parallax motion Reduce Motion asks to remove.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// A full-bleed feather: the wash reaches true strength through the middle band and
    /// dissolves to nothing at every edge, so it reads as "a sky felt more than seen"
    /// rather than a contained card. Elliptical so it stretches to the wide strip and all
    /// four sides + the corners melt into the parchment/theme evenly, softer in dark mode.
    private var edgeFeather: some ShapeStyle {
        // EllipticalGradient — its radii are FRACTIONS of the masked rect (0…1), not the
        // absolute points a RadialGradient uses, so this feathers across the whole slot at
        // any strip width without threading the GeometryReader size into a ShapeStyle. The
        // wash holds full strength through the middle band then dissolves to clear at every
        // edge/corner, a hair softer in dark mode.
        EllipticalGradient(
            gradient: Gradient(stops: [
                .init(color: .black, location: 0),
                .init(color: .black, location: colorScheme == .dark ? 0.60 : 0.66),
                .init(color: .clear, location: 1)
            ]),
            center: .center
        )
    }

    var body: some View {
        // Size-relative so the whole treatment composes in the wide Home strip: every
        // radius, glow, and accet position below is a fraction of the slot it fills.
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                // 1 · Time-of-day tint — always on. Directional per the matrix (radial from
                //     top for dawn/day, from the bottom for dusk, a vertical wash for night).
                Self.tintGradient(for: phase, size: size, scheme: colorScheme)

                // 2 · Celestial glow — also always on, mirroring the matrix's "Clear" row
                //     where the tint alone carries the sun (dawn/day/dusk) or the crescent
                //     moon + faint stars (night). Weather accents layer over this.
                TimelineView(.animation(minimumInterval: 0.5, paused: reduceMotion)) { timeline in
                    Canvas { context, size in
                        Self.drawCelestial(
                            context: &context,
                            size: size,
                            phase: phase,
                            time: timeline.date.timeIntervalSinceReferenceDate
                        )
                    }
                }

                // 3 · Weather accents — only when weather is enabled AND available. Slow,
                //     deterministic drift driven by wall-clock time; a lazy update interval
                //     keeps this far cheaper than the companion's own breath loop.
                if let ambient {
                    TimelineView(.animation(minimumInterval: 0.25, paused: reduceMotion)) { timeline in
                        Canvas { context, size in
                            Self.drawAccents(
                                context: &context,
                                size: size,
                                ambient: ambient,
                                phase: phase,
                                time: timeline.date.timeIntervalSinceReferenceDate
                            )
                        }
                    }
                }
            }
            // No rounded-rect clip: the wash is masked by a soft elliptical feather that
            // scales with the slot, so the sky dissolves into the parchment on every edge
            // instead of stopping at a card boundary. This has to be an alpha mask, not a
            // clipShape + opaque feather overlay: the parchment/theme shows THROUGH the
            // dissolved edges, so the fade must be in the layer's own alpha — an overlay
            // would only work over an opaque backdrop.
            .mask {
                Rectangle().fill(edgeFeather)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: - Time-of-day tint

    /// The directional tint view per phase, sized relative to the slot so it composes at
    /// any strip width. Radials sit at the edges (top for the rising dawn/day light, bottom
    /// for the amber dusk fall) so the shift reads as "the light changed" and leaves the
    /// parchment centre clear for the companion. Night is a deep-blue vertical wash with a
    /// faint upper-right sky glow. `scheme` nudges night's strength: a hair richer over the
    /// dark theme so the wash still registers, a hair softer over parchment.
    @ViewBuilder
    static func tintGradient(for phase: CompanionDayPhase, size: CGSize, scheme: ColorScheme) -> some View {
        // Reach for the directional radials: past the far edge so the tint fills the strip
        // from its origin edge, scaled to the slot's larger dimension.
        let reach = max(size.width, size.height) * 0.92
        switch phase {
        case .dawn:
            // Warm radial rising from the top edge. Endpoint colors sourced from
            // `tintColors` so the tint palette has one authoritative definition.
            RadialGradient(
                gradient: Gradient(colors: tintColors(for: .dawn)),
                center: .top,
                startRadius: 0,
                endRadius: reach
            )
        case .day:
            // Cool, clean radial from the top — the lightest of the four.
            RadialGradient(
                gradient: Gradient(colors: tintColors(for: .day)),
                center: .top,
                startRadius: 0,
                endRadius: reach
            )
        case .dusk:
            // Amber radial welling up from the bottom edge.
            RadialGradient(
                gradient: Gradient(colors: tintColors(for: .dusk)),
                center: .bottom,
                startRadius: 0,
                endRadius: reach
            )
        case .night:
            // Deep-blue vertical wash + a faint sky glow in the upper trailing corner. Over
            // the dark theme, lift the wash a touch so it keeps its presence; over parchment
            // ease it back so it never turns the centre muddy.
            let washBoost = scheme == .dark ? 0.10 : 0.0
            let glowBoost = scheme == .dark ? 0.06 : 0.0
            ZStack {
                LinearGradient(
                    gradient: Gradient(colors: [
                        AmbiencePalette.nightTop.opacity(AmbiencePalette.nightTopOpacity + washBoost),
                        AmbiencePalette.nightBottom.opacity(AmbiencePalette.nightBottomOpacity + washBoost)
                    ]),
                    startPoint: .top,
                    endPoint: .bottom
                )
                RadialGradient(
                    gradient: Gradient(colors: [
                        AmbiencePalette.nightGlow.opacity(0.16 + glowBoost),
                        AmbiencePalette.nightGlow.opacity(0)
                    ]),
                    center: UnitPoint(x: 0.74, y: 0.18),
                    startRadius: 0,
                    endRadius: max(size.width, size.height) * 0.72
                )
            }
        }
    }

    /// The authoritative two-stop endpoint colors per phase — the single source of truth for
    /// the wash tints. `tintGradient(for:size:scheme:)` renders these into the shipping wash
    /// (scheme-nudging night's opacity on top), and the tests assert the "≥ 2 usable colors
    /// per phase" contract against this same entry point, so the two can never drift.
    static func tintColors(for phase: CompanionDayPhase) -> [Color] {
        switch phase {
        case .dawn:
            [AmbiencePalette.dawnTint.opacity(0.42), AmbiencePalette.dawnTint.opacity(0)]
        case .day:
            [AmbiencePalette.dayTint.opacity(0.28), AmbiencePalette.dayTint.opacity(0)]
        case .dusk:
            [AmbiencePalette.duskTint.opacity(0.40), AmbiencePalette.duskTint.opacity(0)]
        case .night:
            [
                AmbiencePalette.nightTop.opacity(AmbiencePalette.nightTopOpacity),
                AmbiencePalette.nightBottom.opacity(AmbiencePalette.nightBottomOpacity)
            ]
        }
    }

    // MARK: - Celestial glow (always on, per the matrix's "Clear" row)

    private static func drawCelestial(
        context: inout GraphicsContext,
        size: CGSize,
        phase: CompanionDayPhase,
        time: TimeInterval
    ) {
        switch phase {
        case .dawn:
            // A small warm sun rising in the upper-trailing corner.
            drawSun(
                context: &context,
                center: CGPoint(x: size.width * 0.80, y: size.height * 0.16),
                radius: min(size.width, size.height) * 0.16,
                core: AmbiencePalette.dawnSunCore,
                edge: AmbiencePalette.dawnSunEdge,
                coreOpacity: 0.70,
                time: time
            )
        case .day:
            // A faint, high, bright-white sun — barely there, just a lift of light.
            drawSun(
                context: &context,
                center: CGPoint(x: size.width * 0.82, y: size.height * 0.14),
                radius: min(size.width, size.height) * 0.20,
                core: AmbiencePalette.daySunCore,
                edge: AmbiencePalette.daySunEdge,
                coreOpacity: 0.42,
                time: time
            )
        case .dusk:
            // A low, warm sun sinking toward the bottom-trailing edge.
            drawSun(
                context: &context,
                center: CGPoint(x: size.width * 0.80, y: size.height * 0.74),
                radius: min(size.width, size.height) * 0.16,
                core: AmbiencePalette.duskSunCore,
                edge: AmbiencePalette.duskSunEdge,
                coreOpacity: 0.66,
                time: time
            )
        case .night:
            drawMoon(context: &context, size: size)
            drawStars(context: &context, size: size, time: time)
        }
    }

    /// A soft radial sun with a very gentle breathing glow. `coreOpacity` scales the whole
    /// thing so the day sun stays a faint high glimmer while dawn/dusk read a touch warmer.
    private static func drawSun(
        context: inout GraphicsContext,
        center: CGPoint,
        radius: CGFloat,
        core: Color,
        edge: Color,
        coreOpacity: Double,
        time: TimeInterval
    ) {
        // Slow breath: opacity drifts within a narrow band so the glow feels alive but calm.
        let breath = 0.85 + 0.15 * sin(time * 0.42)
        let peak = coreOpacity * breath
        let rect = CGRect(
            x: center.x - radius, y: center.y - radius,
            width: radius * 2, height: radius * 2
        )
        context.fill(
            Path(ellipseIn: rect),
            with: .radialGradient(
                Gradient(colors: [core.opacity(peak), edge.opacity(0)]),
                center: center,
                startRadius: 0,
                endRadius: radius
            )
        )
    }

    /// A small crescent moon in the upper-trailing corner: a pale disc with a slightly
    /// offset "bite" punched out, matching the matrix's inset-shadow crescent.
    private static func drawMoon(context: inout GraphicsContext, size: CGSize) {
        let radius = min(size.width, size.height) * 0.075
        let center = CGPoint(x: size.width * 0.82, y: size.height * 0.18)
        let full = CGRect(
            x: center.x - radius, y: center.y - radius,
            width: radius * 2, height: radius * 2
        )
        // Punch a shifted disc out of the full disc to leave a crescent.
        let bite = full.offsetBy(dx: radius * 0.55, dy: radius * 0.34)
        var crescent = Path(ellipseIn: full)
        crescent.addPath(Path(ellipseIn: bite))
        context.fill(crescent, with: .color(AmbiencePalette.moon.opacity(0.85)), style: .init(eoFill: true))
    }

    /// A couple of faint stars that twinkle slowly out of phase with one another.
    private static func drawStars(context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        // (fractional x, fractional y, twinkle phase offset)
        let stars: [(CGFloat, CGFloat, Double)] = [
            (0.66, 0.30, 0.0),
            (0.28, 0.24, 1.1),
            (0.48, 0.14, 0.6)
        ]
        for (fx, fy, offset) in stars {
            // Opacity eases between ~0.25 and ~0.9 like the mockup's twinkle keyframes.
            let twinkle = 0.25 + 0.65 * (0.5 + 0.5 * sin(time * 0.9 + offset * .pi))
            let side: CGFloat = 2.6
            let rect = CGRect(
                x: size.width * fx - side / 2,
                y: size.height * fy - side / 2,
                width: side, height: side
            )
            context.fill(Path(ellipseIn: rect), with: .color(AmbiencePalette.star.opacity(twinkle)))
        }
    }

    // MARK: - Weather accents (tuned per phase)

    private static func drawAccents(
        context: inout GraphicsContext,
        size: CGSize,
        ambient: WeatherAmbient,
        phase: CompanionDayPhase,
        time: TimeInterval
    ) {
        switch ambient.sky {
        case .clear:
            // The tint's sun/moon already carries "clear" — nothing to add here.
            break
        case .clouds:
            drawClouds(context: &context, size: size, phase: phase, time: time, count: 2)
        case .rain:
            drawClouds(context: &context, size: size, phase: phase, time: time, count: 1)
            drawRain(context: &context, size: size, phase: phase, time: time)
        case .snow:
            drawSnow(context: &context, size: size, phase: phase, time: time)
        }
    }

    /// One or two soft cloud blobs drifting very slowly side to side, tinted per phase
    /// (warm off-white at dawn/dusk, clean white by day, muted blue-grey at night).
    private static func drawClouds(
        context: inout GraphicsContext,
        size: CGSize,
        phase: CompanionDayPhase,
        time: TimeInterval,
        count: Int
    ) {
        let (color, lead, trail) = AmbiencePalette.cloud(for: phase)
        for index in 0..<count {
            let baseX = size.width * (index == 0 ? 0.26 : 0.74)
            let drift = sin(time * 0.06 + Double(index) * 2.4) * size.width * 0.045
            let y = size.height * (index == 0 ? 0.16 : 0.30)
            let cloudWidth = size.width * (index == 0 ? 0.26 : 0.20)
            let cloudHeight = cloudWidth * 0.36
            let origin = CGPoint(x: baseX + drift - cloudWidth / 2, y: y)
            let opacity = index == 0 ? lead : trail
            var cloud = Path()
            // Three overlapping ellipses read as one soft cloud.
            cloud.addEllipse(in: CGRect(x: origin.x, y: origin.y, width: cloudWidth * 0.55, height: cloudHeight))
            cloud.addEllipse(in: CGRect(x: origin.x + cloudWidth * 0.28, y: origin.y - cloudHeight * 0.32, width: cloudWidth * 0.55, height: cloudHeight * 1.15))
            cloud.addEllipse(in: CGRect(x: origin.x + cloudWidth * 0.45, y: origin.y, width: cloudWidth * 0.55, height: cloudHeight))
            context.fill(cloud, with: .color(color.opacity(opacity)))
        }
    }

    /// A few short diagonal streaks falling gently — cool blue-grey, low opacity, tilted
    /// like the mockup's `rotate(12deg)` rain.
    private static func drawRain(
        context: inout GraphicsContext,
        size: CGSize,
        phase: CompanionDayPhase,
        time: TimeInterval
    ) {
        let color = AmbiencePalette.rain(for: phase)
        let columns: [CGFloat] = [0.20, 0.36, 0.54, 0.70]
        let tilt = 12.0 * .pi / 180.0
        for (index, fx) in columns.enumerated() {
            let phaseOffset = Double(index) * 0.37
            // Ease in/out at the top and bottom so streaks fade rather than pop.
            let progress = (time * 0.20 + phaseOffset).truncatingRemainder(dividingBy: 1)
            let fade = min(1, progress / 0.2) * min(1, (1 - progress) / 0.2)
            let x = size.width * fx
            let y = size.height * CGFloat(progress)
            let streak = CGRect(x: x, y: y, width: 1.8, height: 11)
            let path = Path(roundedRect: streak, cornerRadius: 1)
            // Rotate about the streak's own top for the gentle diagonal.
            let transform = CGAffineTransform(translationX: x, y: y)
                .rotated(by: tilt)
                .translatedBy(x: -x, y: -y)
            context.fill(path.applying(transform), with: .color(color.opacity(0.55 * fade)))
        }
    }

    /// A few small flakes drifting down slowly with a gentle sway, tinted per phase (warm
    /// white at dawn/dusk, clean white by day, cool blue-white at night).
    private static func drawSnow(
        context: inout GraphicsContext,
        size: CGSize,
        phase: CompanionDayPhase,
        time: TimeInterval
    ) {
        let color = AmbiencePalette.snow(for: phase)
        let columns: [CGFloat] = [0.16, 0.34, 0.52, 0.70, 0.86]
        for (index, fx) in columns.enumerated() {
            let phaseOffset = Double(index) * 0.41
            let progress = (time * 0.06 + phaseOffset).truncatingRemainder(dividingBy: 1)
            let fade = min(1, progress / 0.2) * min(1, (1 - progress) / 0.15)
            let sway = sin(time * 0.5 + Double(index)) * size.width * 0.02
            let side: CGFloat = index.isMultiple(of: 2) ? 4 : 3.2
            let flake = CGRect(
                x: size.width * fx + sway - side / 2,
                y: size.height * CGFloat(progress),
                width: side,
                height: side
            )
            context.fill(Path(ellipseIn: flake), with: .color(color.opacity(0.85 * fade)))
        }
    }
}

// MARK: - Local ambience palette

/// Colors traced directly from the badge-6a matrix, kept local to this file so the shared
/// theme palette is never touched.
///
/// Each is a plain `Color` (no light/dark variant): this layer is a fixed sky wash that reads
/// the same in either app appearance, and the low opacities keep it from fighting the parchment
/// in light mode or the dark theme. The per-phase helpers (`cloud`/`rain`/`snow`) tune the
/// weather accents warmer at dawn/dusk, cleaner by day, and cooler at night.
private enum AmbiencePalette {
    // Time-of-day tint bases — rgba stops from the "Clear" matrix row.
    static let dawnTint = Color(red: 244 / 255, green: 176 / 255, blue: 146 / 255)   // rgba(244,176,146)
    static let dayTint  = Color(red: 158 / 255, green: 200 / 255, blue: 224 / 255)   // rgba(158,200,224)
    static let duskTint = Color(red: 226 / 255, green: 150 / 255, blue:  74 / 255)   // rgba(226,150,74)
    static let nightTop    = Color(red: 58 / 255, green: 68 / 255, blue: 112 / 255)  // rgba(58,68,112)
    static let nightBottom = Color(red: 44 / 255, green: 52 / 255, blue:  90 / 255)  // rgba(44,52,90)
    static let nightGlow   = Color(red: 196 / 255, green: 204 / 255, blue: 232 / 255) // rgba(196,204,232)
    // Night wash base opacities — shared by `tintColors` (the source of truth) and the
    // production night gradient, which adds a small dark-mode boost on top of these.
    static let nightTopOpacity    = 0.44
    static let nightBottomOpacity = 0.50

    // Celestial glows.
    static let dawnSunCore = Color(red: 251 / 255, green: 217 / 255, blue: 166 / 255) // #FBD9A6
    static let dawnSunEdge = Color(red: 243 / 255, green: 178 / 255, blue: 106 / 255) // #F3B26A
    static let daySunCore  = Color(red: 255 / 255, green: 248 / 255, blue: 224 / 255) // rgba(255,248,224)
    static let daySunEdge  = Color(red: 255 / 255, green: 240 / 255, blue: 200 / 255) // rgba(255,240,200)
    static let duskSunCore = Color(red: 246 / 255, green: 197 / 255, blue: 131 / 255) // #F6C583
    static let duskSunEdge = Color(red: 226 / 255, green: 155 / 255, blue:  84 / 255) // #E29B54
    static let moon = Color(red: 232 / 255, green: 236 / 255, blue: 250 / 255)        // rgba(232,236,250)
    static let star = Color(red: 232 / 255, green: 236 / 255, blue: 250 / 255)        // #E8ECFA

    // Weather accent colors, tuned per phase.

    /// Cloud fill + (lead, trail) opacities for the given phase.
    static func cloud(for phase: CompanionDayPhase) -> (Color, Double, Double) {
        switch phase {
        case .dawn:
            (Color(red: 255 / 255, green: 250 / 255, blue: 242 / 255), 0.72, 0.50) // warm off-white
        case .day:
            (Color(red: 255 / 255, green: 255 / 255, blue: 252 / 255), 0.80, 0.60) // clean white
        case .dusk:
            (Color(red: 255 / 255, green: 242 / 255, blue: 226 / 255), 0.70, 0.50) // amber-tinted white
        case .night:
            (Color(red: 120 / 255, green: 130 / 255, blue: 166 / 255), 0.55, 0.40) // muted blue-grey
        }
    }

    /// Cool blue-grey rain streak color, slightly bluer at night.
    static func rain(for phase: CompanionDayPhase) -> Color {
        switch phase {
        case .night:
            Color(red: 150 / 255, green: 162 / 255, blue: 190 / 255) // rgba(150,162,190)
        default:
            Color(red: 114 / 255, green: 126 / 255, blue: 146 / 255) // ~rgba(114,126,146)
        }
    }

    /// Snowflake color, warm/clean by day and cool blue-white at night.
    static func snow(for phase: CompanionDayPhase) -> Color {
        switch phase {
        case .dawn, .dusk:
            Color(red: 255 / 255, green: 252 / 255, blue: 246 / 255) // warm white
        case .day:
            Color.white
        case .night:
            Color(red: 232 / 255, green: 236 / 255, blue: 250 / 255) // cool blue-white
        }
    }
}
