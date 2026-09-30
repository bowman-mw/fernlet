# Messages extension release checklist

The automated exchange tests cover packet envelopes, bounds, corruption, App Group coordination,
inbox expiry/wipe behavior, replay-ledger behavior, the extension dependency wall, and the exact
nine-entry App Shortcuts allocation. The following scenarios still require two physical iPhones
with Fernlet's Messages extension enabled; do not substitute the simulator for them.

## Transport and compatibility

- [ ] Measure the largest successful `MSMessage.url` on the current iOS release. Record the
  measured limit and keep `ExchangeLimits.maxMessageURLCharacters` (and the frame bound derived from
  it) below it; never infer it from the 64 KB recipe or 512 KB workout-file limits.
  *Since 2026-09-23 the code sits at Apple's DOCUMENTED limit — `MSMessage.url` "cannot be longer
  than 5,000 characters" — so `maxMessageURLCharacters` is 5,000. Since 2026-09-24 cards are
  written as envelope VERSION 2 (deflated JSON, base64url once), whose derived frame bound is 3,719
  bytes; a realistic forty-step, sixteen-ingredient recipe makes a 4,704-character URL. The
  measurement is now the only reason to raise it: send a recipe whose card sits just under 5,000
  characters, then one just over, and record whether iOS 26 still refuses the second with
  `urlExceedsMaxSize`. Then send a recipe too large for any card (a very long one with long steps)
  and check that the composer says "too large … export a Fernlet recipe file instead" rather than
  "couldn't insert".*
- [ ] Version-2 bytes survive delivery: send a version-2 recipe card and a workout card, and confirm
  the receiving phone opens both (the URL body is unpadded base64url — `-` and `_` — which no layer
  should re-encode; if Messages percent-encodes or rewrites the URL, the card fails to open and the
  composer's bound needs revisiting).
- [ ] A version-1 card sent by the 2026-09-23 build (any card already in a conversation from that
  build) still opens and reviews on the 2026-09-24 build.
- [ ] A recipe made in parts (a salad and its homemade dressing): the composer's preview and the
  received card both show "Parts: …" with the sender's part names; **Review in Fernlet** lists them;
  the saved copy keeps both parts, their names, and every ingredient and step. Then export the same
  recipe as a `.fernletrecipe` file and import it on a 2026-09-23 build: that build must refuse it as a
  format it does not know (packet version 2), not as damaged.
- [ ] Sender and receiver both have the shipping Fernlet version: send and review one recipe and
  one planned-workout card.
- [ ] **Send in Messages from the app** (2026-09-30): open a recipe's Share screen (Food › recipe row
  › Share, the recipe book, or the recipe page's Share), tap **Send in Messages**, pick a contact
  and send. The simulator can never check this row — `canSendText` is false on every simulator and
  the composer cannot be presented there — so it is hardware-only. Confirm: the draft shows the card
  (picture, name, counts, "Opens in Fernlet on iPhone") and no body text; the bubble matches one
  inserted from the iMessage app for the same recipe, and a one-serving, one-ingredient, one-step
  recipe reads "1 serving · 1 ingredient · 1 step" from both; tapping it on the receiving iPhone opens
  **Review in Fernlet** like any other card; the Share screen then says "Sent in Messages." (and
  nothing after Cancel). Then record what an SMS (green-bubble) recipient and a recipient without
  Fernlet each see, and whether "Include notes" off really sent no notes and no steps.
- [ ] Sender and receiver use different supported Fernlet versions: verify unsupported envelopes
  are rejected before any inbox write.
- [ ] Receiver does not have Fernlet: confirm Messages shows the standard app-install path and no
  Fernlet data is exposed outside the card.
  The install sheet is empty while Fernlet has no public App Store page, and the card's `data:` URL
  gets no browser fallback, so such a recipient sees an empty sheet. Every card carries "Opens in
  Fernlet on iPhone" as its trailing subcaption so that recipient can read why. On a receiving device
  WITHOUT Fernlet (or with a build older than 24, the first TestFlight build that carries the
  extension), confirm the bubble is drawn at all, with its caption and that line, and not truncated:
  it has been seen only on a recipient that has the extension.
- [ ] After installing a Fernlet update, force-quit Messages on BOTH phones, then send and open one
  card. *2026-09-30, CONFIRMED by the owner: the "pops up and is blank" report was Messages, not this
  extension. When Fernlet is updated or reinstalled while Messages keeps running, pkd registers the
  extension under a new UUID but the running Messages process keeps asking for the old one, and the
  tapped card's sheet (always blank for its first ~1.2-1.5 s) is never filled. Log signature, from
  MobileSMS: `[com.apple.PlugInKit:lifecycle] ... [MBO.Fernlet.MessagesExtension(1.0)] Failed to start
  plugin; pkd returned an error: ... Code=4 "no such plugin (uuid not found)"`, then
  `[com.apple.Messages:AppCards] Loaded remote view. Success=false`. The + > Fernlet composer is blank
  in the same state, and every re-tap fails until Messages is relaunched. No Fernlet code runs, so the
  extension cannot detect or fix it. Reproduced on the iOS 26.5 simulator with the Release build of
  build 24 (reinstall Fernlet while MobileSMS keeps running, then tap a received card); a freshly
  launched Messages draws the card in ~1.4 s. On the owner's iPhone, the Messages process had survived
  the build-24 TestFlight update; force-quitting Messages fixed it. Report it to Apple (Feedback:
  Messages keeps a stale PlugInKit UUID after the containing app updates).*
- [ ] TestFlight "What to Test" note: "After installing a Fernlet update, force-quit Messages once on
  each phone before sending or opening Fernlet cards." Fernlet cards open only on an iPhone with build
  24 or later.
- [ ] Forward each card, then open it on a second recipient device. Confirm the packet UUID/hash
  survive forwarding and the replay ledger prevents a second canonical import.
- [ ] Delete the source recipe/workout after sending. Confirm the received packet remains
  independently reviewable.
- [ ] Receive while offline, then reconnect and import. Confirm no hosted Fernlet link is needed.

## Privacy and review

- [ ] Send while the receiving phone is locked. The extension must not bypass protected storage;
  Fernlet should ask the user to unlock before it can review the inbox record.
- [ ] Tap **Review in Fernlet** for a recipe with cooking notes: inspect serving, ingredient, and
  step counts, confirm the notes match the sent recipe, and confirm photos are absent.
- [ ] Tap **Review in Fernlet** for a workout: change the start date and each collision policy;
  confirm the calendar preview, safety flags, and add/change/remove counts refresh before save.
- [ ] Change the recipient calendar while the workout review is open. Confirm the action requires
  review again rather than applying the stale preview.
- [ ] Kill Fernlet between inbox handoff and import, then relaunch from the same message. Confirm
  the review resumes or expires cleanly without a duplicate import.
- [ ] Use **Delete everything** with queued recipe and workout cards. Confirm neither card can
  reopen a pre-wipe import review.
- [ ] After **Delete everything** — and separately after a duress wipe entered at the lock screen
  right after launch — open Fernlet in the Messages app drawer and confirm the composer lists no
  pre-wipe recipe or workout (the catalog clear stopped depending on launch wiring on 2026-09-23).

## Accessibility and presentation

- [ ] Verify compact and expanded composer presentation for recipes and workouts.
- [ ] Verify Dynamic Type, VoiceOver labels, and reduced-motion behavior in the composer and both
  Fernlet review screens.
- [ ] Confirm static/local card artwork renders without a network request.
- [ ] Confirm the iMessage App Icon (`App/FernletMessagesExtension/Assets.xcassets`) on a physical
  iPhone — in the Messages "+" menu (light and dark) and in Settings — and, once uploaded, that App
  Store Connect accepts the 1024×768 image.
  *Since 2026-09-24 the art is purpose-made, not the placeholder: the Home Screen sprig re-framed for
  4:3 and fitted inside the "+" menu's mask, owner-approved, rendered by
  `Scripts/render-imessage-icon.py` (never hand-edit the PNGs). The iOS 26.5 simulator shows it
  correctly in light and dark mode; hardware and App Store Connect are what is left.*

## Localization

The target had NO string catalog until 2026-08-27 — it shipped a round with 57 bare English
sentences, and no wall could see them. It now owns
`App/FernletMessagesExtension/Localizable.xcstrings`, has a line in the `TARGETS` array of
`Scripts/sync-string-catalogs.sh`, and its whole display surface lives in `FernletMessagesCopy`.
`LocalizationBoundaryTests` rules H1 and H2 keep it that way mechanically; what is left here is what
a scan cannot judge.

- [ ] `Scripts/sync-string-catalogs.sh --check` passes. Any code change that touched a sentence
  needs the synced catalog committed WITH it — an un-synced catalog silently stops tracking the
  code, and `--check` is the only thing that says so.
- [ ] Run the composer at the largest accessibility text size in a language whose strings are
  longer than English (German is the usual worst case). The two segment titles, the share button
  and the three status lines are the tight spots.
- [ ] Check the two card WORDMARKS (`messages.card.wordmark.recipe`, `…workout`). They are drawn
  into a 1200×630 image at a fixed 28 pt, so unlike every other string here they cannot reflow — a
  long translation is clipped, not wrapped, in the artwork the RECIPIENT sees.
- [ ] Check the four count strings at 1 and at 2+ (`messages.recipe.servingCount`,
  `…ingredientCount`, `…stepCount`, `messages.workout.sessionCount`). They carry hand-authored
  `one`/`other` plural variations; `xcstringstool sync` preserves a plural block but will never
  re-create one, so a dropped block is silent and shows up only as "1 servings".
- [ ] Confirm the product name renders untranslated wherever it appears ("Fernlet recipe",
  "Review in Fernlet", the `⌁ FERNLET` brand mark), and that "Review in Fernlet" has not been
  translated as "Save" or "Import" — it opens a review and saves nothing.
