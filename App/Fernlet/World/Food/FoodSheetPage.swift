import FernletUI
import SwiftUI

extension View {
    /// A page pushed inside a Food sheet's own stack (Batch 3's `PUSHED`: Scan a food, Remember
    /// product, Scan label): under the World look the system bar hides and the page draws the sheet's
    /// header itself, the Back top left naming the page it returns to ("‹ Log meal") and the title
    /// inside the sheet in Fraunces 30. Without the look it is today's inline navigation title.
    ///
    /// - Parameters:
    ///   - title: The page's title.
    ///   - back: The page Back returns to, already resolved; nil says "Back".
    func foodSheetPushedPage(_ title: LocalizedStringResource, back: String? = nil) -> some View {
        modifier(FoodSheetPushedPage(title: title, back: back))
    }
}

/// Implements ``SwiftUI/View/foodSheetPushedPage(_:back:)``.
private struct FoodSheetPushedPage: ViewModifier {
    let title: LocalizedStringResource
    let back: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.fernletFramedLook) private var look
    /// A World panel's plate, when the page is pushed under one (the recipe editor's scan flow inside
    /// the Food panel) rather than inside a sheet.
    @Environment(\.fernletPlateNavigation) private var plate

    func body(content: Content) -> some View {
        if plate != nil {
            content.fernletPushedPage(title)
        } else if look != nil {
            content
                .navigationTitle(Text(title))
                .toolbar(.hidden, for: .navigationBar)
                // The bar is hidden, so the edge swipe needs the shared delegate to keep going back.
                .fernletEdgeSwipeBack()
                .safeAreaInset(edge: .top, spacing: 0) {
                    SheetHeader(title: Text(title)) {
                        FoodSheetBackButton(title: back) { dismiss() }
                    }
                }
        } else {
            content
                .navigationTitle(Text(title))
                .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// A sheet page's Back (`b3-barcode-off`, `b3-remember`, `b3-label-scan`): the pixel ‹ and the name of
/// the page it returns to, in the sheet's control type, where a root sheet draws Cancel.
struct FoodSheetBackButton: View {
    /// The page it returns to, already resolved; nil says "Back".
    let title: String?
    let action: () -> Void
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                FernletIcon(.back, scale: 2)
                Text(verbatim: title ?? FernletUICopy.back)
            }
            .font(FernletFramedFont.sheetControl)
            .foregroundStyle(look?.dim ?? Color.slate)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: title.map(FernletUICopy.backTo) ?? FernletUICopy.back))
        .accessibilityInputLabels([Text(verbatim: title ?? FernletUICopy.back), Text(verbatim: FernletUICopy.back)])
        .accessibilityIdentifier("sheet.back")
    }
}
