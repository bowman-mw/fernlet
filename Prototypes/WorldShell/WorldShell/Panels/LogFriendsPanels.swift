import SwiftUI

/// Quick log, in the middle of the item bar: today's six tiles with pixel icons. Water logs a glass
/// (the drops fill), Meal logs the first cookie (a stamp), the rest say what would open.
struct LogPanel: View {
    let model: WorldShellModel

    /// One quick-log tile.
    struct Tile: Identifiable {
        let id: String
        let name: String
        let icon: PixelSprite
    }

    private let tiles = [
        Tile(id: "meal", name: "Meal", icon: PixelSprites.onigiri), Tile(id: "water", name: "Water", icon: PixelSprites.drop),
        Tile(id: "sleep", name: "Sleep", icon: PixelSprites.moonDark), Tile(id: "journal", name: "Journal", icon: PixelSprites.diary),
        Tile(id: "workout", name: "Workout", icon: PixelSprites.shoe), Tile(id: "mood", name: "Mood", icon: PixelSprites.happy),
    ]

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: 3), spacing: 7) {
            ForEach(tiles) { tile in
                Button { tap(tile.id, name: tile.name) } label: {
                    VStack(spacing: 4) {
                        PixelSpriteView(sprite: tile.icon, scale: tile.icon.width <= 8 ? 4 : 3)
                            .frame(height: 36)
                        Text(tile.name).font(.caption.weight(.semibold)).foregroundStyle(FernColors.bark)
                    }
                    .frame(maxWidth: .infinity, minHeight: 84)
                    .background(FernColors.cream, in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(FernColors.rule, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tile.name)
            }
        }
        Text("Meal: your first cookie earns a stamp. Water fills a drop in the status bar.")
            .font(.caption).foregroundStyle(FernColors.dim)
    }

    private func tap(_ id: String, name: String) {
        switch id {
        case "water": model.logWater()
        case "meal": model.logMeal()
        default: model.showToast("The \(name.lowercased()) sheet opens here, as it does from any tab today.")
        }
    }
}

/// Friends, as today: the shared album and who's nearby. Friends' photos never go on the map.
struct FriendsPanel: View {
    let model: WorldShellModel

    var body: some View {
        CardLabel(text: "Your shared album")
        if model.level.hasPhotos {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 12) {
                ForEach(Array(WorldFixtures.friendPhotos.enumerated()), id: \.element.id) { index, photo in
                    PhotoPrint(photo: photo, width: 130, caption: true)
                        .rotationEffect(.degrees(index % 2 == 0 ? -1.4 : 1.6))
                }
            }
            .padding(.horizontal, 3)
        } else {
            ShellCard {
                Text("No photos yet").font(.subheadline.weight(.semibold))
                Text("Photos you take together show up here.").font(.caption).foregroundStyle(FernColors.dim)
            }
        }
        ShellCard {
            Text("Nobody nearby right now. Friends features work when you're together.")
                .font(.caption).foregroundStyle(FernColors.dim)
        }
    }
}

/// The full photo wall the strip opens: the friend prints with Recent bites among them, captioned.
struct WallPanel: View {
    let model: WorldShellModel

    var body: some View {
        let photos = Array(WorldFixtures.friendPhotos.prefix(2)) + [WorldFixtures.recentBite] + Array(WorldFixtures.friendPhotos.dropFirst(2))
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 12) {
            ForEach(Array(photos.enumerated()), id: \.element.id) { index, photo in
                PhotoPrint(photo: photo, width: 130, caption: true)
                    .rotationEffect(.degrees(index % 2 == 0 ? -2 : 2))
            }
        }
        .padding(.horizontal, 3)
        Text("Friend photos, picked fresh each launch as today, with Recent bites among them.")
            .font(.caption).foregroundStyle(FernColors.dim)
    }
}

/// Customize: the same stack as today (slot picker, Wardrobe, Creation Studio, Save). The
/// built-in items have hand-drawn pixel versions, so the companion on the map wears them.
struct CustomizePanel: View {
    let model: WorldShellModel

    var body: some View {
        ShellCard {
            CardLabel(text: "Wardrobe")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                ForEach(Outfit.allCases) { outfit in
                    Button {
                        model.outfit = outfit
                        model.say(outfit == .none ? "Back to basics." : "How do I look?", for: 2.5)
                    } label: {
                        Text(outfit.label)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(model.outfit == outfit ? FernColors.mossInk : FernColors.bark)
                            .frame(maxWidth: .infinity, minHeight: 36)
                            .background(model.outfit == outfit ? FernColors.moss.opacity(0.14) : FernColors.parchment, in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(model.outfit == outfit ? FernColors.moss : FernColors.rule, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(model.outfit == outfit ? .isSelected : [])
                }
            }
        }
        ShellCard {
            HStack(alignment: .top, spacing: 12) {
                PixelCompanionView(state: model.careState, ride: .onFoot, outfit: model.outfit)
                    .scaleEffect(1.5)
                    .frame(width: 60, height: 66)
                    .background(FernColors.fog, in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 4) {
                    Text("On the map").font(.subheadline.weight(.semibold))
                    Text("Built-in items get a pixel version drawn by hand. Things you draw in the Creation Studio are shrunk and recoloured on the phone, so they need no extra drawing. Glasses come off on a tired or sick day, as today.")
                        .font(.caption).foregroundStyle(FernColors.dim)
                }
            }
        }
        ShellCard {
            LinkRow(title: "Slot picker") { model.showToast("The slot picker opens here, as today.") }
            LinkRow(title: "Creation Studio") { model.showToast("The Creation Studio opens here, as today.") }
            LinkRow(title: "Closet") { model.showToast("The closet opens here, as today.") }
        }
    }
}
