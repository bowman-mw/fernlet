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
- [ ] Tap **Review in Fernlet** for a recipe: inspect serving, ingredient, and step counts and
  confirm notes/photos are absent.
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
