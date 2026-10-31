import FernletUI
import SwiftUI

/// The Stamp book's Passport row (World-Passport-Spec §9, owner: "Stay in today"): "Sprout's passport" with the
/// countries found, which opens Sprout's passport on page 2. Shown only where the passport's presenter is in the
/// environment (under the app's root).
struct StampBookPassportRow: View {
    var store: FernletStore
    @Environment(WorldPassportPresenter.self) private var passport: WorldPassportPresenter?
    @State private var library: PassportLibrary

    init(store: FernletStore) {
        self.store = store
        _library = State(initialValue: PassportLibrary(openAtlas: { store.worldFog.atlas.openedAtlas },
                                                       seaNeighbours: { store.worldFog.atlas.seaNeighbours() }))
    }

    var body: some View {
        if let passport {
            let countries = library.progress(of: store.worldFog.atlas.book).countryCount
            Button { passport.open(page: 2) } label: {
                FernletCard {
                    HStack(spacing: 10) {
                        WorldSpriteView(sprite: WorldSprites.stampMed, scale: 3, tint: nil)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(PassportPageCopy.stampBookRow)
                                .font(.fernlet(.headerMedium))
                                .foregroundStyle(WorldPalette.bark)
                            Text(PassportPageCopy.countriesFound(countries))
                                .font(.fernlet(.label))
                                .foregroundStyle(WorldPalette.dim)
                        }
                        .fernletWrappingText()
                        Spacer(minLength: 8)
                        WorldSpriteView(sprite: WorldSprites.chevR, scale: 2, tint: WorldPalette.iconInk)
                            .accessibilityHidden(true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityInputLabels([Text(PassportPageCopy.stampBookRow), Text(PassportBookCopy.passport)])
            .accessibilityIdentifier("stampBook.passport")
        }
    }
}
