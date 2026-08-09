# ``FernletUI``

Fernlet's SwiftUI design system: the warm adaptive color palette, the two-system type scale, layout and motion tokens, and the reusable screen, sheet, and keepsake components shared by every Fernlet surface.

## Overview

FernletUI is the presentation vocabulary of the app. It owns four kinds of building material: **color** (the adaptive `parchment` / `cream` / `bark` / `slate` surface tokens driven by ``FernletThemePalette``, plus fixed accents like `moss`, `goldenrod`, `terracotta`, and the reserved state/journal palettes), **type** (``FernletTextRole`` resolved to bundled fonts through `Font.fernlet(_:)`, with the exact PostScript names pinned in ``FernletFontName``), **layout and motion** (the 8pt grid and corner radii in ``FernletMetrics``, the animation tokens in ``FernletMotion``, and the warm bark-tinted shadow modifiers), and **components** — screen chrome (``ScreenHeader``, ``FernletCard``), entry-sheet furniture (``SheetField``, ``SheetSaveBar``, ``ChipButtonStyle``), and decorative keepsakes (``PolaroidTile``, ``CoinGlyph``, ``PressedMedallion``). The one non-decorative outlier is ``ActivityShareView``, the app's single `UIActivityViewController` wrapper — it lives here because all three export surfaces (Privacy & Data's data export, the trainer/nutritionist summary, and the proximity connection-log export) present through it, and its `onFinish` hook is the seam where a plaintext export is deleted once sharing finishes. A large part of the module's surface lives in extensions rather than types: the `Color` token statics, the `Font.fernlet(_:)` resolver, view modifiers such as `fernletSheetStyle()`, `keyboardDoneToolbar()`, `discardConfirmation(isPresented:onDiscard:)`, `uxScreenAnchor(_:)`, and `fernletTabBarCompaction(_:resetToken:)`, the `Binding.isPresent()` bridge that collapses optional-driven presentation state into the `Bool` binding SwiftUI's alert/sheet modifiers take, and the `ModelColors.swift` extensions that give the `FernletDomainModel` enums (`MealType`, `WorkoutSplit`, `FeelingTag`, `CompanionState`, …) their design-system colors so the domain package can stay Foundation-only and portable.

In the FernletKit dependency DAG this is a **layer 1.5 leaf-adjacent target**: it depends only on `FernletDomainModel` (for the enum color extensions) and is consumed upward by `FernletLockUI`, `ProximityKit`, and dozens of views in the app target. Relative to the S3 privacy wall it is **wall-neutral** — it has no dependency edge to any sealed `Private*` store, and neither of the walled consumers (`AIProviders`, `CloudKitSync`) depends on it. Nothing here touches sensitive data or crypto; the only persistence in the entire module is the read of the custom-background hex from `UserDefaults.standard` (keys in ``FernletThemeDefaults``) during theme resolution. App-navigation types (`FernletTab`, `FernletSheet`) are deliberately *not* here — they are app concerns and live in `Fernlet/FernletNavigation.swift`.

The module's one genuinely subtle mechanism is theme resolution. The adaptive surface tokens are built on `UIColor` dynamic providers, and UIKit invokes those provider closures on **whatever thread is resolving the trait collection — including SwiftUI's off-main render thread on device**. The target's package-level `defaultIsolation(MainActor.self)` would make that a Swift 6 executor trap (SIGTRAP), so everything on the resolution path is explicitly `nonisolated` (``FernletThemePalette``, ``FernletThemeDefaults``, the `UIColor` hex/luminance helpers) and every provider closure is annotated `@Sendable` — both annotations are load-bearing, not decoration. When editing colors, follow the existing pattern exactly: fixed colors go through the `Color(light:dark:)` initializer (which bridges to `UIColor` *before* the provider closure, because the SwiftUI bridge is not safe inside it), and adaptive surfaces go through ``FernletThemePalette/current(for:)``. Custom user backgrounds derive a matching box surface via HSB adjustment and choose light-or-dark ink by WCAG relative luminance, so any user-chosen background stays legible.

Two other conventions matter before changing this module. First, **fonts resolve by PostScript name only** — the font files themselves stay registered by the app's Info.plist `UIAppFonts`, and `FernletFontRegistrationTests` asserts every name in ``FernletFontName`` resolves, so a wrong name fails the test run instead of silently falling back to the system font. Second, several tokens (``FernletMotion``, the `lichen`/`state*`/`journal*` colors, the `.wordmark` type role) are **reserved design-export vocabulary**: they may have no call site yet, but they are the documented system palette for surfaces still being built out — they are intentionally kept and should not be flagged or removed as dead code.

## Topics

### Type scale and fonts

- ``FernletTextRole``
- ``FernletFontName``

### Theme engine

- ``FernletThemePalette``
- ``FernletThemeDefaults``

### Layout and motion tokens

- ``FernletMetrics``
- ``FernletMotion``

### Screen chrome and layout primitives

- ``ScreenHeader``
- ``HeaderActionButton``
- ``FernletCard``
- ``SectionLabel``
- ``EmptyState``
- ``FernletTabBarCompactionModifier``

### Entry-sheet components

- ``SheetCancelBar``
- ``SheetSaveBar``
- ``SheetField``
- ``SheetTextEditor``
- ``ChipButtonStyle``
- ``FlowLayout``
- ``HubSectionPicker``

### System integration

- ``ActivityShareView``

### Decorative and keepsake components

- ``PolaroidTile``
- ``SearchingPulse``
- ``PressedMedallion``
- ``CoinGlyph``
- ``CoinBalancePill``
