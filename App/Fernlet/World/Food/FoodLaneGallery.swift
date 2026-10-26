import SwiftUI

#if DEBUG
import AppServices
import FernletDomainModel
import FernletUI
import UIKit

/// The Food screens `FERNLET_UI_TEST_FOOD_SCREEN` opens over the Food panel, with fixtures, for the World
/// build's screenshots (lane food-log): sheets and steps a simulator can't reach by tapping (no camera,
/// no web lookup, a capture that needs a photo). DEBUG only; the raw values are test tokens.
nonisolated enum FoodLaneScreen: String, CaseIterable, Identifiable, Sendable {
    case meal, macros, review, adjust, serving, recent, targets, chooser, veil, camera, cameraOff
    case remember, remembered, labelScan, productReview, mealPhoto

    var id: String { rawValue }

    /// Whether the screen is a full-screen cover rather than a sheet.
    var isCover: Bool { self == .camera }
}

extension View {
    /// Opens `FERNLET_UI_TEST_FOOD_SCREEN`'s screen once Food appears (DEBUG; a no-op in Release).
    func foodLaneGallery(store: FernletStore) -> some View {
        modifier(FoodLaneGalleryHook(store: store))
    }
}

/// Presents the requested Food screen with fixtures (``FoodLaneScreen``).
private struct FoodLaneGalleryHook: ViewModifier {
    let store: FernletStore
    @State private var sheet: FoodLaneScreen?
    @State private var cover: FoodLaneScreen?

    func body(content: Content) -> some View {
        content
            .task {
                guard sheet == nil, cover == nil,
                      let wanted = UITestSupport.foodLaneScreen.flatMap(FoodLaneScreen.init(rawValue:)) else { return }
                if wanted.isCover { cover = wanted } else { sheet = wanted }
            }
            .sheet(item: $sheet) { screen in
                FoodLaneGallerySheet(store: store, screen: screen)
            }
            .fullScreenCover(item: $cover) { _ in
                FoodCaptureCameraView(onBarcode: { _ in }, onLabel: { _ in }, onPhoto: { _ in }, onLibraryPick: { _ in },
                                      onAddByHand: {}, onUnavailable: {}, onClose: { cover = nil },
                                      showsLiveCamera: false)
            }
    }
}

/// One fixture screen, presented as the app presents it.
private struct FoodLaneGallerySheet: View {
    let store: FernletStore
    let screen: FoodLaneScreen

    var body: some View {
        switch screen {
        case .meal:
            MealSheet(store: store, seed: MealSheetSeed(description: "Scrambled eggs and toast"))
                .fernletFoodSheet(anchor: "gallery.meal")
        case .macros:
            MealSheet(store: store, seed: MealSheetSeed(description: "Babcia's kapusniak", macros: Macros(protein: 18, carbs: 32, fat: 9)))
                .fernletFoodSheet(anchor: "gallery.macros")
        case .veil:
            MealSheet(store: store, seed: MealSheetSeed(description: "Scrambled eggs and toast"))
                .overlay { CaptureAnalyzingOverlay() }
                .fernletFoodSheet(anchor: "gallery.veil")
        case .review:
            MealReviewSheet(resolution: FoodLaneFixtures.reviewResolution, store: store, onConfirm: { _, _ in }, onDiscard: {})
                .fernletSheet()
        case .adjust:
            MealCorrectionSheet(store: store, meal: FoodLaneFixtures.adjustMeal)
                .fernletFoodSheet(anchor: "gallery.adjust")
        default:
            FoodLaneGalleryStep(store: store, screen: screen)
        }
    }
}

/// The gallery's fixture meals: a rough-estimate dinner for Check this meal, and a lunch with one
/// low-confidence match for Adjust meal (`bindScore` nil is never a confident bind).
private enum FoodLaneFixtures {
    /// A bind score the app reads as a confident match.
    static let confident = FoodItemSearch.confidentBindScore

    static func item(_ name: String, _ quantity: Double, _ unit: String, _ macros: Macros, score: Int?) -> MealComponentSnapshot {
        MealComponentSnapshot(name: name, quantity: quantity, unit: unit, macros: macros,
                              micronutrients: Micronutrients(), bindScore: score)
    }

    static func meal(_ name: String, _ type: MealType, _ items: [MealComponentSnapshot]) -> Meal {
        let total = Macros(protein: items.reduce(0) { $0 + $1.macros.protein },
                           carbs: items.reduce(0) { $0 + $1.macros.carbs },
                           fat: items.reduce(0) { $0 + $1.macros.fat })
        return Meal(name: name, mealType: type, macros: total, componentSnapshots: items, quality: .ok,
                    confidence: "rough", note: "", source: "gallery")
    }

    static var reviewResolution: MealResolution {
        MealResolution(
            meals: [meal("Scrambled egg and French toast sticks", .dinner, [
                item("Egg omelet or scrambled egg, made with butter", 1, "cup", Macros(protein: 16, carbs: 1, fat: 20), score: confident),
                item("French toast sticks", 1, "serving", Macros(protein: 3, carbs: 18, fat: 4), score: confident)
            ])],
            createdRecipes: [], confidence: .low, isFallback: false,
            suggestedRecipe: RecipeDefinition(name: "Scrambled egg and French toast sticks", servings: 1, ingredients: [],
                                              notes: "", source: "manual", createdAt: Date(), updatedAt: Date()))
    }

    static var adjustMeal: Meal {
        meal("Chicken rice bowl", .lunch, [
            item("Chicken breast, roasted", 150, "g", Macros(protein: 46, carbs: 0, fat: 5), score: confident),
            item("Rice crackers", 1, "cup", Macros(protein: 3, carbs: 40, fat: 1), score: nil)
        ])
    }
}

/// The capture steps and the small sheets, with fixture foods and photos.
private struct FoodLaneGalleryStep: View {
    let store: FernletStore
    let screen: FoodLaneScreen

    var body: some View {
        switch screen {
        case .serving:
            BarcodeServingStepView(foodItem: Self.oatBar, initialServings: 1, onCancel: {}, onLog: { _ in })
                .fernletSheet()
        case .recent:
            RecentMealsSheet(store: store) { _ in }.fernletSheet()
        case .targets:
            NutritionTargetsSheet(store: store).fernletFoodSheet(anchor: "gallery.targets")
        case .chooser:
            CaptureChooserSheet(image: Self.photo, aiEnabled: true, onMeal: {}, onRetake: {}, onTypeInstead: {})
                .fernletSheet()
        case .cameraOff:
            NavigationStack { BarcodeScanView(backTitle: String(localized: "Log meal"), onCode: { _ in }) }.fernletSheet()
        case .remember:
            NavigationStack { BarcodeNotFoundView(store: store, barcode: "0123456789012", backTitle: String(localized: "Log meal")) { _ in } }
                .fernletSheet()
        case .remembered:
            NavigationStack { RememberedConfirmationView(item: Self.oatBar) {} }.fernletSheet()
        case .labelScan:
            NavigationStack {
                NutritionLabelCameraSheet(backTitle: String(localized: "Remember"), seed: Self.labelSeed) { _ in }
            }
            .fernletSheet()
        case .productReview:
            FoodProductReviewSheet(preview: Self.productPreview, product: Self.product, showCalories: false,
                                   onSearchAgain: {}, onConfirm: {})
                .fernletSheet()
        default:
            MealPhotoDetailView(name: "Greek yogurt with berries", loggedAt: Date(),
                                loadData: { Self.photo.jpegData(compressionQuality: 0.8) }, hasSealedData: { true })
        }
    }

    /// A packaged food, one 40 g bar.
    static let oatBar = FoodItem(name: "Hazelnut oat bar", servingSize: 1, servingUnit: "bar",
                                 macros: Macros(protein: 4, carbs: 24, fat: 9), micronutrients: Micronutrients(),
                                 category: "Snacks", source: .manual, servingDescription: "1 bar (40g)", tags: [])

    /// A warm placeholder photo.
    static var photo: UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 600, height: 400)).image { context in
            UIColor(red: 0.72, green: 0.62, blue: 0.45, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 600, height: 400))
        }
    }

    /// A read two-column label: the oat bar per serving, and as prepared.
    static var labelSeed: NutritionLabelSheetSeed {
        let perServing = NutritionLabelResult(servingSize: "1 bar (40g)", protein: 4, carbs: 24, fat: 9, fiber: 3)
        let prepared = NutritionLabelResult(servingSize: "1 bar (40g)", protein: 6, carbs: 27, fat: 10, fiber: 3)
        return NutritionLabelSheetSeed(image: labelPhoto, result: perServing,
                                       dualColumn: DualColumnScanResult(col1Header: "Per serving", col2Header: "As prepared",
                                                                        col1: perServing, col2: prepared))
    }

    /// A pale stand-in label: "Nutrition Facts" over ruled lines.
    static var labelPhoto: UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 600, height: 240)).image { context in
            UIColor(red: 0.99, green: 0.98, blue: 0.95, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 600, height: 240))
            UIColor(red: 0.88, green: 0.85, blue: 0.80, alpha: 1).setFill()
            for row in 1...8 {
                context.fill(CGRect(x: 0, y: CGFloat(row) * 26 + 20, width: 600, height: 3))
            }
            ("Nutrition Facts" as NSString).draw(at: CGPoint(x: 24, y: 10), withAttributes: [
                .font: UIFont.boldSystemFont(ofSize: 28), .foregroundColor: UIColor.black
            ])
        }
    }

    static let productURL = URL(string: "https://example.com/hazelnut-oat-bar") ?? URL(fileURLWithPath: "/")
    static let productPreview = ProductPagePreview(sourceURL: productURL, title: "Hazelnut Oat Bar, 6 pack")
    static let product = ImportedFoodProduct(sourceURL: productURL, name: "Hazelnut Oat Bar, 6 pack", brand: "Kind Pantry",
                                             servingSize: "1 bar (40 g)", macros: Macros(protein: 4, carbs: 24, fat: 9),
                                             micronutrients: Micronutrients())
}

#else
extension View {
    /// A no-op in Release: the Food screens gallery exists only in DEBUG builds.
    func foodLaneGallery(store: FernletStore) -> some View { self }
}
#endif
