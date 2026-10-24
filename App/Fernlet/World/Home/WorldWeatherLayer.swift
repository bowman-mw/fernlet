import AppServices
import SwiftUI

/// Rain or snow over the map (design `b1-home-weather`, approved 2026-10-23): with the clock and weather
/// gone from the top, the weather shows on the map itself. The sky comes from WeatherKit exactly as
/// Home's ambience reads it (`WeatherKitService.currentAmbient()`), only while weather prompts are on.
///
/// Pixel streaks (rain) or pixel flakes (snow) in a fixed scatter over a faint cool wash, falling slowly;
/// Reduce Motion draws them still, and they stop while the map is covered. Decoration: no touches, and
/// VoiceOver reads the weather from the map's own label.
struct WorldWeatherLayer: View {
    let sky: AmbientSky
    /// Whether the map is on screen; off, the fall stops.
    let isActive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How many streaks or flakes fall (bounded).
    static let count = 70

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: reduceMotion || !isActive)) { timeline in
            Canvas { context, size in
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Self.wash.opacity(0.12)))
                let fall = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
                for index in 0..<Self.count {
                    context.fill(Path(Self.mark(index, sky: sky, fall: fall, in: size)), with: .color(colour))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var colour: Color {
        sky == .snow ? Color.white.opacity(0.9) : WorldPalette.rgb(0x7FA9C4).opacity(0.6)
    }

    /// The cool wash under the weather.
    private static let wash = WorldPalette.rgb(0x5B7A8F)

    /// Where mark `index` is at time `fall`: a fixed scatter (the design's own spacing) drifting down the
    /// screen and wrapping, rain faster than snow.
    static func mark(_ index: Int, sky: AmbientSky, fall: TimeInterval, in size: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return .zero }
        let x = CGFloat((index * 53) % max(Int(size.width), 1))
        let speed: Double = sky == .snow ? 22 : 160
        let start = Double((index * 97) % max(Int(size.height), 1))
        let y = CGFloat((start + fall * speed).truncatingRemainder(dividingBy: Double(size.height)))
        return sky == .snow ? CGRect(x: x, y: y, width: 4, height: 4) : CGRect(x: x, y: y, width: 3, height: 12)
    }
}
