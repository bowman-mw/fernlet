# Fernlet UI/UX Redesign — Review Prompt (2026-07-09)

Use this to review the `claude/uiux-no-mockup-fixes` branch on **three axes**: design fidelity vs the
approved mockup, code correctness/quality vs the committed diff, and the rendered UI vs the intended
design. Fan it out one agent per surface (paste the matching row from the table), or run it per surface
yourself. The mockups (`.dc.html`) are in the "First Aid Tools Design.zip" design set — re-unzip from
`~/Downloads` if the scratchpad copy is gone.

## The prompt (per surface)

```
ROLE
You are reviewing ONE surface of the Fernlet iOS (SwiftUI) UI/UX redesign on THREE axes:
(1) design fidelity vs the approved mockup, (2) code correctness/quality vs the committed diff,
(3) the rendered UI vs the intended design. Be adversarial and concrete; verify each finding before
reporting it, and separate genuine gaps from deliberate, justified product decisions.

INPUTS
- Repo root (quote the space): "/Users/michaelbowman/Desktop/Fernlet 5-18/Fernlet"
- Mockups: <unzip "First Aid Tools Design.zip">/firstaid_design/*.dc.html  (HTML/CSS with badge sections, e.g. 2a-2e).
- Design system (the definition of "on-theme"):
    Fernlet/FernletDesignSystem.swift — Font.fernlet(.display/.header/.headerMedium/.body/.bodySmall/
      .bubble/.label/.labelSmall/.stat/.wordmark); Color tokens (parchment, cream, bark, slate, moss, fern,
      lichen, goldenrod, terracotta, sun, dustyRose, midnight, state*, journal*); FernletMetrics
      (space xs4/sm8/md16/lg24/xl40, radius sm10/md18/lg28/xl40); .fernletCardShadow(); FernletMotion.
    _ds/colors_and_type.css + README.md in the design set (voice/tone: no streaks/scores, sentence case).
- Surface under review, its mockup file, Swift file(s), and commit: <FILL IN from the table>

AXIS 1 — DESIGN FIDELITY (mockup vs code)
Read the mockup HTML AND the Swift view. Compare and flag deviations:
- Layout & visual hierarchy; what is shown vs intentionally removed.
- Spacing to the 8pt grid; corner radii (10/18/28/40); warm bark-tinted shadows (never cold gray).
- Color: only design tokens, no raw hex; correct semantic use (moss = CTAs, terracotta = warnings, etc.).
- Typography: serif (Fraunces/DM Serif/Instrument Serif) for titles/prose/companion-voice; sans (DM Sans)
  for control labels + numbers/stats; correct Font.fernlet role AND size vs the mockup.
- Component treatments; empty / loading / error / selected / disabled states.
- Copy tone: warm, gentle, sentence case, no streaks/percentages/scoreboards, no emoji-as-icons.
Cross-check the locked decisions in Docs/UI-UX-Redesign-Brief-2026-07-08.md before calling something a miss.

AXIS 2 — CODE CORRECTNESS (the diff)
Run `git show <commit>`. Check:
- Behavior preserved: every Button/Toggle/Link/Menu action, NavigationLink/.sheet trigger, @State/@Binding,
  data source, and accessibilityIdentifier still intact (no rewire, no dropped feature).
- No logic regression disguised as a restyle; conditionals/gating/filters unchanged unless intended.
- Exhaustive `switch` over any shared enum (FernletShortcut / HomeWidget / FernletScreen / ItemSlot).
- Codable/persistence: added fields/cases backward-compatible; migrations don't crash or double-run.
- Design-system usage: no raw px/hex, no system fonts on Text, reuse shared components.
- No dead code; no S3-wall violation (walled AI/CloudKit modules must never reach the sealed Private* stores).

AXIS 3 — RENDERED UI (does it actually look right)
- Build: `xcodebuild build -scheme Fernlet -destination 'platform=iOS Simulator,name=iPhone 17' -quiet`
  (use a CLEAN build if the diff touches FernletKit/Sources/FernletDomainModel — a stale incremental build
  there masks errors and ships a bad binary). Report the build result.
- Render it: prefer the UX appearance UI-test harness (DEBUG launch args: -completeOnboarding, SEED_DEMO,
  OPEN_SHEET, BYPASS_PRIVATE_LOCK; UXScreenProbe screenshots) — or launch in the simulator with those args
  and navigate to the surface. Attach/reference a screenshot.
- Compare visually: clipping, text truncation/overflow, contrast on parchment, broken/missing states,
  elements that render differently than the code/mockup imply. Check Dynamic Type at XL and AX3.

OUTPUT (per surface)
- Findings list; each: { axis: design|code|ui, severity: high|medium|low, title,
  location: mockup-section / file:line / screenshot, what's wrong, recommended fix }.
- A one-line verdict: MATCHES / MINOR GAPS / NEEDS REWORK.
- Only report findings you verified; note deviations that are justified decisions (not findings).
```

## Surface → mockup → Swift → commit(s)

| Surface | Mockup `.dc.html` | Swift file(s) | Commit(s) |
|---|---|---|---|
| Foundation / type | Foundation | FernletDesignSystem, FernletUIComponents, FernletApp | `1e3e8db` `0c05ba1` `4ede0fc` `8194ed7` |
| Move strip | Move Strip | MoveView | `b01e0aa` `86b2857` |
| Friends shop | Friends Shop | FriendShopView, ConnectView | `3866a57` |
| First aid | First Aid | FirstAidView | `80ca701` |
| Good vibes | Good Vibes | hearts UI (AmbientCards / HomeView) | `4ef7f4d` |
| Food capture | Food Capture + Barcode Handoff | FoodView, NutritionLabelCameraSheet, BarcodeScanView | `bc49924` `78258d5` `a3e6bef` |
| Camera island | Camera Island | DisposableCameraView | `ed9c731` `c99ad4f` |
| Wardrobe studio | Wardrobe Studio | WardrobeView, CreationStudioView | `a05787f` |
| Customization selector | Customization Selector | HomeView (customization sheet) | `1845dfc` (restyle) `c38e2ae` (unified selector) |
| Milestones | Milestones | MilestonesView, HomeView | `8bba43b` |
| Home ambiance | Home Ambiance | CompanionAmbienceLayer, HomeView | `bc25c5a` |
| Companion moments | Companion Moments | CompanionVectorAssets | `4f2e78a` |
| Home companion | Home Companion | HomeView | `62640db` `444893b` |
| Home widgets config | (Milestones / First Aid) | NavigationEnums, HomeView, SettingsSheet | `57eacff` |
| Quick-log tools | (First Aid) | NavigationEnums, HomeView | `5cc9790` |
| Widget | Widget | FernletWidgets/* | pre-existing |

## Known items for the reviewer to weigh (already-flagged deferrals / notes)
- **Food auto-route**: visual single-Capture is in; the behind-the-scenes barcode→label→meal auto-routing is real code but **needs on-device camera testing** (simulator has no camera).
- **Customization**: custom-item ↔ built-in-slot mapping is a design choice (accessory↔hat/face, clothing↔body,
  side-item↔held-item); live preview + recolor-built-ins-only need an on-device eyeball.
- **Home companion**: chip-free; the Body-Signals explainer (App Store 1.4.1 disclaimer) is reachable via a quiet
  gated "Body signals" link under the companion (`444893b`).
- Nothing has been visually verified on-device — that is Axis 3's job.
