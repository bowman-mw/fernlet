// WidgetTheme.swift
// FernletWidgets
//
// The Home Screen and Lock Screen widgets' look in the World design language (World Review Batch 4,
// approved 2026-10-24): paper in a 3-point ink frame, the World's text inks, Fraunces and DM Sans, in
// light and dark and under Increase Contrast. The Live Activities keep `FernletWidgetPalette`.

import SwiftUI
import WidgetKit

/// The widgets' colours for one appearance: the twins of the app's `WorldPalette` tokens as the Batch 4
/// page draws them on a widget (`.wgp`).
///
/// Text measures, light / dark: ``text`` 13:1 / 13:1 on ``paper``; ``muted`` 6.1:1 / 10:1. Under
/// Increase Contrast both darken (light) or brighten (dark), as the app's do.
struct WidgetTheme {
    /// The widget's face.
    let paper: Color
    /// The 3-point frame around it, and the ink of a one-colour icon's outline.
    let frame: Color
    /// Primary text: the state word, the count, the stamp's name.
    let text: Color
    /// Secondary text: the companion's name, "Water", captions.
    let muted: Color
    /// The dashed edge of a stamp still to come.
    let dashed: Color

    /// Parchment and bark.
    static let light = WidgetTheme(paper: Color(widgetRGB: 0xFFF6E2), frame: Color(widgetRGB: 0x4A2E1C),
                                   text: Color(widgetRGB: 0x3A2414), muted: Color(widgetRGB: 0x6B5C4A),
                                   dashed: Color(widgetRGB: 0x3D2E1E).opacity(0.3))
    /// Night browns.
    static let dark = WidgetTheme(paper: Color(widgetRGB: 0x2E261D), frame: Color(widgetRGB: 0x120A04),
                                  text: Color(widgetRGB: 0xFFF1CF), muted: Color(widgetRGB: 0xE2D6C0),
                                  dashed: Color(widgetRGB: 0xFFF1CF).opacity(0.3))

    /// The theme for the widget's appearance; Increase Contrast deepens both text inks.
    static func current(_ scheme: ColorScheme, contrast: ColorSchemeContrast = .standard) -> WidgetTheme {
        let base = scheme == .dark ? dark : light
        guard contrast == .increased else { return base }
        let text: UInt32 = scheme == .dark ? 0xFFF8E4 : 0x2A1808
        let muted: UInt32 = scheme == .dark ? 0xF4EDE0 : 0x4E4030
        return WidgetTheme(paper: base.paper, frame: base.frame, text: Color(widgetRGB: text),
                           muted: Color(widgetRGB: muted), dashed: base.dashed)
    }

    /// The one-colour rendering (Lock Screen, tinted and clear Home Screens): white, which iOS tints.
    static let mono = WidgetTheme(paper: .clear, frame: .white.opacity(0.35), text: .white,
                                  muted: .white.opacity(0.85), dashed: .white.opacity(0.4))
}

/// The colours that stay the same in light and dark, as on the Batch 4 page: the speech bubble stays
/// light paper, the moss button and the ribbon keep their fills, a stamp's disc stays gold.
enum WidgetFixedInk {
    /// The speech bubble's paper and text, and its frame (`.tbub`).
    static let bubblePaper = Color(widgetRGB: 0xFFFBEF)
    static let bubbleText = Color(widgetRGB: 0x3A2414)
    static let bubbleFrame = Color(widgetRGB: 0x4A2E1C)
    /// The shade under a framed bubble or button.
    static let shade = Color(.sRGB, red: 74 / 255, green: 46 / 255, blue: 28 / 255, opacity: 0.25)
    /// The "+" button's moss (`.hsbtn`): the white plus on it measures 6.4:1.
    static let moss = Color(widgetRGB: 0x46683A)
    /// The "New today" ribbon: white text on it measures 6.6:1.
    static let ribbon = Color(widgetRGB: 0x9A4632)
    /// An earned stamp's gold disc (the app's `StampBookArt.stampGold`).
    static let stampGold = Color(widgetRGB: 0xF2D58A)
    /// The placeholder's pale ghost of the companion.
    static let ghost: UInt32 = 0xCDB98F
}

/// The 3-point ink frame inside the widget's own rounded edge, around content padded clear of it. The
/// paper itself is the container background, so iOS can swap it for its own material when it tints
/// the Home Screen; the frame then draws in the one colour (``WidgetTheme/mono``).
struct WidgetPaperFrame: ViewModifier {
    let theme: WidgetTheme
    var padding = EdgeInsets(top: 14, leading: 15, bottom: 14, trailing: 15)

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .overlay { ContainerRelativeShape().strokeBorder(theme.frame, lineWidth: 3) }
    }
}

extension View {
    /// Pads the content clear of the frame and draws the frame (``WidgetPaperFrame``).
    func widgetPaperFrame(_ theme: WidgetTheme, padding: EdgeInsets = EdgeInsets(top: 14, leading: 15, bottom: 14, trailing: 15)) -> some View {
        modifier(WidgetPaperFrame(theme: theme, padding: padding))
    }
}

/// The app's bundled faces, by PostScript name — the twins of `FernletFontName` in FernletUI. The
/// files are copied into this extension (an extension cannot read the app's fonts) and registered by
/// its Info.plist `UIAppFonts`. A missing font falls back to the system face, never a blank.
enum WidgetFont {
    /// Fraunces SemiBold: the state word, the water count, a stamp's name.
    static func display(_ size: CGFloat) -> Font {
        .custom("Fraunces-72ptSemiBoldNonWonky", size: size, relativeTo: .title3)
    }

    /// DM Sans Medium: labels, the companion's name, the speech bubble.
    static func label(_ size: CGFloat) -> Font {
        .custom("DMSans-14ptMedium", size: size, relativeTo: .caption)
    }

    /// DM Sans regular: the line under a number.
    static func body(_ size: CGFloat) -> Font {
        .custom("DMSans-14pt", size: size, relativeTo: .caption)
    }

    /// Instrument Serif italic: the companion's voice.
    static func thought(_ size: CGFloat) -> Font {
        .custom("InstrumentSerif-Italic", size: size, relativeTo: .body)
    }
}

/// Whether a widget draws in one colour: the Lock Screen's vibrant rendering and the tinted and clear
/// Home Screens' accented one. Every view takes this as a plain flag so it can be drawn either way.
extension WidgetRenderingMode {
    /// True outside full colour.
    var drawsInOneColour: Bool { self != .fullColor }
}
