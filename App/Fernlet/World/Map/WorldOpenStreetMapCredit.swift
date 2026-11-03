import FernletUI
import SwiftUI

/// The small "© OpenStreetMap" a map shows when it draws land and water from `WorldShore.pack`
/// (Docs/World-Shore-Pack.md, "Attribution"): the OSMF's attribution guideline puts the credit on or beside the map, where
/// nobody has to interact to see it, so Acknowledgments alone would not do. A tap hands the copyright page to Safari; the
/// app sends it nothing and holds no client for it (a "not fetched" row of `NoTrackingBoundaryTests.permittedDestinations`).
///
/// The credit's own words are a notice, so they stay as written in every language; VoiceOver's label is translated.
struct WorldOpenStreetMapCredit: View {
    /// The page the OSMF asks a credit to link: it says the data is under the ODbL. A constant, checked by the host wall.
    static let copyrightURL = URL(string: "https://www.openstreetmap.org/copyright")

    var body: some View {
        if let url = Self.copyrightURL {
            Link(destination: url) {
                Text(verbatim: "© OpenStreetMap")
                    .font(.fernlet(.labelSmall))
                    .foregroundStyle(WorldPalette.dim)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(WorldPalette.paper, in: Rectangle())
            }
            .accessibilityLabel(Text("Map data from OpenStreetMap", comment: "VoiceOver label of the small map credit; it opens OpenStreetMap's copyright page."))
            .accessibilityInputLabels([Text(verbatim: "OpenStreetMap")])
        }
    }
}
