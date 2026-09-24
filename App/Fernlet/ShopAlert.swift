import SwiftUI
import FernletDomainModel

/// The three ways `store.listCustomItemForSale` can refuse a listing, as alert cases.
///
/// In every case the item itself was already saved (just left unlisted) — the alerts say so.
/// Shared by ``CreationStudioView``'s confirmation step and ``WardrobeView``'s swipe-to-sell
/// path; the per-screen copy differences live in ``ShopAlert/alert(in:)``, keyed by
/// ``ShopAlertContext``.
enum ShopAlert: Identifiable {
    /// The chosen shop name failed moderation; the item stays saved but unlisted.
    case nameFlagged
    /// The shop already holds `ClothingShopLimits.maxListedItems` items.
    case capReached
    /// The shop is temporarily closed because shared items were reported. Carries the ban's
    /// remaining time as read when the listing was refused, so the copy can say when the shop
    /// reopens (tracker §3.5 — it used to say "after a while").
    case storeBanned(remainingSeconds: Double)

    /// Stable identity for `.alert(item:)` presentation.
    var id: Int {
        switch self {
        case .nameFlagged: 0
        case .capReached: 1
        case .storeBanned: 2
        }
    }
}

/// Which screen is presenting a ``ShopAlert`` — the refusal copy points the user at the fix
/// path that exists on that screen.
enum ShopAlertContext {
    /// ``CreationStudioView``'s naming + shop-listing confirmation step. A refused listing
    /// deliberately does NOT dismiss — the user stays on this screen, where the name field
    /// lives, to rename and retry; the copy also reassures that the just-saved item is kept.
    case studioConfirmation
    /// ``WardrobeView``'s swipe "Sell" action. This screen has no name field, so the fix path
    /// is "rename it in the editor".
    case wardrobe
}

extension ShopAlert {
    /// The alert for this refusal as presented from `context`, with the exact per-screen copy
    /// each screen has always shown (full string literals, so the `LocalizedStringKey` `Text`
    /// init is preserved).
    func alert(in context: ShopAlertContext) -> Alert {
        switch (self, context) {
        case (.nameFlagged, .studioConfirmation):
            return Alert(
                title: Text("Pick a friendlier name"),
                message: Text("This name can't be used in your shop. Your item is saved — rename it and try listing again. (Private items can be named anything.)"),
                dismissButton: .default(Text("OK"))
            )
        case (.nameFlagged, .wardrobe):
            return Alert(
                title: Text("Pick a friendlier name"),
                message: Text("This name can't be used in your shop. Rename it in the editor, then list it again. (Private items can be named anything.)"),
                dismissButton: .default(Text("OK"))
            )
        case (.capReached, .studioConfirmation):
            return Alert(
                title: Text("Your shop is full"),
                message: Text("You can list up to \(ClothingShopLimits.maxListedItems) items at once. Unlist one to make room. Your item is saved and ready whenever you are."),
                dismissButton: .default(Text("OK"))
            )
        case (.capReached, .wardrobe):
            return Alert(
                title: Text("Your shop is full"),
                message: Text("You can list up to \(ClothingShopLimits.maxListedItems) items at once. Unlist one to make room."),
                dismissButton: .default(Text("OK"))
            )
        case (.storeBanned(let remainingSeconds), _):
            // The duration arrives already localized by `ShopBanRemainingTime`; interpolating it
            // into the literal keeps the whole SENTENCE a catalog key (`… in %@ — …`), so
            // translators own the word order around it.
            let reopensIn = ShopBanRemainingTime.text(seconds: remainingSeconds)
            return Alert(
                title: Text("Your shop is closed"),
                message: Text("Your shop is paused because items you shared were reported. It reopens automatically in \(reopensIn) — your items are still saved."),
                dismissButton: .default(Text("OK"))
            )
        }
    }
}

/// How long the shop self-ban still has to run, as ONE friendly, localized unit — "30 days",
/// "36 hours", "12 minutes" — rounded UP, so the copy never promises the shop back sooner than
/// the ban clock will release it.
///
/// Units: whole days from two days up, whole hours from one hour up, otherwise whole minutes
/// (at least one — "0 minutes" would contradict the alert saying the ban is still on). The unit
/// words and plurals come from Foundation's `Duration.UnitsFormatStyle` in the given locale, so
/// nothing here is English-only; the sentence around it is a catalog key.
enum ShopBanRemainingTime {
    /// Seconds in the day unit.
    private static let day: Double = 86_400
    /// Seconds in the hour unit.
    private static let hour: Double = 3_600
    /// Upper clamp, in days, on any reading — far above the real 30-day ban, far below overflow.
    private static let maxDays: Double = 366

    /// The remaining time for `seconds` of ban left, formatted for `locale`.
    static func text(seconds: Double, locale: Locale = .current) -> String {
        let rounded = roundedUp(seconds)
        return Duration.seconds(rounded.count * rounded.unit.seconds)
            .formatted(.units(allowed: [rounded.unit.formatUnit], width: .wide).locale(locale))
    }

    /// The single unit and its rounded-up count for `seconds` of ban left.
    static func roundedUp(_ seconds: Double) -> (count: Int64, unit: Unit) {
        // A non-finite or non-positive reading still means "banned" to the caller that asked, so
        // it floors at the smallest honest answer rather than trapping in `Int64(_:)`.
        guard seconds.isFinite, seconds > 0 else { return (1, .minutes) }
        // A ban never runs past `ClothingModerationLimits.banDurationDays`; the clamp only keeps an
        // impossible reading from overflowing `Int64(_:)` into a trap.
        let seconds = min(seconds, maxDays * day)
        if seconds >= 2 * day { return (Int64((seconds / day).rounded(.up)), .days) }
        if seconds >= hour { return (Int64((seconds / hour).rounded(.up)), .hours) }
        return (max(1, Int64((seconds / 60).rounded(.up))), .minutes)
    }

    /// The three units the remaining time is ever expressed in.
    enum Unit: Equatable {
        case days, hours, minutes

        /// Seconds in one of this unit.
        var seconds: Int64 {
            switch self {
            case .days: 86_400
            case .hours: 3_600
            case .minutes: 60
            }
        }

        /// The Foundation formatting unit.
        var formatUnit: Duration.UnitsFormatStyle.Unit {
            switch self {
            case .days: .days
            case .hours: .hours
            case .minutes: .minutes
            }
        }
    }
}
