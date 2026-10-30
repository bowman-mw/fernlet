# Accessibility

Fernlet should work for everyone who wants to look after themselves with it. This page says what
the app supports today, how that is checked, what is not done yet, and how to tell us when
something gets in your way.

## Where Fernlet stands

Fernlet is in active development and has **not yet been submitted to the App Store**. Nothing on
this page claims conformance with WCAG or any other standard. It describes what has been built and
measured, feature by feature, with the evidence each claim rests on.

We are deliberately cautious. A feature listed as supported that turns out not to work costs a
disabled person a download, a setup and a task they cannot finish; a feature left unlisted costs
them nothing. Fernlet also collects no telemetry or analytics of any kind (see the
[no-tracking wall](Docs/No-Tracking-Wall.md)), so nothing would ever tell us after the fact that a
claim was wrong. The evidence has to come first.

The full working record, with every measurement, is
[Docs/Accessibility-Nutrition-Labels.md](Docs/Accessibility-Nutrition-Labels.md). It is the source
for everything below, and it is what Fernlet's App Store accessibility labels will be filled in from.

## Supported today

These four are the features Fernlet plans to declare in its App Store Accessibility Nutrition
Labels at first submission.

**Dark Interface.** Fernlet follows the system's light or dark appearance and never forces light.
Its colours come from named tokens with light and dark values, and their contrast is measured in
both.

**Reduce Motion.** With Reduce Motion on, every continuous animation in the app pauses (7 of 7
animation timelines) and every repeating animation stops (3 of 3), including the companion's
ambient movement and the barcode scanner's sweep. The paced breathing exercise keeps its expanding
and contracting guide, because that motion is the exercise; its idle sway stops.

**Differentiate Without Color.** Information is not carried by colour alone. A selected chip, tile
or row is marked with the selected trait that VoiceOver reads, as well as by its fill. With
Differentiate Without Color on, the workout calendar marks a workout's kind with a symbol and shows
logged as filled and planned as hollow, and the journal calendar's mood colours get the same
treatment.

**Sufficient Contrast, with Increase Contrast on.** Fernlet meets contrast guidelines on the route
Apple allows for apps built on its UI frameworks: with **Settings › Accessibility › Display & Text
Size › Increase Contrast** turned on. To be plain about the default: in the default light
appearance, Fernlet's green (`moss`) text measures about 3.7–4.0:1, below the usual 4.5:1 for text.
Under Increase Contrast it resolves to a darker green measuring 5.1–6.3:1, and the app's grey and
filled-button colours darken too. A 25-screen gallery of the app is measured in default light, dark
and Increase Contrast, and no text on it falls below 4.5:1 in dark or under Increase Contrast.

A few smaller things that help:

- **Photos keep their colours under Smart Invert.** Your own photos and rendered images opt out of
  inversion, so a picture of a meal is never turned into a colour negative.
- **Haptics you can turn down.** **Settings › Sounds & haptics** has an app-wide level: All, Fewer
  (results and timers only, without the small taps) or Off. The system's own haptics switch is
  respected underneath it.
- **One voice.** The guided workout's optional spoken cues are off until you turn them on. While
  VoiceOver is running they are passed to VoiceOver instead of a second voice, so nothing talks over
  it. Sounds and spoken cues follow the ring/silent switch and never stop or duck your music.

## In progress, not yet claimed

These three are intended, and much of the work is done, but each needs a person to complete every
common task with the feature on a real iPhone before Fernlet claims it. Those device checks are
**still pending**. Fernlet's common tasks are logging a meal, logging water, logging a mood and
completing a workout, plus onboarding, changing a setting and finding help.

**VoiceOver: device check pending.** What is in place:

- every common task announces that it finished ("Mood logged."), without reading out what you logged;
- the meal Undo notice announces itself and waits while VoiceOver's cursor is on it;
- the guided workout keeps the cursor on its main button and announces each set, rest and exercise;
- VoiceOver's escape gesture (a two-finger scrub) closes every logging sheet, asking first if you
  have typed something;
- the app lock is modal and speaks its errors;
- screens and sections are marked as headings for the rotor.

Eight simulator walks, one per task, drive each flow through accessibility elements alone and
pass. What a simulator cannot check is what VoiceOver actually says, where the cursor lands after
a sheet closes, and whether the escape gesture and custom actions reach the right controls. That is
the device check.

**Voice Control: device check pending.** Controls on the common-task paths have short spoken names
that match the text drawn on them (38 places were added, such as "Log meal" and "Add water"), so
you can say "Tap" and the word you see rather than a sentence that changes as you log. Where two
controls share a name, Voice Control's numbered overlay is the intended fallback. The simulator
cannot run Voice Control, so the device check is the only test that can confirm this.

**Larger Text: work remaining, then a device check.** Text uses Dynamic Type throughout, layouts
stack at accessibility sizes, and a test suite opens the common tasks at the largest size (AX5).
The automated audit's findings on the original 37 audited screens are down from 167 to 52, and the
Home screen audits clean. The remaining findings on the common-task screens need fixing, or showing
on a device to be drawn whole, before a full AX5 check on a real iPhone.

## Known gaps

- **Bold Text is not supported.** The serif typeface Fernlet uses for body text and headings comes
  in a single weight, so there is no bolder version to switch to.
- **Text-field placeholders truncate at the largest text sizes.** What you type is not affected.
- **Some control edges are low contrast.** Hairline borders on cards, fields and chips measure
  about 1.2–1.7:1. Controls on the common tasks are identified by their text, which is measured;
  only a few shared components thicken their borders under Increase Contrast.
- **Translations need their own check.** Accessibility labels are translated along with the rest
  of the app, but the Larger Text work was measured against English lengths and has to be measured
  again for each language.
- **There is no Help screen in the app.** Help today is Settings › Safety & reporting (crisis lines
  and the developer's email) and the privacy policy. Searching Settings for "help" finds it.
- **Reduce Motion does not switch screen transitions to cross-fades.** The transitions are short
  slides combined with a fade.

## Not applicable

- **Captions and Audio Descriptions.** Fernlet plays no video or audio content. The camera is used
  only to take photos and scan barcodes.
- **iPad.** Fernlet runs on iPhone only.

## How it is checked

Because no field data will ever check these claims, the checking lives in the repository:

- **A source scan with ten rules,** [`Scripts/accessibility-scan.py`](Scripts/accessibility-scan.py)
  and its Swift twin `Tests/FernletTests/AccessibilityBoundaryTests`. Among other things it fails the
  build on text that ignores Larger Text, a fixed-width grid, a spoken internal value, a missing
  heading trait, a photo without Smart Invert protection, a control that stops announcing as a
  button, a faded grey text, a field prompt drawn in the system's low-contrast placeholder colour,
  and a long spoken name with no short Voice Control name. Every exception is listed in
  `Scripts/accessibility-allowlist.json` with its reason.
- **Apple's accessibility audit, with a ratchet.** The UI test suites run `performAccessibilityAudit`
  on every probed screen. Each screen's remaining findings are frozen, so a new finding fails, and
  so does a frozen one that no longer appears.
- **A contrast measurement.** Every visible text and empty-field prompt on the probed screens is
  measured in the screenshot against 4.5:1, and the gallery is re-run in light, dark and Increase
  Contrast.
- **Task walks.** `Tests/FernletUITests/VoiceOverTaskUITests` walks each common task through
  accessibility elements alone, and `VoiceControlNameInventoryUITests` lists every control's spoken
  name on the common-task screens.
- **The app lock.** `Tests/FernletTests/LockGateAccessibilityBoundaryTests` checks that the lock
  hides what it covers from VoiceOver and is modal.
- **Words stay words.** Spoken labels and Voice Control names are translated with the app's other
  text, while accessibility identifiers and stored values stay fixed, so a translation cannot break
  a test or a saved setting ([the localization plan](Docs/Localization-Plan-2026-07-19.md)).

What no machine checks: where VoiceOver's focus goes, whether a label that is present is also
right, and whether a task can actually be completed. Those are why the device checks above exist.

## Reporting an accessibility problem

If something in Fernlet is hard or impossible to use with the way you use your iPhone, we want to
know. It is treated as a bug.

- **Email** [fernletapp@gmail.com](mailto:fernletapp@gmail.com) with "accessibility" in the subject, or
- **open an issue** at [github.com/bowman-mw/fernlet/issues](https://github.com/bowman-mw/fernlet/issues).
  Issues are public, so leave out anything personal.

It helps to include your iPhone model and iOS version, the accessibility features you have on (for
example VoiceOver, Voice Control, a larger text size, Increase Contrast or Switch Control), the
screen you were on and what you were trying to do. Please do not send health data, journal text or
anything from your private store; it is not needed.

Fernlet is made by one person. Every report is read.
