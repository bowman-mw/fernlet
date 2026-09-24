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
     §13 weakening. Anyone who read the old text deserves to be told.), and 2026-09-24 (the
     2026-09-23 owner-decisions round, several parts of which correct text that had been false:
     §2/§4/§7 Core memory never holds journal text — an entry leaves only its mood, or, with the
     on-device AI helper on, a short on-device summary checked not to copy it; until this round a
     memory kept the entry's first 120 characters, which synced while §4 said journal text never
     did (earlier excerpts were not migrated: nothing tells them apart from words a user typed, and
     there is no real user data yet). §2/§4 sensitive (Tier-2) memories never leave the device in
     any form — they had synced in plaintext while §2 placed them in the sealed store; they now
     live in a backup-excluded device-only file, and the encrypted "sensitive notes" backup is
     retired, any old copy deleted from iCloud automatically. §3 nothing Fernlet reads from Apple
     Health is stored in iCloud by Fernlet — the readings had synced in the day records while §3
     said Health data was used only on the device; the read list is completed (it said "heart
     rate" where Fernlet reads resting heart rate and heart-rate variability, and omitted exercise
     minutes, mindful minutes, respiratory rate, wrist temperature and the body profile); writes
     now happen only while Fernlet's own switches are on — a logged workout used to be written with
     them off — with one ask at the first workout; the optional body-tension history is named as
     the one Health-derived file a device backup can still carry. §4 the synced friends list and
     session log are named; they always synced. §5 "never analyzed" was wrong: Apple's on-device
     Vision framework reads the barcode, label or food in a photo taken to log food. §1/§6/§12 the
     iMessage app. §7 the Open Food Facts barcode lookup. §9 the shop pause, its remaining time,
     and its wipe-surviving record. §11 intimacy tracking has been on by default for users 16+ since
     2026-07-16 — "hidden and off by default" was wrong — and onboarding now offers to turn it off.
     The behaviour changes tighten protection and the new features send only what the user
     chooses, on a tap, so none of this weakens an existing promise under §13; anyone who read the
     old text deserves to be told). Before
     submission: (1) host this text at a public URL and enter that URL in App Store Connect, and
     (2) keep it in sync with the in-app copy in App/Fernlet/PrivacyPolicyView.swift (Settings →
     Privacy Policy) AND the hosted copy in Site/privacy/index.html. Any material change: update
     the effective date in all three. -->

**Effective date:** September 24, 2026
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

When you choose to send a recipe or a planned workout in Messages, that copy goes to the people you
send it to (Section 6).

We, Michael Bowman Olay, do not receive, store, or have access to your health information,
journal entries, photos, memories, cycle data, friend list, or location.

## 2. What Fernlet stores on your device

Almost everything, including:

- **Health & activity you log:** meals and their nutrition, workouts, hydration, hygiene, sleep,
  and your daily wellbeing score.
- **Journal entries** and the gentle reflections derived from them.
- **Memories** — short notes Fernlet keeps so it can respond to you thoughtfully over time. A
  memory drawn from a journal entry never holds your words: it keeps only that entry's mood (for
  example "bright" or "hard"), or — if the on-device AI helper is on — a short summary the
  on-device model writes in its own words (Section 7).
- **Your companion's appearance, wardrobe, coins, and milestones.**
- **Cycle/period tracking**, if you use it.
- **Photos** you add to your private album.
- **App settings and preferences.**

Sensitive categories — **period/cycle data, journal text, Worry Box notes, and any
intimate-activity notes** — are stored in an **encrypted, sealed store** on your device. These
sealed categories are walled off inside the app so that on-device AI and any networking code cannot
read the raw data.

**Sensitive memories** — the private observations Fernlet infers about your patterns so it can
respond gently — **never leave this device in any form**. They are not synced to iCloud and are not
part of any backup (neither the optional encrypted backup nor your phone's own device backup), and
they are protected by your device's file encryption. On a new or restored phone, Fernlet works them
out again from the logs on that phone.

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
photo files (see Section 5). Some files are kept out of device backups whatever it says — among
them your sensitive memories (above) and the file of daily readings Fernlet takes from Apple Health
(Section 3 names the one Health-derived file that is not).

## 3. HealthKit (Apple Health)

With your permission, Fernlet **reads** the following from Apple Health to reflect your day. You
share each kind separately — in Settings → Health, or when Fernlet asks at the moment a feature
needs it — and Fernlet reads a kind only while it is shared:

- **Workouts & activity:** workouts, including ones other apps saved to Apple Health; step count;
  active energy; and exercise minutes.
- **Body signals:** sleep analysis (including sleep stages), resting heart rate, and heart-rate
  variability — plus respiratory rate and sleeping wrist temperature if you turn on "Notice body
  tension".
- **Mindfulness:** mindful minutes.
- **Body measurements:** your age, sex, height, and weight, for your nutrition targets.
- **Cycle tracking** and **intimate logging**, if you use them: your cycle observations and
  sexual-activity events.

Fernlet **writes** to Apple Health only what you log yourself, only in the categories you have
separately granted — Apple asks per category, and declining any one of them simply turns that write
off — and only while Fernlet's own **Share with Health** switch is on and that kind of data is
shared in Settings → Health. With either off, Fernlet writes nothing to Apple Health. Fernlet asks
about workouts at most once, the first time you log or start one, and never again once you decline
or turn Health off in Settings; you can share workouts in Settings → Health at any time:

- **Workouts** you log, so they count toward your Apple activity rings.
- **Cycle data**, if you use cycle tracking: menstrual flow, basal body temperature,
  cervical mucus quality, ovulation test results, and spotting. These are the clinical samples of
  your cycle, and they go to Apple Health so your own Health app shows a complete Cycle Tracking
  picture. **The notes you write about your cycle are not among them** — those stay sealed and
  encrypted on your device (Section 2).
- **Sexual activity**, if you use intimate logging: the event and, if you record it, whether
  protection was used. Your notes stay sealed on your device.
- **Mindful minutes**, when you finish a breathing session.
- **Height and body mass**, from the body profile you enter, when body measurements are shared with
  Health.

Fernlet **never** writes your journal text, your mood, your hydration, or your hygiene log to Apple
Health. When you remove a workout or delete a cycle day in Fernlet, Fernlet also removes the copy it
wrote to Apple Health — even while sharing is off, since removing adds nothing to Apple Health. It
can only ever remove samples Fernlet itself wrote.

**Nothing Fernlet reads from Apple Health is stored in iCloud by Fernlet** — not in iCloud sync, and
not in the encrypted backup. Your steps, energy and exercise minutes, sleep and heart readings,
mindful minutes, the workouts other apps saved to Apple Health, and the age, sex, height and weight
Fernlet reads for your body profile stay on the device that read them, in a device-only file that is
also excluded from your phone's device backup. If you use Fernlet on more than one device, each one
reads Apple Health for itself. Turning off **Share with Health**, or deleting everything, erases that
file.

One file is the exception to the device-backup part: if you turn on "Notice body tension", the
60-day history of heart-rate variability, resting heart rate, breathing rate and wrist temperature it
compares against stays on this device and never syncs, but your phone's own device backup can include
it unless you turn Fernlet off in your device's iCloud Backup settings. Turning that setting off, or
deleting everything, erases it.

Health data accessed through HealthKit is used only on the device that read it, to compute your
companion's state, your derived trends, and your nutrition targets. It is **never** used for
advertising, never sold, and never shared with us or any third party. Your daily wellbeing score,
your companion's state, and the coins you earn for an active day are Fernlet's own results, worked
out partly from these readings; if you use iCloud sync they sync with the rest of your app data,
while the readings themselves never do. Deleting Fernlet does not delete samples Fernlet wrote to
Apple Health — remove those in the Health app if you wish.

## 4. iCloud sync and encrypted backup (optional, you choose)

During setup you choose whether to keep your data **only on this device** or **sync it to iCloud**.

- **iCloud sync (optional):** If enabled, your core app data (meals, the workouts you log in
  Fernlet, hydration, hygiene, the sleep you log yourself, scores, settings, derived signals, core
  memories, your friends list, and a log of your recent in-person sessions) is synced to **your own
  iCloud private database** using Apple's CloudKit. Your friends list holds the display names and
  public keys of the friends you added in person, when you added and last saw them, and any block or
  report you made; the session log records which friend, when, and what kind of item was sent or
  received — never the item itself. **Nothing Fernlet reads from Apple Health is part of this sync**
  (Section 3), and neither are your sensitive memories (Section 2). Journal **text** is not part of
  this sync: the days and structure of your journal sync, but the words you wrote are sealed on your
  device and leave it only as ciphertext, through the opt-in encrypted backup below.
  Core memories never hold your journal text either: a memory drawn from a journal entry syncs as
  the entry's mood or, if the on-device AI helper is on, as a short summary the on-device model
  wrote, which Fernlet checks is not a copy or an excerpt of your entry and uses no clinical
  language — though, being a summary, it does say what the entry was about. This is associated with
  your Apple ID under Apple's standard privacy model. We cannot see it. You can turn this off or
  delete the cloud copy at any time in Settings → Privacy & Data. Deleting the cloud copy never
  deletes your local copy or your Apple Health history.
- **Encrypted sealed backup (separate, off by default):** You may separately opt in to back up
  **period data**, **journal entries**, **intimate logs** and/or **your own photos** (see §5).
  Before this data leaves your device it is encrypted
  with a key derived from a dedicated backup key (AES-256-GCM). Apple stores only unreadable
  ciphertext. Because the key lives in your iCloud Keychain, **if you permanently lose access to your
  iCloud Keychain on all your devices, this encrypted data cannot be recovered.** You are told this
  when you enable it. Period-data backup is a deliberate, clearly-warned opt-in because of the
  sensitivity of that information. Because the sealed store's key is locked to this device's
  security hardware (Section 2), this opt-in backup is the **only** way the sealed categories can be
  recovered on another or an erased device — without it, sealed data is unrecoverable off this
  device, full stop. The journal, period-data and intimate-log parts of this backup require
  Fernlet's app lock: without one, those categories cannot be backed up at all. Sensitive memories
  are never backed up, by design; if you had switched on the former encrypted backup of sensitive
  memories, Fernlet deletes that copy from your iCloud automatically. And notes you let go of in the
  **Worry Box** are deliberately excluded from every backup — they exist only on this device and do
  not survive a device erase.

## 5. Photos

Photos are stored **encrypted in the app's private storage** and are **never** sent to any server or
to any AI service. The only analysis of a photo happens on your device, with
Apple's Vision framework, and only to log food: it reads a barcode or a nutrition label in a photo
you take or choose for that, and — if the on-device AI helper is on and you ask Fernlet to identify
a meal from a photo — it suggests what food the photo shows, which you review before anything is
logged. **By default they are also never uploaded to CloudKit** — they leave
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
recognition**, and apart from the food-logging reads above, no analysis of your photos.

## 6. Identity keys and friend features (in-person only)

To support optional in-person friend features, Fernlet generates a cryptographic identity for your
device on first launch. The keys are stored in your device's Keychain and never sync to iCloud
Keychain — a new phone starts with a fresh identity, and you re-add friends in person. Your
**public key** is the only persistent identifier shared with friends; your private keys never
leave your device.

By default the friend features work **only when two people are physically near each other**, over a
short-range, encrypted, peer-to-peer connection — no friend server, and no remote friend activity.
When a session is live, Fernlet may ask iOS for a short spell of background time so the connection
survives you leaving the app; that continuation uses your local network and some battery,
iOS may refuse or end it at any time, and nothing already saved is lost when it does.
When you add a friend in person, your devices exchange your display names, public keys, avatar
appearances, and a **fuzzy** wellbeing vibe (e.g. "thriving," "okay," "struggling"). Friends **never**
see your numeric score, your goals, your cycle information, or any raw health data. You can send
"hearts," share recipes, and share custom companion clothing with nearby friends. All of this stays
device-to-device.

There is one **optional exception**, and it is off unless you turn it on. If you switch on
**Deliver hearts later**, a heart you send to a friend you already added in person is sealed end to end
and left in a shared iCloud drop-off area under a rotating, meaningless tag, so their phone can pick
it up later. Only sealed hearts go there — never your own data, and nothing that names either of you.
We cannot read them. Turning the setting off deletes the ones still waiting.

**Separately from the friend features: sharing a recipe or a planned workout in Messages.** Fernlet
includes an iMessage app. When you open it in a Messages conversation, it lists the recipes and
upcoming planned workouts the Fernlet app has prepared for it — a list Fernlet keeps in storage on
your phone that only Fernlet and its extensions can read, and which never contains your journal,
cycle or intimate data, health readings, photos, friends, or location. When you pick one and send
the message, the card carries that item to everyone in the conversation
through Apple's Messages service, under Apple's privacy terms and not through any server of ours:
for a recipe, its name, servings, ingredients with their amounts and macros, steps, and any notes
you wrote on it; for a workout, its name, planned day, exercises, and notes. Anyone in the
conversation, and anyone they forward it to, can read what the card carries; we never see it, and
Fernlet cannot take it back once sent. A card you receive is only a suggestion: nothing is saved
until you open it in Fernlet, review it, and confirm.

Optional coarse (approximate) location may be used only for gentle weather-based prompts and, if you
choose, to tag an in-person group activity. Location is never tracked over time and never attached to
your identity for us.

## 7. Artificial intelligence

Fernlet's AI features (for example, suggesting a workout, summarizing your day, or reflecting on a
journal entry) run **on your device** using Apple's on-device models. Your journal text, memories,
health data, photos, period data, and friend data are **not** sent to any external AI service. With
the AI helper on, Fernlet may summarize a journal entry in a few words for your Core memory — on your
device only, and never as a copy of your entry; with it off, Core memory keeps only the entry's mood.

Some optional convenience features may look up **non-personal reference data** from public sources —
for example, fetching the nutrition facts for a packaged product or a recipe you're importing. Those
lookups send only the minimal query needed (such as a product name, a recipe URL, or a product's
barcode number) and never attach your identity, health data, or any sensitive information.

**Looking up a barcode (off by default).** When a barcode you scan isn't one Fernlet recognizes, you
can tap to look it up on **Open Food Facts**, a free, open food database run by a non-profit — one
tap per lookup, never automatically. The first time, Fernlet asks for your permission. It is the same
**Web nutrition lookup** permission that lets a typed product search go to DuckDuckGo (in Settings →
AI & data sources; it works only while the on-device AI helper is on), so allowing one allows both,
and turning Web nutrition lookup off stops both. Only the barcode's number is sent, along with the
app's name and version; like any website, Open Food Facts also sees your device's IP address, under
its own privacy policy. What it finds is shown to you before anything is saved, and a product you
keep is stored as one of your own foods — on your device, and in your iCloud sync if you use it —
marked "Data from Open Food Facts (ODbL)", because Open Food Facts publishes its data under the Open
Database License. Each lookup is noted only on your device, in the AI activity log.

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
report is not anonymous to them. It never reaches us or any server.

If several friends report items you shared, your own shop pauses for 30 days, and the app shows
how long is left. A record of the pause stays on this device — even after **Delete Everything**,
and even if you reinstall Fernlet — until the pause ends. It keeps only coded references to the
reports behind it, never the reporters' names or keys.

The full content rules are shown in the app, and use of the app is governed by Apple's standard
Licensed Application End User License Agreement.

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

Fernlet is not directed to children under 13. Intimate-tracking features are available only to
users who indicate they are 16 or older, and stay hidden and unavailable to everyone else. For those
users they are on by default — nothing is recorded unless you log it — and right after the age check,
onboarding offers to turn them off; Settings → Period & sensitive content can hide them at any time.
Hiding never deletes anything you have logged.

## 12. Data retention

Data is retained on your device until you delete it or delete the app. iCloud copies are retained in
your iCloud account until you delete them in the app or in your Apple ID storage settings. We hold no
copy we can read.

A recipe or workout you send in Messages stays in that conversation — on your phone, on the
recipients' phones, and wherever it is forwarded — under Apple's retention, not ours; Fernlet cannot
delete it. The copy Fernlet keeps while a card you received waits for your review is deleted after
seven days, or by **Delete Everything**, which also empties the list the iMessage app shows.

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
