# ``FernletUI``

Fernlet's SwiftUI design system: the warm adaptive color palette, the two-system type scale, layout and motion tokens, and the reusable screen, sheet, and keepsake components shared by every Fernlet surface.

## Overview

FernletUI is the presentation vocabulary of the app. It owns four kinds of building material: **color** (the adaptive `parchment` / `cream` / `bark` / `slate` surface tokens driven by ``FernletThemePalette``, plus fixed accents like `moss`, `goldenrod`, `terracotta`, and the reserved state/journal palettes), **type** (``FernletTextRole`` resolved to bundled fonts through `Font.fernlet(_:)`, with the exact PostScript names pinned in ``FernletFontName``), **layout and motion** (the 8pt grid and corner radii in ``FernletMetrics``, the animation tokens in ``FernletMotion``, and the warm bark-tinted shadow modifiers), and **components** — screen chrome (``ScreenHeader``, ``FernletCard``), entry-sheet furniture (``SheetField``, ``SheetSaveBar``, ``ChipButtonStyle``), and decorative keepsakes (``PolaroidTile``, ``CoinGlyph``, ``PressedMedallion``). The one non-decorative outlier is ``ActivityShareView``, the app's single `UIActivityViewController` wrapper — it lives here because all three export surfaces (Privacy & Data's data export, the trainer/nutritionist summary, and the proximity connection-log export) present through it, and its `onFinish` hook is the seam where a plaintext export is deleted once sharing finishes. A large part of the module's surface lives in extensions rather than types: the `Color` token statics, the `Font.fernlet(_:)` resolver, view modifiers such as `fernletSheetStyle()`, `keyboardDoneToolbar()`, `discardConfirmation(isPresented:onDiscard:)`, `uxScreenAnchor(_:)`, and `fernletTabBarCompaction(_:resetToken:)`, the `Binding.isPresent()` bridge that collapses optional-driven presentation state into the `Bool` binding SwiftUI's alert/sheet modifiers take, and the `ModelColors.swift` extensions that give the `FernletDomainModel` enums (`MealType`, `WorkoutSplit`, `FeelingTag`, `CompanionState`, …) their design-system colors so the domain package can stay Foundation-only and portable.

The module also owns the app's screen-capture **friction** layer: ``CaptureProtectionState`` (an app-lifetime `@MainActor @Observable` service owning the screenshot pulse from `userDidTakeScreenshotNotification` and the per-window-scene capture verdict from `UIScreen.isCaptured` / `capturedDidChangeNotification`) and ``CaptureProtectedModifier`` behind the `captureProtected(surface:active:isFrontmost:)` view extension, which draws an opaque cover while the surface's own screen is being recorded/mirrored or the scene is not `.active` (app-switcher snapshots), and reacts to a screenshot with a brief blur plus a calm once-per-session nudge (its copy in ``CaptureNudgeCopy``, spoken once through a VoiceOver announcement, since the blur and banner are otherwise invisible to that channel). It is applied by the app target to exactly six surfaces — the Private hub root (inner to the lock gate, so the cover can never occlude the passcode field) and the five sensitive sheets. Three details are invariants, not polish: the capture verdict **fails toward covering before a surface's screen probe has resolved** (with nothing registered yet it consults every connected window scene's screen live, so the first surface mounted mid-recording is covered rather than leaked); the cover's arrival **resigns keyboard focus in the surface's own window** (the system keyboard renders in its own window above the cover and its QuickType bar echoes typed text — without the resign, a recording captures live sensitive typing over the panel); and the screenshot pulse is **skipped while the surface is occluded** — by its own Tier-2 cover, and, composed by the call sites into `isFrontmost`, by the hub's lock-gate overlay (`FernletLockGateOcclusion`) and covering root sheets — so the session's one nudge is never spent on a banner nobody can see. Two register rules are load-bearing: this is **friction against the user's own casual self-sharing, never a security control** (it cannot prevent a screenshot and must never be described as if it could — see `Docs/Design-Capture-Protection-2026-08-10.md`), and the state is **injected, never self-discovered**, because neither real trigger can be driven from an automated test — the injection is the entire test seam.

In the FernletKit dependency DAG this is a **layer 1.5 leaf-adjacent target**: it depends only on `FernletDomainModel` (for the enum color extensions) and is consumed upward by `FernletLockUI`, `ProximityKit`, and dozens of views in the app target. Relative to the S3 privacy wall it is **wall-neutral** — it has no dependency edge to any sealed `Private*` store, and neither of the walled consumers (`AIProviders`, `CloudKitSync`) depends on it. Nothing here touches sensitive data or crypto; the only persistence in the entire module is the read of the custom-background hex from `UserDefaults.standard` (keys in ``FernletThemeDefaults``) during theme resolution. App-navigation types (`FernletTab`, `FernletSheet`) are deliberately *not* here — they are app concerns and live in `App/Fernlet/FernletNavigation.swift`.

The module's one genuinely subtle mechanism is theme resolution. The adaptive surface tokens are built on `UIColor` dynamic providers, and UIKit invokes those provider closures on **whatever thread is resolving the trait collection — including SwiftUI's off-main render thread on device**. The target's package-level `defaultIsolation(MainActor.self)` would make that a Swift 6 executor trap (SIGTRAP), so everything on the resolution path is explicitly `nonisolated` (``FernletThemePalette``, ``FernletThemeDefaults``, the `UIColor` hex/luminance helpers) and every provider closure is annotated `@Sendable` — both annotations are load-bearing, not decoration. When editing colors, follow the existing pattern exactly: fixed colors go through the `Color(light:dark:)` initializer (which bridges to `UIColor` *before* the provider closure, because the SwiftUI bridge is not safe inside it), and adaptive surfaces go through ``FernletThemePalette/current(for:)``. Custom user backgrounds derive a matching box surface via HSB adjustment and choose light-or-dark ink by WCAG relative luminance, so any user-chosen background stays legible.

**Accessibility is a property of the primitives, not of the call sites.** Several rules are enforced here precisely because they cannot be enforced 41 chip sites at a time: ``ChipButtonStyle`` and ``HubSectionPicker`` add the `.isSelected` trait themselves (a custom style renders a selected state that VoiceOver otherwise cannot see); ``ScreenHeader`` titles *wrap* rather than shrink-and-truncate; ``HeaderActionButton`` takes an `accessibilityLabel:` because an icon-only button otherwise announces its SF Symbol name; `fernletIconButton(_:)` / `fernletTapTarget()` lift a glyph-sized control to the 44pt minimum; and the contrast-safe fill/ink pairs (`mossFill` + `onMoss`, `terracotta` + `onTerracotta`, `terracottaInk` for destructive *text*) exist because plain white on `moss` measures 4.29:1 in light mode and 2.53:1 in dark. Never hand-roll `.foregroundStyle(.white)` on an accent fill, and prefer ``ActionPillButtonStyle`` — 44pt, three roles — for anything that *acts*, leaving ``ChipButtonStyle`` for things that *select*.

**Display text is `LocalizedStringKey`; tokens stay `String`.** Every text parameter a person reads — ``ScreenHeader``'s `title`/`subtitle`, ``HeaderActionButton``'s `title`/`accessibilityLabel`, ``SectionLabel``, ``SheetField``'s caption, ``SheetSaveBar``'s `label`, ``EmptyState``'s `text`, and `fernletIconButton(_:)`'s VoiceOver label — takes a `LocalizedStringKey`, while everything that is a *token* stays a plain `String`: SF Symbol names, the `identifier:` anchors the UX appearance tests match on, and any persisted rawValue a caller happens to render. This is the whole point of the type split, and it is not cosmetic: a `String` parameter looks localizable at the call site and silently is not, because the compiler only harvests a literal into a string catalog when the parameter it is passed to is a `LocalizedStringKey`. Flipping these seven signatures made ~289 existing app call sites extractable without touching one of them.

**The module now owns a string catalog of its own** (`Localizable.xcstrings`, added by the 2026-08-22 accessibility review's §4.0). That is not a reversal of the rule above — copy a caller *names* is still a caller parameter — but a shared component cannot push everything outward, and the exceptions had been sitting here as bare literals: ``SheetSaveBar``'s `"Save"` **default** (a default value has no call site to come from; its own doc comment recorded that it translated only because several sheets happened to pass the same literal explicitly), the shared discard prompt (whose entire value is that all ~40 entry sheets word it identically), the keyboard toolbar's Done, ``SheetCancelBar``/``SheetHeader``'s Cancel, the coin pill's spoken balance, and the capture cover and nudge — which render from a *modifier* and are spoken from ``CaptureProtectionState``, so there is no call site to hand words in through at all. All of it now resolves through ``FernletUICopy`` (and ``CaptureNudgeCopy``) with `String(localized:…, bundle: .module)`, exactly as `FernletLockUI` has always done with `FernletLockCopy`. The mechanical half is `LocalizationBoundaryTests.packageDisplayLiteralsPassModuleBundle()`: any bare literal handed to a SwiftUI display initializer anywhere under `FernletKit/Sources` — including one hiding inside a ternary, or moved into a `LocalizedStringKey`-typed property — now fails that test, so the next one cannot ship silently.

Three consequences follow, and each is a trap if forgotten. First, **the key is harvested into the *calling* target's catalog and looked up in `Bundle.main`** — correct for the app target, which owns nearly every call site, and wrong for a caller inside another package module (`FernletLockUI`, `ProximityKit`), whose literals land in a package bundle `Bundle.main` never consults and would render as untranslated English with no error anywhere. A package caller resolves its own copy with `String(localized:bundle:.module)` and passes the result to the matching `verbatim:` initializer. Second, **every component that can receive runtime text carries a second, explicitly labelled `verbatim:` initializer** (``ScreenHeader`` uses a `Text`-taking initializer instead, so its two halves can be decided independently). The label is deliberate: a same-label `String` overload would win overload resolution for every plain literal — `String` is a literal's default type — and quietly un-localize the component, which is the exact failure this design removes. Verbatim is for text that is already final: user or peer data, a formatted date, a persisted token used as a heading. Third, **casing is applied with `.textCase(.uppercase)`, never `String.uppercased()`** — ``SectionLabel`` and ``SheetField`` both render uppercase captions, and the transform has to run *after* the catalog lookup so it uppercases the translation rather than the English key (German ß becomes SS; French capitals keep their accents). `LocalizedStringKey` has no `.uppercased()` for exactly this reason.

**Two accessibility mechanisms live here rather than at 30 call sites.** ``FernletAnnouncer`` is the app's single VoiceOver-announcement seam — the extraction of the injected closure ``CaptureProtectionState`` already carried, which is now the only one in the module. It exists for two reasons. The accessibility system never reports back what it spoke, so an announcement that silently stops firing is invisible to every other kind of test in the repo; the announcer's one injected closure makes "was this spoken, and was that one *not*?" a unit-testable question (`FernletAnnouncerTests`). And `AccessibilityNotification.Announcement` takes a plain `String`, which resolves against `Bundle.main` — never this module's own catalog — so a literal written there would be spoken in English forever with a clean build — so **the announcer's whole API takes caller-resolved text**, either a `LocalizedStringResource` carrying its own bundle or an already-resolved `String` behind a `resolved:` label, and the file contains no copy at all (a test scans its source to keep it that way). The other rule is a privacy one: **announce the event, never the payload.** An announcement is spoken aloud into the room, and most of the surfaces that call this are behind the app lock precisely because their text is private — "Released." not the worry, "Couldn't save that." not the note. ``FernletDismissalWindow`` is the matching timing seam: every auto-dismissing toast in the app is budgeted for a sighted tap, which is the wrong budget for someone who has to notice a new overlay exists, swipe to it and double-tap. It offers the two policies as two methods, not one optional parameter, because they want opposite handling of a missing answer. `window(standard:assistive:)` always returns a `Duration` — the caller has already assigned the state that timer is responsible for clearing, so there must be no branch on which no timer is created, and an optional there invites a `guard … else { return }` that strands the toast on screen forever. `windowUnlessAssistive(standard:)` returns `nil` while an assistive technology runs, meaning *do not auto-dismiss at all* — correct only when dismissal would remove controls from the accessibility tree and leaving the surface up is genuinely harmless (it is not, for instance, when the surface holds a radio open, which is why the proximity share sheet takes the stretched window instead). The assistive-technology read is injected, because `UIAccessibility.isVoiceOverRunning` cannot be forced from a test and that branch would otherwise be the one nothing ever exercises.

**Sheet reading order is a component rule too.** ``SheetHeader`` raises `.accessibilitySortPriority` on its three texts — eyebrow 12, title 11, subtitle 10, against the control row's default 0 — so a sheet opens by saying what it *is* before offering the way out of it. In layout order Cancel and Done come first, so every sheet used to greet a VoiceOver user with "Cancel, button". One raised band on the shared header fixes all 16 sites, which is why it lives here. The companion rule from the same review is deliberately **not** implemented: moving VoiceOver focus on appear is a per-sheet opt-in, never a component default, because forcing title focus would fight the text field on the delete-everything gate — and SwiftUI's sheet-focus timing is not reproducible enough in this repo's harness to ship blind. Focus moves only where content the user was reading is destroyed or replaced, and only where the behaviour can be demonstrated twice.

Confirmations are the other module-level rule. Both `discardConfirmation(isPresented:onDiscard:)` and `confirmDestructive(_:isPresented:message:confirmLabel:cancelLabel:onConfirm:)` are **alerts, deliberately**: on iOS 26 a `.confirmationDialog` renders as a popover that suppresses the `.cancel`-role button, so the user is shown a lone destructive action and no visible way out. Any new destructive prompt in a package module goes through `confirmDestructive`; app-target surfaces use the richer `DestructiveConfirmation` type in `App/Fernlet/`, which adds the audit trail. `fernletDraftGuard(isDirty:showsCancelBar:onDismiss:)` packages the whole dirty-sheet contract — blocked swipe-dismiss, a ``SheetCancelBar``, and the discard alert — into one modifier.

**Sheet chrome is the 2026-08-21 three-slot template** (design canvas artboards 2a/2b). ``SheetHeader`` is the canonical pinned header — Cancel top-left when a draft can be lost, Done top-right to dismiss or commit in place, an optional leading accessory (a coin balance) when the sheet leads with information — above a Fraunces-28 title and an optional one-line italic subtitle that is the first thing to go at accessibility sizes. Draft sheets adopt it through the title-bearing `fernletDraftGuard(isDirty:title:subtitle:onDismiss:)` overload, which wires Cancel to the discard prompt and keeps the `sheet.cancel` identifier unique; ``SheetSaveBar`` stays the bottom-right commit for drafts (now with the template's hairline), and the bottom-right moss "Done" pill is retired everywhere. The destructive vocabulary is one token in three forms: ``ChipButtonStyle`` with `destructive: true` for chips that destroy, ``ActionPillButtonStyle`` `.destructive` (the tinted token — terracotta ink on a 10% fill, never solid) for 44pt pills, and ``DestructiveCardButtonStyle`` for full-width actions; solid terracotta is reserved for the confirm button inside a confirmation alert, and a disabled destructive control drops opacity, never color.

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
- ``AdaptiveStack``
- ``FernletTabBarCompactionModifier``

### Entry-sheet components

- ``SheetHeader``
- ``DestructiveCardButtonStyle``
- ``SheetCancelBar``
- ``SheetSaveBar``
- ``SheetField``
- ``SheetTextEditor``
- ``SheetGrowingTextField``
- ``ChipButtonStyle``
- ``ActionPillButtonStyle``
- ``FernletActionPillKind``
- ``FlowLayout``
- ``HubSectionPicker``
- ``FernletDraftGuardModifier``

### System integration

- ``ActivityShareView``

### Accessibility seams

- ``FernletAnnouncer``
- ``FernletAnnouncement``
- ``FernletAnnouncementKind``
- ``FernletDismissalWindow``

### Capture friction

- ``CaptureProtectionState``
- ``CaptureProtectedModifier``
- ``CaptureNudgeCopy``
- ``FernletUICopy``

### Decorative and keepsake components

- ``PolaroidTile``
- ``SearchingPulse``
- ``PressedMedallion``
- ``CoinGlyph``
- ``CoinBalancePill``
