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
    /// The widget's view of an appearance: the body shape and topper as their FROZEN tokens, and
    /// each colour as a resolved `#RRGGBB` — or nil where the slot follows the state, so the widget
    /// keeps colouring it by the day (and by the night colour while the companion is asleep).
    ///
    /// Clothing, the side item and user-designed items stay in the app: at widget size they are a few
    /// pixels and would crowd the cut-out face. Fixed colours resolve in the LIGHT appearance — the
    /// companion is the same creature in a dark widget, as in the app's own dark Home.
    ///
    /// - Parameter appearance: The person's companion, as dressed in the app.
    init(appearance: CompanionAppearance) {
        self.init(bodyStyleRaw: appearance.bodyStyle.rawValue,
                  bodyColorHex: Self.hex(custom: appearance.bodyCustomColorHex, slot: appearance.bodyColor),
                  accessoryRaw: appearance.accessory.rawValue,
                  accessoryColorHex: Self.hex(custom: appearance.accessoryCustomColorHex, slot: appearance.accessoryColor))
    }

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
/// The widget's `FernletWidgetLink` writes the same two spellings (`WidgetBridgeTests` pins them).
/// Each becomes a ``PendingIntentSheet`` request, so it rides the same path a Siri open does: it waits
/// behind launch and behind any open sheet, and a stale one expires rather than hijacking a later
/// open.
nonisolated enum FernletWidgetLinkRouter {
    /// The host every widget link uses.
    static let host = "widget"

    /// Where a widget link lands, or nil when the URL is not one.
    static func target(of url: URL) -> PendingIntentSheet.Target? {
        guard url.scheme == "fernlet-world", url.host == host else { return nil }
        switch url.path {
        case "/home": return .home
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
