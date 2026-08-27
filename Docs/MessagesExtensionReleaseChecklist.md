# Messages extension release checklist

The automated exchange tests cover packet envelopes, bounds, corruption, App Group coordination,
inbox expiry/wipe behavior, replay-ledger behavior, the extension dependency wall, and the exact
nine-entry App Shortcuts allocation. The following scenarios still require two physical iPhones
with Fernlet's Messages extension enabled; do not substitute the simulator for them.

## Transport and compatibility

- [ ] Measure the largest successful `MSMessage.url` envelope on the current iOS release. Record
  the measured limit and keep `ExchangeLimits.maxMessageEnvelopeBytes` below it; never infer it
  from the 64 KB recipe or 512 KB workout-file limits.
- [ ] Sender and receiver both have the shipping Fernlet version: send and review one recipe and
  one planned-workout card.
- [ ] Sender and receiver use different supported Fernlet versions: verify unsupported envelopes
  are rejected before any inbox write.
- [ ] Receiver does not have Fernlet: confirm Messages shows the standard app-install path and no
  Fernlet data is exposed outside the card.
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

## Accessibility and presentation

- [ ] Verify compact and expanded composer presentation for recipes and workouts.
- [ ] Verify Dynamic Type, VoiceOver labels, and reduced-motion behavior in the composer and both
  Fernlet review screens.
- [ ] Confirm static/local card artwork renders without a network request.

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
