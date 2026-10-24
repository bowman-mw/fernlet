# ``FernletUI``

Fernlet's SwiftUI design system: the warm adaptive color palette, the two-system type scale, layout and motion tokens, and the reusable screen, sheet, and keepsake components shared by every Fernlet surface.

## Overview

FernletUI is the presentation vocabulary of the app. It owns four kinds of building material: **color** (the adaptive `parchment` / `cream` / `bark` / `slate` surface tokens driven by ``FernletThemePalette``, plus fixed accents like `moss`, `goldenrod`, `terracotta`, and the reserved state/journal palettes), **type** (``FernletTextRole`` resolved to bundled fonts through `Font.fernlet(_:)`, with the exact PostScript names pinned in ``FernletFontName``), **layout and motion** (the 8pt grid and corner radii in ``FernletMetrics``, the animation tokens in ``FernletMotion``, and the warm bark-tinted shadow modifiers), and **components** — screen chrome (``ScreenHeader``, ``FernletCard``), entry-sheet furniture (``SheetField``, ``SheetSaveBar``, ``ChipButtonStyle``), and decorative keepsakes (``PolaroidTile``, ``CoinGlyph``, ``PressedMedallion``). The one non-decorative outlier is ``ActivityShareView``, the app's single `UIActivityViewController` wrapper — it lives here because all three export surfaces (Privacy & Data's data export, the trainer/nutritionist summary, and the proximity connection-log export) present through it, and its `onFinish` hook is the seam where a plaintext export is deleted once sharing finishes. A large part of the module's surface lives in extensions rather than types: the `Color` token statics, the `Font.fernlet(_:)` resolver, view modifiers such as `fernletSheetStyle()`, `keyboardDoneToolbar()` (it reaches only fields in its own hosting controller, so each page of a `NavigationStack` declares its own — one outside the stack reaches none of them), `discardConfirmation(isPresented:onDiscard:)`, `uxScreenAnchor(_:)`, `fernletTabBarCompaction(_:resetToken:)`, and the floating tab bar's two clearances (`fernletTabBarBottomClearance()` ends a tab page's scroll range above the bar; `fernletTabBarSafeAreaClearance()` lifts a pushed page's pinned save bar above it, and gives way to the keyboard once the keyboard covers the bar, which stays pinned behind it — measured by `fernletKeyboardOverlap(_:)`, the larger of the two winning per `FernletTabBarClearance.reservation(clearance:keyboardOverlap:)`), the `Binding.isPresent()` bridge that collapses optional-driven presentation state into the `Bool` binding SwiftUI's alert/sheet modifiers take, and the `ModelColors.swift` extensions that give the `FernletDomainModel` enums (`MealType`, `WorkoutSplit`, `FeelingTag`, `CompanionState`, …) their design-system colors so the domain package can stay Foundation-only and portable.

The module also owns the app's screen-capture **friction** layer: ``CaptureProtectionState`` (an app-lifetime `@MainActor @Observable` service owning the screenshot pulse from `userDidTakeScreenshotNotification` and the per-window-scene capture verdict from `UIScreen.isCaptured` / `capturedDidChangeNotification`) and ``CaptureProtectedModifier`` behind the `captureProtected(surface:active:isFrontmost:)` view extension, which draws an opaque cover while the surface's own screen is being recorded/mirrored or the scene is not `.active` (app-switcher snapshots), and reacts to a screenshot with a brief blur plus a calm once-per-session nudge (its copy in ``CaptureNudgeCopy``, spoken once through a VoiceOver announcement, since the blur and banner are otherwise invisible to that channel). It is applied by the app target to exactly six surfaces — the Private hub root (inner to the lock gate, so the cover can never occlude the passcode field) and the five sensitive sheets. Three details are invariants, not polish: the capture verdict **fails toward covering before a surface's screen probe has resolved** (with nothing registered yet it consults every connected window scene's screen live, so the first surface mounted mid-recording is covered rather than leaked); the cover's arrival **resigns keyboard focus in the surface's own window** (the system keyboard renders in its own window above the cover and its QuickType bar echoes typed text — without the resign, a recording captures live sensitive typing over the panel); and the screenshot pulse is **skipped while the surface is occluded** — by its own Tier-2 cover, and, composed by the call sites into `isFrontmost`, by the hub's lock-gate overlay (`FernletLockGateOcclusion`) and covering root sheets — so the session's one nudge is never spent on a banner nobody can see. Two register rules are load-bearing: this is **friction against the user's own casual self-sharing, never a security control** (it cannot prevent a screenshot and must never be described as if it could — see `Docs/Design-Capture-Protection-2026-08-10.md`), and the state is **injected, never self-discovered**, because neither real trigger can be driven from an automated test — the injection is the entire test seam.

In the FernletKit dependency DAG this is a **layer 1.5 leaf-adjacent target**: it depends only on `FernletDomainModel` (for the enum color extensions) and is consumed upward by `FernletLockUI`, `FernletProximityUI`, and dozens of views in the app target. It depends on no networking and no Photos code, and must keep it that way: the in-person review screens that need `ProximityKit` and Photos live in `FernletProximityUI`, which depends on this module and on `ProximityKit`, so the design system stays light for the Fernlet Coach app (`Docs/Plan-FernletCoach-ProximityKit-2026-10-01.md`, step A0.1). Relative to the S3 privacy wall it is **wall-neutral** — it has no dependency edge to any sealed `Private*` store, and neither of the walled consumers (`AIProviders`, `CloudKitSync`) depends on it. Nothing here touches sensitive data or crypto; the only persistence in the entire module is the read of the custom-background hex from `UserDefaults.standard` (keys in ``FernletThemeDefaults``) during theme resolution. App-navigation types (`FernletTab`, `FernletSheet`) are deliberately *not* here — they are app concerns and live in `App/Fernlet/FernletNavigation.swift`.

The module's one genuinely subtle mechanism is theme resolution. The adaptive surface tokens are built on `UIColor` dynamic providers, and UIKit invokes those provider closures on **whatever thread is resolving the trait collection — including SwiftUI's off-main render thread on device**. The target's package-level `defaultIsolation(MainActor.self)` would make that a Swift 6 executor trap (SIGTRAP), so everything on the resolution path is explicitly `nonisolated` (``FernletThemePalette``, ``FernletThemeDefaults``, the `UIColor` hex/luminance helpers) and every provider closure is annotated `@Sendable` — both annotations are load-bearing, not decoration. The design tokens themselves are `nonisolated` too — the `Color` palette extensions and the `Color(light:dark:)` initializers, `Font.fernlet(_:)`, ``FernletTextRole`` and ``FernletFontName`` — because they are immutable `Sendable` values that views read from default arguments and from `@Sendable` view-builder closures, nonisolated contexts in which newer Xcode rejects a main-actor token. When editing colors, follow the existing pattern exactly: fixed colors go through the `Color(light:dark:)` initializer (which bridges to `UIColor` *before* the provider closure, because the SwiftUI bridge is not safe inside it), and adaptive surfaces go through ``FernletThemePalette/current(for:contrast:)``. Custom user backgrounds derive a matching box surface via HSB adjustment and then **fit** both inks to it with a bounded search (``FernletThemePalette/fitted(background:)``), rather than picking an ink family off one binary luminance threshold and using it unchanged — the old behaviour handed a mid-grey background 1.79:1 primary ink and 1.13:1 secondary on every screen. The fit is pure and allocates exactly one `UIColor`, because it runs inside those same off-main provider closures.

**The World build's framed look.** ``FernletFramedLook`` is an environment value, unset by default, so a surface without it draws exactly as it always has; the World build sets it once at the app's root (`worldDesignLanguage()`), together with ``FernletFramedToggleStyle``, ``FernletFormStyle`` and a ``FernletIconRenderer``, so every screen and every sheet the root presents takes it (a presented sheet does not inherit the presenter's toggle and Form styles, so `fernletSheet()` sets both again on the sheet's content). This module owns the look's shape and none of its palette: the app's World theme supplies the colours (the original twelve tokens plus `page`, `pageDot`, `rule`, `link`, `wood`, `woodHigh` and `warn`, which default from them) and draws the pixel icons (``FernletFramedIcon`` through the renderer, so one-colour icons take the ink token in dark mode); without a renderer each icon is its SF Symbol. Under the look ``FernletCard`` is paper in a 2-pt ink frame with a solid shadow, ``SectionLabel`` and ``SheetField``'s caption carry a small framed square, ``EmptyState`` draws in the look's dim ink, and the shared pieces every screen already uses switch over in place: ``SheetHeader`` (the wooden ``FernletSheetGrabber``, Cancel top left, Done top right, the title inside the sheet in Fraunces 30, paper with an ink top edge via ``FernletSheetPaper``), ``SheetCancelBar``, ``SheetSaveBar`` (the kit's framed primary button on paper), `sheetTextInput()` and ``SheetTextEditor`` (the framed field), ``ChipButtonStyle``, ``ActionPillButtonStyle`` (with a `.small` ``FernletActionPillSize``), ``HubSectionPicker`` (the framed section tabs) and every `Form` (``FernletFormStyle``: framed sections with hairlines). The foundation lane added the primitives each World screen is built from, each matching the approved kit CSS and falling back to today's look without the look: the sheet frame (`fernletSheet()` for full height at a sheet's root, `fernletSheetToolbar(title:…)` for a sheet built on a `NavigationStack`, ``FernletSheetFooter``), focused flows (``FernletFocusedFlow``, ``FernletCloseButton``), pages pushed inside a panel (`fernletPushedPage(_:)`, ``FernletPlateNavigation``, ``FernletBackButton``; a page holding unsaved work registers a close guard the panel's ✕ asks first, `setCloseGuard(id:_:)` / `allowsClose()`, and a page running a wipe holds Back and ✕ off with `isHeld`; a page that hides its bar inside a sheet's own stack keeps the edge swipe with `fernletEdgeSwipeBack()`), dotted pages (``FernletDottedPage``, `fernletPageBackground()`), rows (``FernletFramedSection``, ``FernletRowLabel``, ``FernletRowButtonStyle``, ``FernletDottedRule``, `fernletFramedListRow(isFirst:isLast:)`), controls (``FernletDropdown``, ``FernletSegmentedPicker``, ``FernletStepper``) and content pieces (``FernletNotice``, ``FernletKeyValueRow``, ``FernletTag``, ``FernletBigTime``, ``FernletRing``, ``FernletTileGrid``, ``FernletIconTile``), with the kit's type sizes in ``FernletFramedFont``. **The frame rule** (``FernletFrameRule``, owner-approved 2026-10-24) is applied here once, so every screen follows it: one frame per section (a framed ``FernletCard``, ``FernletFramedSection`` or Form section sets `fernletInFramedSection` on its content), 1-pt hairlines inside it (``FernletDottedRule`` draws the hairline now, in the look's `rule` token), and frames only on controls; inside a section a nested ``FernletCard`` or ``FernletFramedSection`` draws no frame, a decorative ``FernletIconTile`` sits bare (`isControl: true` keeps a button face framed), a ``FernletNotice`` keeps its tint without a frame, and app pieces join through `fernletFrameRulePiece(_:fill:cornerRadius:)`. `fernletSheet()`, ``FernletFocusedFlow`` and the framed Form clear the flag, since a sheet presented from inside a card inherits the card's environment. The DEBUG-only `WorldFoundationGallery` in the app (`FERNLET_UI_TEST_WORLD_GALLERY`) shows them all.

**Increase Contrast resolves on the same axis, in the same providers.** `Color(light:dark:)` is a thin forward to `Color(light:dark:lightHC:darkHC:)`, which branches on `trait.accessibilityContrast == .high` (UIKit's spelling of SwiftUI's `colorSchemeContrast == .increased`) — so a token gains a high-contrast twin by naming one, and all of its call sites inherit it with zero churn. Three tokens branch today and every other resolves identically at `.increased`, which is the property that makes the capability free of visual risk at default settings: `slate` → `#45535E` (6.90:1 / 7.41:1), `mossFill` → `#38562C` (white on it 8.28:1), `moss` → `#46683A` (5.54:1 / 5.95:1, up from 3.74:1). `goldenrod` deliberately has **no** twin — its fixed `midnight` ink measures 2.89:1 on a deepened fill, so deepening it would break the pair; the refusals are recorded in `FernletUIComponents.swift`'s "tokens that deliberately have NO high-contrast twin" note. Component boundaries (``FernletCard``'s edge, the chip and pill strokes) use `Color.barkEdge(_:normal:)` / `Color.terracottaEdge(_:normal:)`, whose Increase Contrast alphas were measured to clear the 3:1 non-text floor. A `ButtonStyle` cannot read the environment, which is why both styles keep a nested content view.

**Accessibility is a property of the primitives, not of the call sites.** Several rules are enforced here precisely because they cannot be enforced 41 chip sites at a time: ``ChipButtonStyle`` and ``HubSectionPicker`` add the `.isSelected` trait themselves (a custom style renders a selected state that VoiceOver otherwise cannot see); ``ScreenHeader`` titles *wrap* rather than shrink-and-truncate; ``HeaderActionButton`` takes an `accessibilityLabel:` because an icon-only button otherwise announces its SF Symbol name; `fernletIconButton(_:)` / `fernletTapTarget()` lift a glyph-sized control to the 44pt minimum; and the contrast-safe fill/ink pairs (`mossFill` + `onMoss`, `terracotta` + `onTerracotta`, `terracottaInk` for destructive *text*) exist because plain white on `moss` measures 4.29:1 in light mode and 2.53:1 in dark. Never hand-roll `.foregroundStyle(.white)` on an accent fill, and prefer ``ActionPillButtonStyle`` — 44pt, three roles — for anything that *acts*, leaving ``ChipButtonStyle`` for things that *select*.

**Display text is `LocalizedStringKey`; tokens stay `String`.** Every text parameter a person reads — ``ScreenHeader``'s `title`/`subtitle`, ``HeaderActionButton``'s `title`/`accessibilityLabel`, ``SectionLabel``, ``SheetField``'s caption, ``SheetSaveBar``'s `label`, ``EmptyState``'s `text`, ``PolaroidTile``'s `caption`, and `fernletIconButton(_:)`'s VoiceOver label — takes a `LocalizedStringKey`, while everything that is a *token* stays a plain `String`: SF Symbol names, the `identifier:` anchors the UX appearance tests match on, and any persisted rawValue a caller happens to render. This is the whole point of the type split, and it is not cosmetic: a `String` parameter looks localizable at the call site and silently is not, because the compiler only harvests a literal into a string catalog when the parameter it is passed to is a `LocalizedStringKey`. Flipping the first seven of these signatures made ~289 existing app call sites extractable without touching one of them; ``PolaroidTile`` followed in the Spanish extraction round (2026-10-20), its one caller (the Home photowall) moving to the `verbatimCaption:` initializer because every caption it draws is resolved before it gets there.

**The module now owns a string catalog of its own** (`Localizable.xcstrings`, added by the 2026-08-22 accessibility review's §4.0). That is not a reversal of the rule above — copy a caller *names* is still a caller parameter — but a shared component cannot push everything outward, and the exceptions had been sitting here as bare literals: ``SheetSaveBar``'s `"Save"` **default** (a default value has no call site to come from; its own doc comment recorded that it translated only because several sheets happened to pass the same literal explicitly), the shared discard prompt (whose entire value is that all ~40 entry sheets word it identically), the keyboard toolbar's Done, ``SheetCancelBar``/``SheetHeader``'s Cancel, the coin pill's spoken balance, and the capture cover and nudge — which render from a *modifier* and are spoken from ``CaptureProtectionState``, so there is no call site to hand words in through at all. All of it now resolves through ``FernletUICopy`` (and ``CaptureNudgeCopy``) with `String(localized:…, bundle: .module)`, exactly as `FernletLockUI` has always done with `FernletLockCopy`. The mechanical half is `LocalizationBoundaryTests.packageDisplayLiteralsPassModuleBundle()`: any bare literal handed to a SwiftUI display initializer anywhere under `FernletKit/Sources` — including one hiding inside a ternary, or moved into a `LocalizedStringKey`-typed property — now fails that test, so the next one cannot ship silently.

Three consequences follow, and each is a trap if forgotten. First, **the key is harvested into the *calling* target's catalog and looked up in `Bundle.main`** — correct for the app target, which owns nearly every call site, and wrong for a caller inside another package module (`FernletLockUI`, `FernletProximityUI`), whose literals land in a package bundle `Bundle.main` never consults and would render as untranslated English with no error anywhere. A package caller resolves its own copy with `String(localized:bundle:.module)` and passes the result to the matching `verbatim:` initializer. Second, **every component that can receive runtime text carries a second, explicitly labelled `verbatim:` initializer** (``ScreenHeader`` uses a `Text`-taking initializer instead, so its two halves can be decided independently). The label is deliberate: a same-label `String` overload would win overload resolution for every plain literal — `String` is a literal's default type — and quietly un-localize the component, which is the exact failure this design removes. Verbatim is for text that is already final: user or peer data, a formatted date, a persisted token used as a heading. Third, **casing is applied with `.textCase(.uppercase)`, never `String.uppercased()`** — ``SectionLabel`` and ``SheetField`` both render uppercase captions, and the transform has to run *after* the catalog lookup so it uppercases the translation rather than the English key (German ß becomes SS; French capitals keep their accents). `LocalizedStringKey` has no `.uppercased()` for exactly this reason.

**Two accessibility mechanisms live here rather than at 30 call sites.** ``FernletAnnouncer`` is the app's single VoiceOver-announcement seam — the extraction of the injected closure ``CaptureProtectionState`` already carried, which is now the only one in the module. It exists for two reasons. The accessibility system never reports back what it spoke, so an announcement that silently stops firing is invisible to every other kind of test in the repo; the announcer's one injected closure makes "was this spoken, and was that one *not*?" a unit-testable question (`FernletAnnouncerTests`). And `AccessibilityNotification.Announcement` takes a plain `String`, which resolves against `Bundle.main` — never this module's own catalog — so a literal written there would be spoken in English forever with a clean build — so **the announcer's whole API takes caller-resolved text**, either a `LocalizedStringResource` carrying its own bundle or an already-resolved `String` behind a `resolved:` label, and the file contains no copy at all (a test scans its source to keep it that way). The other rule is a privacy one: **announce the event, never the payload.** An announcement is spoken aloud into the room, and most of the surfaces that call this are behind the app lock precisely because their text is private — "Released." not the worry, "Couldn't save that." not the note. ``FernletDismissalWindow`` is the matching timing seam: every auto-dismissing toast in the app is budgeted for a sighted tap, which is the wrong budget for someone who has to notice a new overlay exists, swipe to it and double-tap. It offers the two policies as two methods, not one optional parameter, because they want opposite handling of a missing answer. `window(standard:assistive:)` always returns a `Duration` — the caller has already assigned the state that timer is responsible for clearing, so there must be no branch on which no timer is created, and an optional there invites a `guard … else { return }` that strands the toast on screen forever. `windowUnlessAssistive(standard:)` returns `nil` while an assistive technology runs, meaning *do not auto-dismiss at all* — correct only when dismissal would remove controls from the accessibility tree and leaving the surface up is genuinely harmless (it is not, for instance, when the surface holds a radio open, which is why the proximity share sheet takes the stretched window instead). The assistive-technology read is injected, because `UIAccessibility.isVoiceOverRunning` cannot be forced from a test and that branch would otherwise be the one nothing ever exercises.

**Haptic and sound cues have one seam too.** ``FernletFeedback`` is to a buzz or a chime what ``FernletAnnouncer`` is to a spoken line: callers name what happened as a ``FernletFeedbackEvent`` and never touch a generator. The vocabulary began with the guided runner's moments (a rest ended, a hold started or ended, a set was logged, the session moved to a new block, the workout finished, the opt-in zone nudge) and the app-wide sounds-and-haptics pass (2026-10-20) added the rest of the app's: touches (`tick`, `logged`, `limit`, `moved`, `held`), outcomes (`captured`, `done`, `caveat`, `failed`, `friendHere`) and session moments (`pace`, `timerEnded`, `messageIn`, and the disposable camera's `windDetent`, `wound` and `shutter`). Each event's ``FernletFeedbackEvent/haptic``, ``FernletFeedbackEvent/sound``, ``FernletFeedbackEvent/scope`` and ``FernletFeedbackEvent/minimumInterval`` are the only mapping, and every intensity lives in the player's renderer, so tuning a feel on a device is a one-file change. Only session moments may carry a sound — sound reaches the room and a haptic doesn't — so no touch or outcome, and no private surface's error, can ever chime. Every feel is a UIKit generator pattern that plays on iPhone; SwiftUI's `.increase`, `.decrease`, `.start`, `.stop` and `.levelChange` never appear, because they play nothing there. The one exception is "time's up" — ``FernletHaptic/attention``, shared by a rest, a hold and the cooking timer running out — which plays ``FernletFeedback/attentionPattern``, three transient taps rising from soft to firm within about a quarter of a second, through the app's one `CHHapticEngine`. That engine is made lazily on the first such cue, never in an app extension (``FernletAttentionRenderer``), plays haptics only so it never touches the audio session, and is started again at the next cue after the system stops or resets it. Wherever it can't play — hardware without haptics, an extension, an engine that fails — the same cue falls back to the two heavy impacts it replaced, so callers never know which renderer ran and a test counts one cue either way. Apple documents nothing about Core Haptics and the system haptics switch, so the renderer reads the app-wide level again as it plays: Fernlet's Off silences the pattern whatever the cue says. Every play takes the calling surface's ``FernletFeedbackPreferences``, built by the ONE resolver ``FernletFeedbackPreferences/resolved(haptics:sounds:in:)``: the surface's own switch (Workout haptics, breathing's Haptics) ANDed with the app-wide ``FernletHapticsLevel`` — *All*, *Fewer* (which drops ``FernletFeedbackScope/touch`` and keeps results and timers) or *Off* — read at play time from its device-local key, the one preference this module reads, because every module that plays a cue must see the same level. A cue whose channels are off is dropped before anything reaches UIKit (``FernletFeedbackCue`` is what is left, and what a test records through the injected closure, on an injected clock for pacing); under that, `UIFeedbackGenerator` honours the system haptics setting itself. A view whose moment is a value changing uses the declarative twin, `fernletFeedback(_:trigger:haptics:feedback:when:)`, in place of `.sensoryFeedback`. `FeedbackBoundaryTests` keeps every generator, audio player, synthesizer, system sound and `.sensoryFeedback(` in the shipping tree behind `FernletFeedback.swift` and `FernletSpeech.swift`. Sounds are AudioServices system sounds — they follow the ring/silent switch, play at the ringer volume and mix with whatever is playing, because no `AVAudioSession` category is ever set, so the person's music is never paused or ducked. The ``FernletSound`` files are short, quiet sine tones written for Fernlet and, like the fonts, ship in the APP bundle and are resolved by name (the same names the app's background cue notifications use). This module holds no copy: a spoken cue stays the announcer's job.

**Spoken cues have the sibling seam.** ``FernletSpeaker`` says a ``FernletSpokenLine`` — caller-resolved catalog words, never sealed content — for a surface whose person turned spoken cues on (today the guided workout runner). It keeps **one voice**: while VoiceOver runs it never starts the synthesizer and posts only ``FernletSpokenLine/voiceOverText`` through ``FernletAnnouncer`` (nil when the screen's own announcement already says the moment, so nothing is said twice). With VoiceOver off it speaks through a ``FernletSpeechVoice`` (production: one `AVSpeechSynthesizer`, made on first use, preferring the person's assistive-technology speech settings, in the app's language — the person's regional voice when their device speaks it, ``FernletSpeaker/voiceLanguage(appLanguage:locale:)``), and it **never takes the audio, and respects the switch**: each line configures the shared session with ``FernletSpeechAudioPolicy`` — `.ambient` in the default mode with no options, the same on every route (the phone's speaker, headphones, Bluetooth, CarPlay, AirPlay), so it mixes with whatever is playing, never ducks or pauses it, and the ring/silent switch silences it, in headphones too (the owner's decision 3, 2026-10-20: "respect the switch") — activates it, and releases it with `.notifyOthersOnDeactivation` a moment after the last line ends. The cost of that decision is accepted on purpose: in headphones the music no longer dips under the words, and a podcast keeps talking over them; iOS offers no way to read the switch, so ducking only while the ringer is on cannot be built. A session that refuses to configure or activate drops the line rather than speak on a category that would stop the music. Every session call is a ``FernletSpeechSessionCall`` through an injected closure, so a test asserts the exact sequence; the voice and the VoiceOver read are injected too, and there is no route to inject — the speaker never reads it.

**Sheet reading order is a component rule too.** ``SheetHeader`` raises `.accessibilitySortPriority` on its three texts — eyebrow 12, title 11, subtitle 10, against the control row's default 0 — so a sheet opens by saying what it *is* before offering the way out of it. In layout order Cancel and Done come first, so every sheet used to greet a VoiceOver user with "Cancel, button". One raised band on the shared header fixes all 16 sites, which is why it lives here. The companion rule from the same review is deliberately **not** implemented: moving VoiceOver focus on appear is a per-sheet opt-in, never a component default, because forcing title focus would fight the text field on the delete-everything gate — and SwiftUI's sheet-focus timing is not reproducible enough in this repo's harness to ship blind. Focus moves only where content the user was reading is destroyed or replaced, and only where the behaviour can be demonstrated twice.

Confirmations are the other module-level rule. Both `discardConfirmation(isPresented:onDiscard:)` and `confirmDestructive(_:isPresented:message:confirmLabel:cancelLabel:onConfirm:)` are **alerts, deliberately**: on iOS 26 a `.confirmationDialog` renders as a popover that suppresses the `.cancel`-role button, so the user is shown a lone destructive action and no visible way out. Any new destructive prompt in a package module goes through `confirmDestructive`; app-target surfaces use the richer `DestructiveConfirmation` type in `App/Fernlet/`, which adds the audit trail. `fernletDraftGuard(isDirty:showsCancelBar:onDismiss:)` packages the whole dirty-sheet contract — blocked swipe-dismiss, a ``SheetCancelBar``, and the discard alert — into one modifier.

**Sheet chrome is the 2026-08-21 three-slot template** (design canvas artboards 2a/2b). ``SheetHeader`` is the canonical pinned header — Cancel top-left when a draft can be lost, Done top-right to dismiss or commit in place, an optional leading accessory (a coin balance) when the sheet leads with information — above a Fraunces-28 title and an optional one-line italic subtitle that is the first thing to go at accessibility sizes. Draft sheets adopt it through the title-bearing `fernletDraftGuard(isDirty:title:subtitle:onDismiss:)` overload, which wires Cancel to the discard prompt and keeps the `sheet.cancel` identifier unique; ``SheetSaveBar`` stays the bottom-right commit for drafts (now with the template's hairline), and the bottom-right moss "Done" pill is retired everywhere. The destructive vocabulary is one token in three forms: ``ChipButtonStyle`` with `destructive: true` for chips that destroy, ``ActionPillButtonStyle`` `.destructive` (the tinted token — terracotta ink on a 10% fill, never solid) for 44pt pills, and ``DestructiveCardButtonStyle`` for full-width actions; solid terracotta is reserved for the confirm button inside a confirmation alert, and a disabled destructive control drops opacity, never color.

Two other conventions matter before changing this module. First, **fonts resolve by PostScript name only** — the font files themselves stay registered by the app's Info.plist `UIAppFonts`, and `FernletFontRegistrationTests` asserts every name in ``FernletFontName`` resolves, so a wrong name fails the test run instead of silently falling back to the system font. The fonts are under the SIL Open Font License 1.1, not Apache-2.0: each family's license text in `App/Fernlet/Fonts/LICENSES/` must reach the app bundle beside the font, and the same test checks that too. Each bundled face carries one weight, so a weight asked of a face (`.weight(.bold)`, `.fontWeight(.bold)`) draws that face's own weight: bold DM Sans names the Bold face (`FernletFontName.dmSansBold`, added 2026-10-24), through ``FernletFramedFont``'s bold roles (`button`, `tag`, `back`, `rowTitleBold`, `sectionLabel`, …). The design export's wordmark face, Playfair Display Italic, and its `.wordmark` role were removed on 2026-10-01: the bundled file was a static instance cut from the variable font, which the OFL counts as a Modified Version, and Playfair Display reserves its name, so a modified copy may not be called "Playfair Display". Nothing rendered it. If a wordmark comes back, bundle an unmodified upstream file with its license (Google Fonts' `PlayfairDisplay-Italic[wght].ttf` registers as `PlayfairDisplay-Italic`), never a re-instanced or subset copy. Second, several tokens (``FernletMotion``, the `lichen`/`state*`/`journal*` colors) are **reserved design-export vocabulary**: they may have no call site yet, but they are the documented system palette for surfaces still being built out — they are intentionally kept and should not be flagged or removed as dead code.

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
- ``FernletFrameRule``
- ``FernletFramedLook``
- ``FernletFramedToggleStyle``
- ``FernletFramedFont``
- ``FernletFramedIcon``
- ``FernletIcon``
- ``FernletIconRenderer``
- ``FernletDottedPage``
- ``FernletPlateNavigation``
- ``FernletBackButton``
- ``FernletFocusedFlow``
- ``FernletCloseButton``
- ``EmptyState``
- ``AdaptiveStack``
- ``FernletTabBarCompactionModifier``
- ``FernletTabBarSafeAreaClearanceModifier``
- ``FernletKeyboardOverlapReader``

### Entry-sheet components

- ``SheetHeader``
- ``FernletSheetGrabber``
- ``FernletSheetPaper``
- ``FernletSheetFooter``
- ``FernletFramedSection``
- ``FernletRowLabel``
- ``FernletRowButtonStyle``
- ``FernletDottedRule``
- ``FernletFormStyle``
- ``FernletDropdown``
- ``FernletSegmentedPicker``
- ``FernletStepper``
- ``FernletStepperMath``
- ``FernletNotice``
- ``FernletKeyValueRow``
- ``FernletTag``
- ``FernletBigTime``
- ``FernletRing``
- ``FernletTileGrid``
- ``FernletIconTile``
- ``FernletActionPillSize``
- ``FernletSheetStyleModifier``
- ``SheetTextInputModifier``
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

### Addressing the user

Spanish (and every later gendered language) genders the words that describe the user. They agree
with the body profile's Sex answer, masculine when it was never answered: the app root sets
`EnvironmentValues.fernletTermOfAddress` from `BiologicalSex.termOfAddress`, and a translation's
`^[listo](inflect: true)` mark is inflected with it rather than with the system's Form of Address.
The resolution itself is `AddressedCopy` in FernletDomainModel (moved there 2026-10-21 so the
planner's stored notes, the scoring lines and a notification body can use it without SwiftUI);
this module keeps the view half: the environment value and ``AddressedText``, which reads it. A
view that needs a `Text` value rather than a view (an alert message, a component's `Text`
parameter) or a `String` calls `AddressedCopy.attributed(_:addressing:)` /
`AddressedCopy.string(_:addressing:)` with the same environment value.

A marked key must never be read by `String(localized:)`, which keeps the raw markup, and no
caller-built `LocalizedStringResource` is resolved that way either. `LocalizationBoundaryTests`
part I holds both walls, and part I2 pins every user-gendered key to an addressed reader: its
literal sits inside ``AddressedText``, `AddressedCopy.string` / `.attributed` with an `addressing:`
term, or ``FernletAnnouncer``'s resource overload with one (it resolves through `AddressedCopy`
too), never `Text("…")`, a component's `LocalizedStringKey` parameter or `AddressedCopy.plain(_:)`.
A component whose display text may describe the user therefore offers a `Text` (or `verbatim:`)
form for its caller to fill: `EmptyState(verbatim:)`, `ScreenHeader(title: Text, …)`.

- ``AddressedText``

### Accessibility seams

- ``FernletAnnouncer``
- ``FernletAnnouncement``
- ``FernletAnnouncementKind``
- ``FernletDismissalWindow``

### Haptic and sound cues

- ``FernletFeedback``
- ``FernletFeedbackEvent``
- ``FernletFeedbackCue``
- ``FernletFeedbackPreferences``
- ``FernletFeedbackScope``
- ``FernletHapticsLevel``
- ``FernletHaptic``
- ``FernletHapticTap``
- ``FernletAttentionRenderer``
- ``FernletSound``

### Spoken cues

- ``FernletSpeaker``
- ``FernletSpokenLine``
- ``FernletSpeechVoice``
- ``FernletSpeechAudioPolicy``
- ``FernletSpeechSessionCall``

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
