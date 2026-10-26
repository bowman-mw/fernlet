// WidgetCompanionLookMirror.swift
// Fernlet
//
// The app half of the widget's simplified companion (owner decision 2026-10-21): the person's
// `CompanionAppearance`, reduced to what a widget-sized companion can show, and the deep links a
// widget tap opens.

import Foundation
import SwiftUI
import UIKit
import FernletDomainModel
import FernletUI

extension WidgetSnapshot.CompanionLook {
    /// The widget's view of an appearance: the body shape, topper and side item as their FROZEN
    /// tokens, and each colour as a resolved `#RRGGBB` — or nil where the slot follows the state, so
    /// the widget keeps colouring it by the day (and by the night colour while the companion is
    /// asleep). The clothing travels as the scarf's or the sleep cap's colour, as the map draws it.
    ///
    /// Since the phone test (W-02, W-07; 2026-10-25) the widget draws the whole pixel wardrobe and the
    /// worn Creation Studio pieces (`items`, fitted to their boxes by ``WorldItemBox``). Fixed colours
    /// resolve in the LIGHT appearance — the companion is the same creature in a dark widget, as in the
    /// app's own dark Home.
    ///
    /// - Parameters:
    ///   - appearance: The person's companion, as dressed in the app.
    ///   - items: The Creation Studio pieces it wears (none in a decoy session).
    init(appearance: CompanionAppearance, items: [CustomizationItem] = []) {
        self.init(bodyStyleRaw: appearance.bodyStyle.rawValue,
                  bodyColorHex: Self.hex(custom: appearance.bodyCustomColorHex, slot: appearance.bodyColor),
                  accessoryRaw: appearance.accessory.rawValue,
                  accessoryColorHex: Self.hex(custom: appearance.accessoryCustomColorHex, slot: appearance.accessoryColor),
                  scarfColorHex: Self.scarfHex(appearance),
                  capColorHex: Self.capHex(appearance),
                  sideItemRaw: appearance.sideItem == .none ? nil : appearance.sideItem.rawValue,
                  sideItemColorHex: Self.hex(custom: appearance.sideItemCustomColorHex, slot: appearance.sideItemColor),
                  items: Self.itemArt(items))
    }

    /// The sleep cap as the map draws it: the clothing slot's colour, or the cap's night blue when the
    /// slot follows the state; nil without the cap.
    static func capHex(_ appearance: CompanionAppearance) -> String? {
        guard appearance.clothing == .sleepCap else { return nil }
        return hex(custom: appearance.clothingCustomColorHex, slot: appearance.clothingColor)
            ?? String(format: "#%06X", WorldCompanionLook.capBlue)
    }

    /// The worn pieces, each in its place and size; nil when none draws anything (so a look without
    /// pieces encodes exactly as before).
    static func itemArt(_ items: [CustomizationItem]) -> [ItemArt]? {
        let sorted = items.sorted { WorldItemBox.paintOrder($0.slot) < WorldItemBox.paintOrder($1.slot) }
        let art: [ItemArt] = sorted.compactMap { item in
            let fitted = WorldItemBox.fit(item.texture, slot: item.slot)
            guard fitted.indices.contains(where: { $0 >= 0 && $0 < item.texture.palette.count }) else { return nil }
            let palette = item.texture.palette.prefix(ItemArt.maxPalette).map { "#" + $0.replacingOccurrences(of: "#", with: "").uppercased() }
            return ItemArt(x: fitted.x, y: fitted.y, width: fitted.width, height: fitted.height, palette: Array(palette),
                           pixels: fitted.indices.map { $0 < palette.count ? $0 : -1 }, coversHead: item.slot == .hat)
        }
        return art.isEmpty ? nil : art
    }

    /// The scarf the pixel companion wears, as the map's does (`WorldCompanionLook`): the clothing
    /// slot's colour, or the design's scarf red when the slot follows the state; nil without a scarf.
    static func scarfHex(_ appearance: CompanionAppearance) -> String? {
        guard appearance.clothing == .scarf else { return nil }
        return hex(custom: appearance.clothingCustomColorHex, slot: appearance.clothingColor) ?? scarfRed
    }

    /// The design's scarf red, the twin of `WorldCompanionLook.scarfRed`.
    static let scarfRed = "#D9532F"

    /// A slot's colour as `#RRGGBB`: the person's custom hex when it is well formed, nil for a slot
    /// that follows the state, else the named design colour resolved in the light appearance.
    static func hex(custom: String?, slot: CompanionAssetColor) -> String? {
        if let custom = normalizedHex(custom) { return custom }
        guard slot != .state else { return nil }
        // A fixed slot ignores the state it is handed.
        return hex(of: slot.color(for: .okay))
    }

    /// `#RRGGBB` (upper-case) for six hex digits with or without a leading `#`; nil for anything else.
    static func normalizedHex(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let digits = raw.hasPrefix("#") ? String(raw.dropFirst()) : raw
        guard digits.count == 6, Int(digits, radix: 16) != nil else { return nil }
        return "#" + digits.uppercased()
    }

    /// A SwiftUI colour as `#RRGGBB`, resolved in the light appearance; nil if it has no RGB form.
    static func hex(of color: Color) -> String? {
        let resolved = UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
        let channel = { (value: CGFloat) in Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", channel(red), channel(green), channel(blue))
    }
}

/// The deep links a widget tap opens, read where the app receives URLs.
///
/// The widget's `FernletWidgetLink` writes the same spellings (`WidgetBridgeTests` pins them).
/// Each becomes a ``PendingIntentSheet`` request, so it rides the same path a Siri open does: it waits
/// behind launch and behind any open sheet, and a stale one expires rather than hijacking a later
/// open.
nonisolated enum FernletWidgetLinkRouter {
    /// The host every widget link uses.
    static let host = "widget"

    /// Where a widget link lands, or nil when the URL is not one.
    ///
    /// The stamp widget's `/stamps` opens Today and pushes the Stamp book at its stamps, as the stamp
    /// banner's tap does (`ContentView.openStampBookInToday()`).
    static func target(of url: URL) -> PendingIntentSheet.Target? {
        guard url.scheme == "fernlet", url.host == host else { return nil }
        switch url.path {
        case "/home": return .home
        case "/stamps": return .stamps
        case "/water": return .water
        default: return nil
        }
    }

    /// Records the landing for a widget link. Returns whether the URL was one, so the caller can hand
    /// any other URL to the next handler.
    static func open(_ url: URL) -> Bool {
        guard let target = target(of: url) else { return false }
        PendingIntentSheet.request(target)
        return true
    }
}
