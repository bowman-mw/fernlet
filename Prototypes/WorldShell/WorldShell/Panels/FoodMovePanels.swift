import SwiftUI

/// Food, as today's Food tab: the day's meals, water, Recent bites and the recipe you're cooking.
struct FoodPanel: View {
    let model: WorldShellModel

    var body: some View {
        mealCard("Breakfast · 8:10", "Oatmeal with blueberries")
        mealCard("Lunch · 12:05", "Lentil soup and bread")
        ShellCard {
            CardLabel(text: "Dinner")
            HStack {
                Text("Nothing yet").font(.caption).foregroundStyle(FernColors.dim)
                Spacer()
                Button("Log") { model.logMeal() }.font(.footnote.weight(.semibold)).foregroundStyle(FernColors.mossInk)
            }
        }
        ShellCard {
            HStack {
                Text("Water").font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(model.water) of 8").font(.caption).foregroundStyle(FernColors.dim)
            }
            HStack(spacing: 4) {
                ForEach(0..<8, id: \.self) { index in
                    PixelSpriteView(sprite: index < model.water ? PixelSprites.drop : PixelSprites.emptyDrop)
                }
                Spacer()
                PillButton(title: "+ Glass") { model.logWater() }
            }
        }
        ShellCard {
            CardLabel(text: "Recent bites")
            HStack(spacing: 8) {
                PhotoPrint(photo: WorldFixtures.recentBite, width: 58)
                Text("Your meal photos also sit on the map where you ate them.").font(.caption).foregroundStyle(FernColors.dim)
            }
        }
        ShellCard {
            Text("Pick up where you left off").font(.subheadline.weight(.semibold))
            Text("Shakshuka · step 3 of 6").font(.caption).foregroundStyle(FernColors.dim)
            PillButton(title: "Resume") { model.showToast("The cooking card opens here, as today.") }
        }
    }

    private func mealCard(_ label: String, _ name: String) -> some View {
        ShellCard {
            CardLabel(text: label)
            Text(name).font(.subheadline.weight(.semibold))
        }
    }
}

/// Move, as today's Move tab: the week, today's plan, the last run with its route, saved trails.
struct MovePanel: View {
    let model: WorldShellModel

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(["M", "T", "W", "T", "F", "S", "S"].enumerated()), id: \.offset) { index, day in
                VStack(spacing: 5) {
                    Text(day).font(.caption2.weight(.semibold))
                    Circle().fill(index < 2 ? FernColors.moss : FernColors.bark.opacity(0.13)).frame(width: 6, height: 6)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .background(index == 3 ? FernColors.moss.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(8)
        .background(FernColors.cream, in: RoundedRectangle(cornerRadius: 15))
        .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(FernColors.rule, lineWidth: 1))
        ShellCard {
            CardLabel(text: "Today")
            Text("Upper body").font(.subheadline.weight(.semibold))
            Text("6 exercises · about 40 min").font(.caption).foregroundStyle(FernColors.dim)
            PillButton(title: "Start") { model.showToast("The guided runner starts here, as today.") }
        }
        ShellCard {
            CardLabel(text: "Tuesday")
            Text("Easy run").font(.subheadline.weight(.semibold))
            Text("3.2 km · 24 m climbed · 27 min").font(.caption).foregroundStyle(FernColors.dim)
            RouteMini(route: model.decoy ? [] : RecordedRoutes.riverRoad)
            Text("Route kept on this iPhone").font(.caption2).foregroundStyle(FernColors.dim)
        }
        if !model.visibleTrails.isEmpty {
            ShellCard {
                HStack {
                    Text("Trails").font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("\(model.visibleTrails.count) saved").font(.caption).foregroundStyle(FernColors.dim)
                }
                Text(model.level == .year ? "Home to the park · Oak Park loop · River road" : "Home to the park · Oak Park loop")
                    .font(.caption).foregroundStyle(FernColors.dim)
            }
        }
    }
}

/// A small route drawing on plain ground, Fernlet's own (the route card's look, no map tiles).
struct RouteMini: View {
    let route: [GeoPoint]

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(FernColors.rgb(0xE9E4D2)))
            guard let first = route.first, route.count > 1 else { return }
            let box = route.map { $0.metres(from: first) }
            let east = box.map(\.east), north = box.map(\.north)
            let minE = east.min() ?? 0, maxE = east.max() ?? 1, minN = north.min() ?? 0, maxN = north.max() ?? 1
            let scale = min((size.width - 24) / max(1, maxE - minE), (size.height - 16) / max(1, maxN - minN))
            var path = Path()
            for (index, step) in box.enumerated() {
                let point = CGPoint(x: 12 + (step.east - minE) * scale, y: size.height - 8 - (step.north - minN) * scale)
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            context.stroke(path, with: .color(FernColors.trail), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
        }
        .frame(height: 84)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(FernColors.rule, lineWidth: 1))
        .accessibilityHidden(true)
    }
}
