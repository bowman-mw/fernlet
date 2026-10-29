//
//  AppleWeatherAttribution.swift
//  Fernlet
//
//  The credit Apple's WeatherKit terms ask of an app that shows anything made from Apple's weather
//  data (the owner's pick, 2026-10-25). Fernlet shows only what it makes from the current conditions —
//  the weather on the map, the gentler-day note, the short-walk offer — which the terms call a
//  value-added product: one must credit " Weather" and say that the data Apple provides has been
//  modified (WeatherKit's "Get started" guide, "Apple Weather and third-party attribution"; the
//  Developer Program License Agreement, Attachment 8). The two weather-made cards carry
//  `AppleWeatherCaption`; Settings → AI & data sources and Acknowledgments carry the mark, the notice
//  and Apple's legal page of weather data sources. The map's rain and snow are decoration and carry none.
//
//  The mark is Apple's text form, the Apple logo (U+F8FF) and "Weather", as Apple's guide writes it,
//  drawn in the system font, the only face that has the logo. Nothing is fetched to draw it: the image
//  marks `WeatherService.attribution` hands out would need a download the no-tracking wall has no
//  client for. The legal page is a link Safari opens on a tap; the app never fetches it, and its host
//  is a "not fetched" row of `NoTrackingBoundaryTests.permittedDestinations`. `AppleWeatherAttributionTests`
//  pins the mark, the page and where each piece is drawn.
//

import SwiftUI
import FernletUI

/// Apple's WeatherKit attribution: the Apple Weather mark, how it is spoken, and Apple's legal page of
/// weather data sources.
///
/// Read by ``AppleWeatherCaption`` (the weather-made Home cards), ``AppleWeatherNotice`` (under the
/// weather switch in Settings) and the Acknowledgments screen's weather section.
enum AppleWeatherAttribution {
    /// The Apple Weather mark in text, as Apple's WeatherKit guide writes it: the Apple logo (U+F8FF),
    /// which only the system font draws, and "Weather". A trademark, so it is drawn `verbatim` and never
    /// translated.
    static let mark = "\u{F8FF} Weather"

    /// The mark's spoken name, so VoiceOver says "Apple Weather" rather than reading a private-use
    /// character. WeatherKit's own `serviceName`, the same in every language.
    static let spokenMark = "Apple Weather"

    /// Apple's legal attribution page of WeatherKit's data sources. On 2026-10-25 it redirected to
    /// developer.apple.com/weatherkit/data-source-attribution/, the page Apple's guide links as "other
    /// data sources". Safari opens it when the user taps ``AppleWeatherSourcesLink``; Fernlet never
    /// fetches it.
    static let legalPageURL = URL(string: "https://weather-data.apple.com/legal-attribution.html")

    /// The mark as a `Text`, to sit inside a sentence: semibold in the system font at `style`, so it
    /// scales with Larger Text beside the Fernlet face around it, and spoken as ``spokenMark``.
    static func markText(_ style: Font.TextStyle) -> Text {
        Text(verbatim: mark)
            .font(.system(style, weight: .semibold))
            .accessibilityLabel(Text(verbatim: spokenMark))
    }
}

/// The line at the foot of a Home card made from the weather: "From  Weather, modified by Fernlet",
/// the credit and the notice WeatherKit's terms ask of a value-added product, spoken "From Apple
/// Weather, modified by Fernlet".
///
/// Drawn by `AmbientCardsView` on the gentler-day card and on the short-walk offer, the only offer the
/// weather decides.
struct AppleWeatherCaption: View {
    var body: some View {
        Text("From \(AppleWeatherAttribution.markText(.caption)), modified by Fernlet",
             comment: "Caption at the foot of a Home card made from Apple's weather data. %@ is the Apple Weather mark (the Apple logo and \"Weather\"), a trademark that stays as it is in every language. Apple's terms ask the card to credit Apple Weather and to say the data was changed.")
            .font(.fernlet(.labelSmall))
            .foregroundStyle(Color.slate)
            .fernletWrappingText()
            // VoiceOver: inside a sentence the mark loses its own label (XCUITest read the caption as
            // "From  Weather, …", 2026-10-25), so the caption says it whole, from the same key.
            .accessibilityLabel(Text("From \(Text(verbatim: AppleWeatherAttribution.spokenMark)), modified by Fernlet"))
    }
}

/// Under the weather switch in Settings → AI & data sources: two framed rows like the switches above
/// it (main-merge-2 follow-up 3, owner 2026-10-26), the mark over the notice that Fernlet modifies the
/// data Apple provides, then ``AppleWeatherSourcesLink`` in a row of its own, as Acknowledgments draws
/// them.
///
/// Drawn whether the switch is on or off, so the credit sits where the feature is chosen. Its body is
/// the two rows with no container, so ``FernletFramedSection`` splits them with its hairline.
struct AppleWeatherNotice: View {
    var body: some View {
        FernletRowLabel(title: AppleWeatherAttribution.markText(.body),
                        detail: Text("Fernlet modifies the data Apple provides into its own gentle signals, never a forecast.",
                                     comment: "Settings, under the weather switch and the Apple Weather mark: the notice Apple's terms ask for, that Fernlet changes Apple's weather data. 'Gentle signals' are the weather on the map, the gentler-day note and the short-walk idea."))
            // A two-line row takes the kit's row padding above and below its words, as the switches do.
            .padding(.vertical, 7)
        AppleWeatherSourcesLink()
    }
}

/// "Weather data sources" ↗: Apple's legal page of weather data sources, handed to Safari on a tap.
///
/// Draws nothing if ``AppleWeatherAttribution/legalPageURL`` could not be built (it is a fixed literal,
/// so it always can). Used by ``AppleWeatherNotice`` and the Acknowledgments screen.
struct AppleWeatherSourcesLink: View {
    var body: some View {
        if let url = AppleWeatherAttribution.legalPageURL {
            Link(destination: url) {
                HStack(spacing: 6) {
                    Text("Weather data sources",
                         comment: "Link to Apple's legal page listing where its weather data comes from. Opens in Safari.")
                        .font(.fernlet(.label))
                    Image(systemName: "arrow.up.right")
                        .font(.caption.weight(.semibold))
                        .accessibilityHidden(true)
                }
                .foregroundStyle(Color.mossInk)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .accessibilityHint(Text("Opens Apple's page in Safari",
                                    comment: "VoiceOver hint on the Weather data sources link: it leaves Fernlet for Apple's page in Safari."))
            .accessibilityIdentifier("weather.dataSources")
        }
    }
}
