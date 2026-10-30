import FernletUI
import SwiftUI
import UIKit

/// Sprout's passport's own colours (World-Passport-Spec §2; the mockup's `--pp-*` tokens), each following Dark Mode
/// and Increase Contrast. Every text colour passes 4.5:1 on the page's paper (7:1 with Increase Contrast); the gold
/// on the cover passes 5.5:1.
nonisolated enum PassportBookPalette {
    /// The page's paper, `#FFF9EA` (dark `#2A2721`).
    static let paper = WorldPalette.adaptive(light: 0xFFF9EA, dark: 0x2A2721)
    /// The first stepped edge and the turning leaf's back, `#F1E6CB`.
    static let paper2 = WorldPalette.adaptive(light: 0xF1E6CB, dark: 0x36312A)
    /// The darker stepped edge, `#CDBB93`.
    static let edge = WorldPalette.adaptive(light: 0xCDBB93, dark: 0x4C4436)
    /// The page's text.
    static let text = WorldPalette.adaptive(light: 0x3A2414, dark: 0xFFF1CF, lightHC: 0x2A1808, darkHC: 0xFFF8E4)
    /// The page's quieter text (page numbers, dates in headers, descriptions).
    static let dim = WorldPalette.adaptive(light: 0x6B5C4A, dark: 0xCFC4B1, lightHC: 0x4E4030, darkHC: 0xE2D8C6)
    /// The headers' moss (small caps).
    static let moss = WorldPalette.adaptive(light: 0x46683A, dark: 0x9BCB84, lightHC: 0x36522C, darkHC: 0xB4DCA0)
    /// The links' moss in the index.
    static let link = WorldPalette.adaptive(light: 0x3E6B32, dark: 0x9BCB84, lightHC: 0x30542A, darkHC: 0xB4DCA0)
    /// The cover, `#26492F` (dark `#1D3A25`), its top light and its spine band.
    static let cover = WorldPalette.adaptive(light: 0x26492F, dark: 0x1D3A25)
    static let coverHigh = WorldPalette.adaptive(light: 0x356040, dark: 0x2A4D33)
    static let coverLow = WorldPalette.adaptive(light: 0x1A3622, dark: 0x122818)
    /// The gold stitching and the cover's letters, `#E6BF62`.
    static let gold = WorldPalette.rgb(0xE6BF62)
    /// The ribbon, `#B3343A` (dark `#C9545A`).
    static let ribbon = WorldPalette.adaptive(light: 0xB3343A, dark: 0xC9545A)
    /// The framed cream of the ✕, the chips and the page bar (`--g-cream`) and its low edge.
    static let cream = WorldPalette.adaptive(light: 0xFFF1CF, dark: 0x3A2E22)
    static let creamLow = WorldPalette.adaptive(light: 0xE2C893, dark: 0x2A2017)
    /// The chips' text on cream.
    static let onCream = WorldPalette.bark

    /// The hairline under headers and between index rows: ink at 22 % (cream at 20 % in dark), 45 % with
    /// Increase Contrast.
    static let rule = tinted(light: (0x4A2E1C, 0.22, 0.45), dark: (0xFFF1CF, 0.2, 0.45))
    /// The veil over the map behind the book: cream at 20 % (dark `#1C1E1B` at 30 %; 40 % / 50 % with Increase
    /// Contrast).
    static let veil = tinted(light: (0xF5EFDF, 0.2, 0.4), dark: (0x1C1E1B, 0.3, 0.5))
    /// The gutter's darkest step: ink at 20 % (black at 42 % in dark).
    static let gutter = tinted(light: (0x4A2E1C, 0.2, 0.2), dark: (0x000000, 0.42, 0.42))
    /// The gutter's two lighter steps.
    static let gutterMid = tinted(light: (0x4A2E1C, 0.11, 0.11), dark: (0x000000, 0.24, 0.24))
    static let gutterLight = tinted(light: (0x4A2E1C, 0.05, 0.05), dark: (0x000000, 0.1, 0.1))
    /// The security print's two waves: moss at 13 % and red at 7 % (cream at 7 % in dark).
    static let printMoss = tinted(light: (0x5E844D, 0.13, 0), dark: (0xFFF1CF, 0.07, 0))
    static let printRed = tinted(light: (0xB3343A, 0.07, 0), dark: (0xFFF1CF, 0, 0))

    /// A colour of `hex` at an alpha for light and for dark, each with its Increase Contrast alpha.
    private static func tinted(light: (UInt32, CGFloat, CGFloat), dark: (UInt32, CGFloat, CGFloat)) -> Color {
        Color(UIColor { @Sendable trait in
            let high = trait.accessibilityContrast == .high
            let (hex, normal, contrast) = trait.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: high ? contrast : normal)
        })
    }
}

/// The passport's type (World-Passport-Spec §2, the mockup's page CSS), each scaling with Dynamic Type.
nonisolated enum PassportBookType {
    /// A page's header in small caps ("STAMPS", 11 pt DM Sans Bold).
    static let header = Font.custom(FernletFontName.dmSansBold, size: 11, relativeTo: .caption2)
    /// A heading inside a page ("TWO TO AIM FOR").
    static let heading = Font.custom(FernletFontName.dmSansBold, size: 11, relativeTo: .caption2)
    /// The page number, Fraunces italic 14.
    static let pageNumber = Font.custom(FernletFontName.frauncesSemiBold, size: 14, relativeTo: .footnote).italic()
    /// Body text on a page (13 pt).
    static let body = Font.custom(FernletFontName.dmSans, size: 13, relativeTo: .footnote)
    /// The page bar's name (15 pt bold).
    static let bar = Font.custom(FernletFontName.dmSansBold, size: 15, relativeTo: .subheadline)
    /// The page bar's quiet part ("of 6").
    static let barQuiet = Font.custom(FernletFontName.dmSansMedium, size: 15, relativeTo: .subheadline)
    /// A chip's words (14.5 pt bold).
    static let chip = Font.custom(FernletFontName.dmSansBold, size: 14.5, relativeTo: .subheadline)
    /// A big title on a page (Fraunces 20, the fresh page; 21 the continent).
    static let title = Font.custom(FernletFontName.frauncesSemiBold, size: 21, relativeTo: .title3)
    /// A count's big number (Fraunces 22).
    static let count = Font.custom(FernletFontName.frauncesSemiBold, size: 22, relativeTo: .title3)
    /// A count's words (14 pt).
    static let countWords = Font.custom(FernletFontName.dmSans, size: 14, relativeTo: .subheadline)
    /// A row's name in the index (13.5 pt bold).
    static let rowName = Font.custom(FernletFontName.dmSansBold, size: 13.5, relativeTo: .footnote)
    /// A row's small line in the index (12.5 pt).
    static let rowSmall = Font.custom(FernletFontName.dmSans, size: 12.5, relativeTo: .caption)
    /// A row's link in the index (12.5 pt bold).
    static let rowLink = Font.custom(FernletFontName.dmSansBold, size: 12.5, relativeTo: .caption)
    /// A name under a stamp in the A to Z grid (10.5 pt bold) and its trips (10 pt).
    static let cellName = Font.custom(FernletFontName.dmSansBold, size: 10.5, relativeTo: .caption2)
    static let cellTrips = Font.custom(FernletFontName.dmSansMedium, size: 10, relativeTo: .caption2)
    /// The dotted next spot's words (Instrument Serif italic 16).
    static let next = Font.custom(FernletFontName.instrumentSerifItalic, size: 16, relativeTo: .callout)
    /// The cover's letters ("PASSPORT", 19 pt bold, wide) and name (Fraunces 30).
    static let coverWord = Font.custom(FernletFontName.dmSansBold, size: 19, relativeTo: .headline)
    static let coverName = Font.custom(FernletFontName.frauncesSemiBold, size: 30, relativeTo: .title)
}
