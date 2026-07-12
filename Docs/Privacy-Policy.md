# Fernlet Privacy Policy

> **DRAFT — requires legal review before publication.** Replace every `{{PLACEHOLDER}}`
> with the real value, have counsel review, then (1) host this text at a public URL and enter
> that URL in App Store Connect, and (2) embed the same text in the in-app Privacy Policy screen
> (Settings → Privacy Policy). Keep the hosted copy and the in-app copy in sync.

**Effective date:** July 11, 2026
**Developer:** Michael Bowman Olay
**Contact:** _TODO: add a support/contact email before submission._

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

Sensitive categories — **period/cycle data, sensitive memories, journal text, and any intimate-activity
notes** — are stored in an **encrypted, sealed store** on your device. These sealed categories are
walled off inside the app so that on-device AI and any networking code cannot read the raw data.

## 3. HealthKit (Apple Health)

With your permission, Fernlet **reads** the following from Apple Health to reflect your day: heart
rate, active energy, sleep analysis, step count, and workouts. Fernlet **writes** only the workouts
you log (so they count toward your Apple activity rings). Fernlet **never** writes period, mood,
journal, hydration, or hygiene data to Apple Health.

Health data accessed through HealthKit is used only on your device to compute your companion's state
and your derived trends. It is **never** used for advertising, never sold, and never shared with us
or any third party. Deleting Fernlet does not delete samples Fernlet wrote to Apple Health — remove
those in the Health app if you wish.

## 4. iCloud sync and encrypted backup (optional, you choose)

During setup you choose whether to keep your data **only on this device** or **sync it to iCloud**.

- **iCloud sync (optional):** If enabled, your core app data (meals, workouts, journal entries,
  hydration, hygiene, sleep, scores, settings, derived signals, and core memories) is synced to
  **your own iCloud private database** using Apple's CloudKit. This is associated with your Apple ID
  under Apple's standard privacy model. We cannot see it. You can turn this off or delete the cloud
  copy at any time in Settings → Privacy & Data. Deleting the cloud copy never deletes your local
  copy or your Apple Health history.
- **Encrypted sealed backup (separate, off by default):** You may separately opt in to back up
  **sensitive memories** and/or **period data**. Before this data leaves your device it is encrypted
  with a key derived from your device identity key (AES-256-GCM). Apple stores only unreadable
  ciphertext. Because the key lives in your iCloud Keychain, **if you permanently lose access to your
  iCloud Keychain on all your devices, this encrypted data cannot be recovered.** You are told this
  when you enable it. Period-data backup is a deliberate, clearly-warned opt-in because of the
  sensitivity of that information.

## 5. Photos

Photos in your Fernlet album are stored **encrypted in the app's private storage** and are **never**
uploaded to CloudKit or sent to any AI or server. They are included in your standard iCloud **device
backup** through the app container (the same way other app files are), unless you exclude Fernlet
from device backup. You may explicitly export an individual photo to your system Photos library with
a "Save to Photos" action — that is a one-time export you initiate, not automatic sync. Fernlet does
**no face recognition** and no automated photo analysis of your private album.

## 6. Identity keys and friend features (in-person only)

To support optional in-person friend features, Fernlet generates a cryptographic identity for your
device on first launch. The keys are stored in your Keychain (and your iCloud Keychain, so they can
follow you to a new device). Your **public key** is the only persistent identifier shared with
friends; your private keys never leave your device.

The friend features work **only when two people are physically near each other**, over a short-range,
encrypted, peer-to-peer connection — there is no friend server and no remote friend activity. When
you add a friend in person, your devices exchange your display names, public keys, avatar
appearances, and a **fuzzy** wellbeing vibe (e.g. "thriving," "okay," "struggling"). Friends **never**
see your numeric score, your goals, your cycle information, or any raw health data. You can send
"hearts," share recipes, and share custom companion clothing with nearby friends. All of this stays
device-to-device.

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

## 8. What we do NOT do

- We do **not** sell, rent, or trade your personal data.
- We do **not** use third-party advertising, ad networks, or cross-app/cross-site tracking.
- We do **not** embed third-party analytics SDKs that profile you.
- We do **not** perform face recognition or biometric identification of people in your photos.
- We do **not** operate a server that collects your health or journal data.
- We do **not** require an account or a login to use the app.

## 9. User-generated content and safety

If you create custom companion clothing and share it with friends in person, that content is
governed by our in-app rules against objectionable content. You can **report** and **block** content
and the people who share it; reporting hides the content on your device and blocks that person, and
Fernlet keeps an on-device record used to limit abusive sharing. Because sharing is peer-to-peer,
moderation actions take effect on-device. See the in-app terms/EULA (to be published before release) for the full
content rules.

## 10. Your controls and rights

In Settings you can:

- Choose local-only storage or iCloud sync, and change it any time.
- Turn encrypted sealed backup on or off per category.
- **Export your data** as a file you can save or share (this export excludes the encrypted sealed
  categories described in Section 2 to protect them).
- Delete your iCloud copy.
- Delete your data.
- Manage or wipe the memories Fernlet keeps.

Depending on where you live, you may have additional rights (such as access, correction, deletion,
or portability). Because we do not hold your data on our own servers, you exercise these rights
directly in the app; contact us using the contact details published on the App Store listing (a dedicated support email will be added before release) with any questions.

## 11. Children

Fernlet is not directed to children under 13. Intimate-tracking features are gated to users
who indicate they are 18 or older and are hidden and off by default.

## 12. Data retention

Data is retained on your device until you delete it or delete the app. iCloud copies are retained in
your iCloud account until you delete them in the app or in your Apple ID storage settings. We hold no
copy to retain or delete.

## 13. Changes to this policy

If we make material changes, we will update the effective date above and surface the change in the
app. Continued use after an update means you accept the revised policy.

## 14. Contact

Questions about this policy or your privacy: _support contact to be added before release._
Michael Bowman Olay

---

*Fernlet is a wellness and self-care companion, not a medical device. It does not provide medical
advice, diagnosis, or treatment. If you are in crisis, contact your local emergency services or, in
the US, call or text 988 (the Suicide & Crisis Lifeline).*
