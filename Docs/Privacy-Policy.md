# Fernlet Privacy Policy

<!-- Maintainer note (not published prose): this text was finalized 2026-07-19 and revised
     2026-08-09 (Section 13 rewritten: perpetual no-retroactive-use commitments), 2026-08-11
     (opt-in encrypted photo backup; §4 backup-category list), and 2026-08-12 (2026-08-10/11
     security-hardening round: hard SE-binding of the sealed store, default device-backup
     exclusion, duress PIN, journal text removed from the plaintext-sync list, no-backdoor
     statement; intimacy age gate corrected to 16+ to match the shipped gate), and again
     2026-08-12 (§7 manual plan exchange: the opt-in clipboard export of a training summary to an
     outside assistant), and 2026-08-19 (§9 moderation-report disclosure: a report is signed and
     relayed to friends met in person — the reported maker among them — not merely device-local;
     finding L21), and 2026-08-19 (§6/§12 away-hearts disclosure: the opt-in "deliver hearts when
     apart" setting leaves sealed hearts in our CloudKit public database, deletable only by the
     sending device and with no server-side expiry, so "no friend server" is now scoped to the
     default configuration and "they age out on their own" is removed as false; §7 the clipboard
     copy is device-local — findings I32, L18), and 2026-08-20 (§3 Apple Health writes and §10
     export contents corrected to match the code: the previous text said Fernlet wrote "only the
     workouts you log" and "never" wrote period data, and that the export excluded all sealed
     categories. Both were WRONG and had been for some time — the app also writes cycle samples,
     sexual activity, mindful minutes, and height/body mass, each behind its own Apple permission
     prompt, and the export deliberately includes journal text because it sits behind a fresh
     biometric check. No app behaviour changed; the policy was corrected to describe behaviour that
     already existed and was always separately consented, so this is a clarification rather than a
     §13 weakening. Anyone who read the old text deserves to be told.). Before
     submission: (1) host this text at a public URL and enter that URL in App Store Connect, and
     (2) keep it in sync with the in-app copy in App/Fernlet/PrivacyPolicyView.swift (Settings →
     Privacy Policy) AND the hosted copy in Site/privacy/index.html. Any material change: update
     the effective date in all three. -->

**Effective date:** August 20, 2026
**Developer:** Michael Bowman Olay
**Contact:** fernletapp@gmail.com

---

## The short version

Fernlet is a private, gentle self-care companion. It is built **privacy-first, on-device by
design**. We — the developer — do not run servers that collect your health data, we do not sell or
share your data, we do not use advertising or third-party analytics or tracking, and we never do
face recognition. Most of what you log never leaves your phone. The parts that can be backed up go
to **your own** iCloud account, not to us, and the most sensitive parts are encrypted on your device
first so that not even Apple can read them.

This policy explains, in plain language, exactly what data Fernlet handles and where it goes.

---

## 1. Who controls your data

Fernlet has no backend that we operate. Your data lives in three places, all under your control:

1. **On your device** — the default home for nearly everything you log.
2. **Your personal iCloud account** — if you turn on iCloud sync and/or encrypted backup. This is
   Apple's infrastructure tied to your Apple ID, not ours. We never receive a copy.
3. **Directly between phones, in person** — for the optional friend features, which work over a
   short-range peer-to-peer connection when two people are physically near each other.

We, Michael Bowman Olay, do not receive, store, or have access to your health information,
journal entries, photos, memories, cycle data, friend list, or location.

## 2. What Fernlet stores on your device

Almost everything, including:

- **Health & activity you log:** meals and their nutrition, workouts, hydration, hygiene, sleep,
  and your daily wellbeing score.
- **Journal entries** and the gentle reflections derived from them.
- **Memories** — short notes Fernlet keeps so it can respond to you thoughtfully over time.
- **Your companion's appearance, wardrobe, coins, and milestones.**
- **Cycle/period tracking**, if you use it.
- **Photos** you add to your private album.
- **App settings and preferences.**

Sensitive categories — **period/cycle data, sensitive memories, journal text, Worry Box notes, and
any intimate-activity notes** — are stored in an **encrypted, sealed store** on your device. These
sealed categories are walled off inside the app so that on-device AI and any networking code cannot
read the raw data.

The key that opens the sealed store is locked to **this device's security hardware** (the Secure
Enclave). That means sealed data cannot be recovered on any other device — or on this device after
it has been erased, reset, or replaced — from any device backup, **even with your correct app
passcode**. The only way sealed data can follow you to a new phone is the opt-in encrypted sealed
backup described in Section 4. If the sealed store can no longer be opened on this device, the app
tells you so plainly instead of failing silently.

Separately, your phone's own **device backup** (iCloud Backup or a computer backup): for new
installs, Fernlet's local data files — the sealed store and your local history database — are
**excluded from device backups by default**. If you were already using Fernlet before this default
existed, the app asks you once, plainly, which you prefer. You can change this at any time with the
"Include local data in iOS backup" toggle in Settings → Privacy & Data. That toggle does not cover
photo files (see Section 5).

## 3. HealthKit (Apple Health)

With your permission, Fernlet **reads** the following from Apple Health to reflect your day: heart
rate, active energy, sleep analysis, step count, and workouts.

Fernlet **writes** to Apple Health only what you log yourself, and only in the categories you have
separately granted — Apple asks per category, and declining any one of them simply turns that write
off:

- **Workouts** you log, so they count toward your Apple activity rings.
- **Cycle data**, if you use cycle tracking: menstrual flow, basal body temperature,
  cervical mucus quality, ovulation test results, and spotting. These are the clinical samples of
  your cycle, and they go to Apple Health so your own Health app shows a complete Cycle Tracking
  picture. **The notes you write about your cycle are not among them** — those stay sealed and
  encrypted on your device (Section 2).
- **Sexual activity**, if you use intimate logging: the event and, if you record it, whether
  protection was used. Your notes stay sealed on your device.
- **Mindful minutes**, when you finish a breathing session.
- **Height and body mass**, from the body profile you enter, when you turn on Health syncing for it.

Fernlet **never** writes your journal text, your mood, your hydration, or your hygiene log to Apple
Health.

Health data accessed through HealthKit is used only on your device to compute your companion's state
and your derived trends. It is **never** used for advertising, never sold, and never shared with us
or any third party. Deleting Fernlet does not delete samples Fernlet wrote to Apple Health — remove
those in the Health app if you wish.

## 4. iCloud sync and encrypted backup (optional, you choose)

During setup you choose whether to keep your data **only on this device** or **sync it to iCloud**.

- **iCloud sync (optional):** If enabled, your core app data (meals, workouts, hydration, hygiene,
  sleep, scores, settings, derived signals, and core memories) is synced to **your own iCloud
  private database** using Apple's CloudKit. Journal **text** is not part of this sync: the days
  and structure of your journal sync, but the words you wrote are sealed on your device and leave
  it only as ciphertext, through the opt-in encrypted backup below. This is associated with your
  Apple ID under Apple's standard privacy model. We cannot see it. You can turn this off or delete
  the cloud copy at any time in Settings → Privacy & Data. Deleting the cloud copy never deletes
  your local copy or your Apple Health history.
- **Encrypted sealed backup (separate, off by default):** You may separately opt in to back up
  **sensitive memories**, **period data**, **journal entries**, **intimate logs** and/or **your own
  photos** (see §5). Before this data leaves your device it is encrypted
  with a key derived from a dedicated backup key (AES-256-GCM). Apple stores only unreadable
  ciphertext. Because the key lives in your iCloud Keychain, **if you permanently lose access to your
  iCloud Keychain on all your devices, this encrypted data cannot be recovered.** You are told this
  when you enable it. Period-data backup is a deliberate, clearly-warned opt-in because of the
  sensitivity of that information. Because the sealed store's key is locked to this device's
  security hardware (Section 2), this opt-in backup is the **only** way the sealed categories can be
  recovered on another or an erased device — without it, sealed data is unrecoverable off this
  device, full stop. The journal, period-data and intimate-log parts of this backup require
  Fernlet's app lock: without one, those categories cannot be backed up at all (sensitive memories
  still can be). And notes you let go of in the **Worry Box** are
  deliberately excluded from every backup — they exist only on this device and do not survive a
  device erase.

## 5. Photos

Photos are stored **encrypted in the app's private storage** and are **never** sent to any AI or
server, and never analyzed. **By default they are also never uploaded to CloudKit** — they leave
your phone only inside your standard iCloud **device backup**, through the app container (the same
way other app files are), unless you turn Fernlet off in your device's iCloud Backup settings. Note
that the app's own "Include local data in iOS backup" toggle (Section 2) does **not** cover photo
files — only that system-level switch removes photos from device backups.

There is exactly **one exception, and it is off unless you turn it on.** If you switch on
"Sealed backup for your photos" in Settings → Privacy & Data, your **own** meal, recipe and
gym-progress photos are backed up to **your own iCloud private database**. Each photo is encrypted
on your device before it leaves (AES-256-GCM, under a key derived from the same dedicated backup
key), so Apple stores only unreadable ciphertext — and it is still never sent to us and never sent to any AI.
Photos **friends have shared with you** are never part of that backup.

Once that backup has actually stored your photos, Fernlet **locks their encryption key to this
device**, so future device backups can no longer open them. The lock protects only backups made
*after* you turn it on — a device backup made *before* still carries a working copy of the key.
The lock is permanent, and from then on the encrypted photo backup is the route by which those
photos come back on a new phone. You are told this before you turn the backup on, and there is a
separate, clearly-warned way to lock them to this device *without* the backup if you prefer the
protection to the recovery.

You may explicitly export an individual photo to your system Photos library with a "Save to Photos"
action — that is a one-time export you initiate, not automatic sync. Fernlet does **no face
recognition** and no automated photo analysis of your photos.

## 6. Identity keys and friend features (in-person only)

To support optional in-person friend features, Fernlet generates a cryptographic identity for your
device on first launch. The keys are stored in your device's Keychain and never sync to iCloud
Keychain — a new phone starts with a fresh identity, and you re-add friends in person. Your
**public key** is the only persistent identifier shared with friends; your private keys never
leave your device.

By default the friend features work **only when two people are physically near each other**, over a
short-range, encrypted, peer-to-peer connection — no friend server, and no remote friend activity.
When you add a friend in person, your devices exchange your display names, public keys, avatar
appearances, and a **fuzzy** wellbeing vibe (e.g. "thriving," "okay," "struggling"). Friends **never**
see your numeric score, your goals, your cycle information, or any raw health data. You can send
"hearts," share recipes, and share custom companion clothing with nearby friends. All of this stays
device-to-device.

There is one **optional exception**, and it is off unless you turn it on. If you switch on
**Deliver hearts when apart**, a heart you send to a friend you already added in person is sealed end to end
and left in a shared iCloud drop-off area under a rotating, meaningless tag, so their phone can pick
it up later. Only sealed hearts go there — never your own data, and nothing that names either of you.
We cannot read them. Turning the setting off deletes the ones still waiting.

Optional coarse (approximate) location may be used only for gentle weather-based prompts and, if you
choose, to tag an in-person group activity. Location is never tracked over time and never attached to
your identity for us.

## 7. Artificial intelligence

Fernlet's AI features (for example, suggesting a workout, summarizing your day, or reflecting on a
journal entry) run **on your device** using Apple's on-device models. Your journal text, memories,
health data, photos, period data, and friend data are **not** sent to any external AI service.

Some optional convenience features may look up **non-personal reference data** from public sources —
for example, fetching the nutrition facts for a packaged product or a recipe you're importing. Those
lookups send only the minimal query needed (such as a product name or a recipe URL) and never attach
your identity, health data, or any sensitive information.

Fernlet does not use AI to generate mental-health diagnoses or clinical labels, and it filters such
language out of anything it stores.

**Copying a training summary for an outside assistant (off by default).** There is one place where
you can deliberately take your data to an AI service Fernlet has no relationship with. If you turn
on **Manual plan exchange** in Settings, "Share with a trainer" on the Move tab gains a button that
copies a training summary — your workouts, macro targets and recent meals, equipment, the
muscles and movements you avoid, and the workouts you've already planned for the coming weeks —
to your clipboard as plain text, so you can paste it into an assistant of your choosing and
paste the workout plan it writes back into Fernlet.

This is off unless you switch it on, and Fernlet still sends nothing anywhere: the copying and the
pasting are both actions you take. The copy is marked device-local, so it is not shared to your other
Apple devices through Universal Clipboard. But once you paste that text into another app, that app has it,
under its own privacy policy and not ours — Fernlet cannot reach it or take it back. The summary
never includes your journal, period or cycle data, intimate data, photos, friends, location, or
your private keys. A plan you paste back is shown to you day by day, and checked against the
muscles and movements you avoid, before anything is added to your week. A plan can also change
or remove workouts you had already planned; you see every such change, before and after, before
accepting it. Nothing you have already logged is ever altered.

## 8. What we do NOT do

- We do **not** sell, rent, or trade your personal data.
- We do **not** use third-party advertising, ad networks, or cross-app/cross-site tracking.
- We do **not** embed third-party analytics SDKs that profile you.
- We do **not** perform face recognition or biometric identification of people in your photos.
- We do **not** operate a server that collects your health or journal data.
- We do **not** require an account or a login to use the app.
- We do **not** hold a master key or any recovery backdoor. We cannot bypass or remove your app
  lock for you, and we cannot recover your sealed data — nobody can, not us, not Apple, not any
  future owner of the app. The only recovery route is the encrypted sealed backup you may opt
  into (Section 4).

## 9. User-generated content and safety

If you create custom companion clothing and share it with friends in person, that content is
governed by our in-app rules against objectionable content. You can **report** and **block** content
and the people who share it; reporting hides the content on your device and blocks that person, and
Fernlet keeps an on-device record used to limit abusive sharing. Because sharing is peer-to-peer,
moderation works device to device: when you report an item, a signed record of that report — the
item, the reason, the maker's key and your key — is passed to friends you meet in person so their
devices can hide repeatedly reported content. The maker you reported is one of those friends, so a
report is not anonymous to them. It never reaches us or any server. The full content rules are shown
in the app, and use of the app is governed by Apple's standard Licensed Application End User License
Agreement.

## 10. Your controls and rights

In Settings you can:

- Choose local-only storage or iCloud sync, and change it any time.
- Turn encrypted sealed backup on or off per category, including "Sealed backup for your photos"
  (Section 5).
- Lock your photos' encryption key to this device *without* any backup, if you prefer the
  protection to the recovery (clearly warned; permanent).
- Choose whether Fernlet's local data files are included in your device backup ("Include local
  data in iOS backup" — excluded by default for new installs; see Section 2).
- Set an optional **duress PIN**: a second app passcode with one response you choose — open a
  **decoy** view with sensitive content hidden (nothing is destroyed), perform a **silent wipe**,
  or trigger a **recovery lock** (both described in Section 12). Entering it looks exactly like a
  normal unlock — nothing on the screen, in the unlock's timing, or in the app's activity log
  gives away that a duress PIN is configured.
- **Reset app lock** — permanently destroys every key that can open the sealed categories on this
  device (a crypto-erase): the sealed data on this phone becomes unreadable for good. A cloud copy
  in the opt-in encrypted sealed backup (Section 4), if you enabled it, is separate and survives a
  lock reset — turn that backup off to delete it.
- **Export your data** as a file you can save or share. The export is reached from behind a fresh
  biometric check, and it is *your* data, so it **includes your journal entries**. It leaves out
  period and cycle data, intimate-activity data, sensitive (Tier-2) memories, Worry Box notes,
  photo image data, and your private cryptographic keys. The file states its own contents in a
  preamble, so you can see exactly what you are about to share before you share it.
- Delete your iCloud copy.
- Delete your data.
- Manage or wipe the memories Fernlet keeps.

Depending on where you live, you may have additional rights (such as access, correction, deletion,
or portability). Because we do not hold your data on our own servers, you exercise these rights
directly in the app; contact us at fernletapp@gmail.com with any questions.

## 11. Children

Fernlet is not directed to children under 13. Intimate-tracking features are gated to users
who indicate they are 16 or older and are hidden and off by default.

## 12. Data retention

Data is retained on your device until you delete it or delete the app. iCloud copies are retained in
your iCloud account until you delete them in the app or in your Apple ID storage settings. We hold no
copy we can read.

One thing does sit outside your own iCloud storage, and only if you turned it on: **away hearts**
(Section 6). A heart you send while your friend is elsewhere is stored, sealed, in a shared area of
our iCloud database until their phone picks it up or your phone cleans it up. It is unreadable to us
and carries no name. Only the device that wrote a heart can delete it — so if you delete Fernlet
without first using **Delete Everything**, or turn the setting off, the hearts you already sent stay
there, because the information needed to delete them lived only on your phone. They remain sealed,
unreadable ciphertext that is never linked to you by name. Use Delete Everything, or turn away hearts
off, before you uninstall, and Fernlet clears them for you.

If you configured a duress PIN (Section 10), its responses have specific retention consequences:

- **Decoy** destroys nothing. It opens a view with sensitive content hidden; all your data is
  retained.
- **Silent wipe** immediately destroys every key that can open sealed data on this device — an
  instant, irreversible **crypto-erasure** — and then deletes the remaining local data, your iCloud
  copies, and the samples Fernlet wrote to Apple Health, on a best-effort basis. Encrypted backup
  data or in-transit "hearts" stored off the device may persist, but they are unopenable ciphertext.
  They are removed when the purge completes; if the purge cannot run — no network at that moment, or
  the app was already deleted — they stay where they are, sealed and unreadable, and nothing can
  address them afterwards to remove them.
- **Recovery lock** is **not** deletion. It destroys this device's unlock keys, so everything
  sealed stays on the phone as unreadable ciphertext — a lock-out, not an erase. The data can be
  recovered only in person, through a mutual QR ceremony with a second device **you** previously
  enrolled as your own recovery device. There is no cloud or remote route, and the recovery device
  is always your own — never us, never a third party.

## 13. Changes to this policy — and the promises that cannot change

If we make material changes, we will update the effective date above and surface the change in the
app.

Some of this policy is **permanent**. The following commitments are perpetual: they bind this
version of Fernlet, every future version, and any future owner or maintainer of the app:

- **Data you logged under this policy is never retroactively repurposed.** Anything Fernlet stored
  while this policy was in force stays governed by the promises that were in force when you logged
  it. No future update may reach back and use, upload, analyze, sell, or share that data under
  weaker terms.
- **The no-collection guarantee does not expire.** Fernlet is built so that the developer receives
  none of your health, journal, photo, memory, cycle, friend, or location data (Sections 1 and 8),
  and that guarantee binds every future version and owner — no future version may begin collecting
  from data you already entered.
- **Weakening ever requires your fresh, affirmative consent.** Any future change that would send
  existing data somewhere new, or handle it less protectively, takes effect only for users who
  explicitly and separately agree to it after being clearly told what changes. Continued use,
  silence, or installing an update is **never** consent to such a change — and declining must
  either leave the app usable with your data handled under the old terms, or let you export and
  delete your data first.

For everything else — clarifications, new features, stronger protections — continued use after an
update means you accept the revised policy.

How these promises are backed technically (build-enforced boundaries, a published network-egress
inventory, and a standing invitation to audit the app's traffic) is described in the project's
verifiability statement, `Docs/Verifiability.md`, alongside the source code.

## 14. Contact

Questions about this policy or your privacy: **fernletapp@gmail.com**
Michael Bowman Olay

---

*Fernlet is a wellness and self-care companion, not a medical device. It does not provide medical
advice, diagnosis, or treatment. If you are in crisis, contact your local emergency services or, in
the US, call or text 988 (the Suicide & Crisis Lifeline).*
