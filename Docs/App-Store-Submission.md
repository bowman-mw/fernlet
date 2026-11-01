# App Store submission — what goes in each App Store Connect field

Everything App Store Connect asks for to submit Fernlet 1.0, in the order the pages show it, with the
answer to paste or pick. Field limits are App Store Connect's. Facts were checked against main
`7bb2174f` (2026-11-01). The TestFlight side (Beta App Review and Test Information) lives in
[App-Review-Demo-Mode.md](App-Review-Demo-Mode.md), and the App Privacy answers in
[App-Privacy-Nutrition-Labels.md](App-Privacy-Nutrition-Labels.md).

**Never use "tamagotchi" in the listing.** Tamagotchi is Bandai's trademark, and App Review rejects
metadata that uses another company's trademark (Guidelines 2.3.7 and 5.2.1). The website can keep its
phrase; the store copy says "companion" instead.

## 1. App Information (App Store tab → General → App Information)

| Field | Answer |
| --- | --- |
| Name (30) | `Fernlet` |
| Subtitle (30) | `Gentle self-care companion` (26). Alternative: `Self-care without the streaks` (29). |
| Bundle ID | `MBO.Fernlet` (picked when the app record was made) |
| SKU | Your own label, set once at creation and never shown to anyone, e.g. `FERNLET-IOS` |
| Primary language | English (U.S.) |
| Category | Primary **Health & Fitness** (matches `LSApplicationCategoryType` `public.app-category.healthcare-fitness`), secondary **Lifestyle** |
| Content rights | **Yes**, the app contains third-party content, and **yes**, you have the rights: every source is public domain or under an open license that Fernlet credits in Settings → Privacy & data → Acknowledgments (Open Food Facts under ODbL, USDA FoodData Central, Natural Earth, the Köppen-Geiger climate maps under CC BY 4.0, OurAirports, Wikidata, US Census TIGER/Line, USGS, Copernicus/EOX imagery, Apple Weather, and the four fonts under the SIL OFL). |
| License agreement | Leave it as **Apple's Standard License Agreement**. The privacy policy (§9) says the app is governed by it. The repo's Apache 2.0 `LICENSE` covers the source code, not the installed app. |
| App encryption documentation | Nothing to upload. The build sets `ITSAppUsesNonExemptEncryption = NO`, so App Store Connect doesn't ask (see [App-Privacy-Nutrition-Labels.md](App-Privacy-Nutrition-Labels.md) § Encryption). |
| Digital Services Act | App Store Connect asks once, under Business, whether you are a trader before the app can go on EU storefronts. A trader's address, phone and email are shown on the EU listing. |

### Age rating (App Information → Age Rating → Edit)

Apple's questionnaire works out the rating from these answers. With these answers it should come out
at **13+**, which matches the youngest in-app gate (nearby chat, held at 13 by Apple's own age check).

| Question | Answer | Why |
| --- | --- | --- |
| Parental controls | No | The app has none of its own. |
| Age assurance | **Yes** | Nearby chat and intimate tracking ask Apple's Declared Age Range (`AgeAssuranceRequest`). |
| Unrestricted web access | No | Recipe import reads a page but never shows a browser. |
| User-generated content | **Yes** | Friends share clothing designs and photos in person. Report and block are built in (policy §9). |
| Messaging and chat | **Yes** | Nearby chat between friends, 13+ through Apple's age check only. |
| Advertising | No | |
| Profanity or crude humor | None | |
| Horror or fear themes | None | |
| Alcohol, tobacco or drug use or references | None | Food logging can include a drink, but nothing is about drinking. |
| Medical or treatment information | Infrequent | First aid tips, injury ease-back, cycle predictions. |
| Health or wellness topics | **Yes** | It's a self-care app. |
| Mature or suggestive themes | Infrequent | Intimate-activity logging, hidden unless the person is 16 or older. |
| Sexual content or nudity | None | Logging is a form, never an image or a description. |
| Graphic sexual content and nudity | None | |
| Cartoon, realistic, prolonged or graphic violence | None | |
| Guns or other weapons | None | |
| Gambling, simulated gambling | None | |
| Contests | None | |
| Loot boxes | None | Shops sell set items for coins; nothing is random. |

If App Store Connect lands on a different rating, keep it. The in-app gates (13 for chat, 16 for
intimate tracking) hold whatever the store rating says.

## 2. Pricing and Availability

- **Price:** Free. No in-app purchases.
- **Availability:** every country **except France**. France may need an ANSSI declaration first
  ([App-Privacy-Nutrition-Labels.md](App-Privacy-Nutrition-Labels.md) § Encryption).
- **Export self-classification:** sign revision 2 of the
  [self-classification memo](Export-Self-Classification-Memo.md) before the app goes on sale outside
  the US and Canada ([Export-Compliance-Encryption.md](Export-Compliance-Encryption.md) §6A.4).

## 3. App Privacy (App Store tab → Trust & Safety → App Privacy)

- **Privacy policy URL:** `https://fernlet.com/privacy/`
- **Privacy choices URL:** leave empty.
- **The questionnaire:** answer from the per-type table in
  [App-Privacy-Nutrition-Labels.md](App-Privacy-Nutrition-Labels.md). In short:
  - **Tracking:** none. No data is used to track you.
  - **Collected only through the person's own iCloud, when they turn sync on:** Health & Fitness,
    core memories (User Content) and the friends list (Contacts). Each is Linked to You and used for
    App Functionality only.
  - **Ciphertext only, and only if the person turns on the sealed backups:** journal, period and
    intimate logs, and own photos.
  - **Not collected:** HealthKit readings, location and the map (since the World build, encrypted on
    the iPhone and never synced; see policy §6 "Location and the map"), contact info, browsing,
    purchases and financial data.
  - **Two rows the doc marks for legal:** the sealed away-hearts in the public CloudKit database, and
    the DuckDuckGo and Open Food Facts lookups. Settle these before submitting.

## 4. The 1.0 version page (App Store tab → iOS App → 1.0)

### Promotional text (170, can change any time without review)

> A little pixel companion lives on a map of your world and feels how you're doing. Log meals, walks, sleep and rest. No streaks, no ads, no account.

### Description (4,000)

> Fernlet is a self-care companion that's gentle with you.
>
> Your companion lives on a pixel map of your real world and reflects how you're looking after yourself: food, movement, sleep, rest, your cycle and personal care. Six hearts show how your day is going. There are no streaks to break and no score to chase. A new day begins at midnight, and a quiet day is just a quiet day.
>
> YOUR MAP
> • Home is a live pixel map that uncovers as you walk, with terrain that follows the real climate
> • Earn stamps along the way, and fill your companion's passport with countries, airports, flights and famous landmarks
> • Remember places you love, log your bike rides, and dress your companion from a pixel wardrobe
>
> FOOD AND MOVEMENT
> • Log a meal in a few taps, or scan a barcode
> • Save recipes and cook them step by step, with timers on your Lock Screen
> • Guided workouts planned around your gym, your week and your own history, with animated how-tos
> • Works with Apple Health, if you'd like it to
>
> A PRIVATE SPACE
> • Your journal, your cycle and more sit behind a passcode, sealed on your iPhone
> • Cycle predictions and period-aware care, kept in Fernlet's own sealed store
>
> FRIENDS, IN PERSON
> • Friends begin in person: hold two iPhones together on Home to meet and start a hangout
> • Share photos, clothing you design and gold hearts, with no server in between
>
> YOUR DATA STAYS YOURS
> • No account, no ads, no analytics, no tracking
> • Your data stays on your iPhone, or in your own iCloud if you turn on sync
> • Fernlet's AI runs on your iPhone, with Apple Intelligence on supported models. Everything works without it.
> • The source code is open for anyone to read
>
> Widgets put your companion and its hearts on your Home Screen and Lock Screen.
>
> Fernlet is a self-care companion, not a medical device. Cycle predictions are estimates and are not a form of contraception. If you are in crisis, contact your local emergency services, or in the US call or text 988.

### Keywords (100, comma-separated, no spaces after commas)

`wellness,journal,food log,meal,workout,cycle,period,sleep,mood,virtual pet,pixel,walk,map,diary` (95)

The words in the name and subtitle ("Fernlet", "gentle", "self-care", "companion") are already
searchable, so they're left out here.

### URLs and the rest

| Field | Answer |
| --- | --- |
| Support URL | `https://fernlet.com/support/` |
| Marketing URL | `https://fernlet.com` |
| Version | `1.0` (the build's `MARKETING_VERSION`) |
| Copyright | `2026 Michael Bowman Olay` |
| Routing app coverage file | None (Fernlet isn't a routing app) |
| Version release | **Manually release this version**, so launch day is your pick |

### Screenshots

iPhone only (`TARGETED_DEVICE_FAMILY = 1`), so only the iPhone set is needed. Upload the **6.9-inch**
set (1320 × 2868 portrait, RGB, no transparency). App Store Connect scales it down for every smaller
iPhone. The six images are in `Marketing/App-Store/` (untracked, like the rest of `Marketing/`), in
upload order by file name:

| File | Caption |
| --- | --- |
| `01-home.png` | Your map: A little companion on a map of your world |
| `02-today.png` | How you're doing: Gentle care. No streaks, no score to chase. |
| `03-food.png` | Food: Log a meal in a few taps, or scan a barcode |
| `04-move.png` | Workouts: Planned around your gym and your week |
| `05-passport.png` | Your companion: Name it, dress it, fill its passport |
| `07-cycle.png` | Private: Your journal and cycle, behind a passcode |

`Marketing/render-app-store.py` draws them from the raw captures in `Marketing/App-Store/raw/`, taken on
an iPhone 17 Pro Max simulator from the Demo build's sample data only, with the status bar at 9:41. The
companion is called by its default name, Fernlet, in every screen; the listing never names it.

### App icon

Nothing to upload. App Store Connect takes the 1024 px icon from the build's asset catalog (the pixel
Sprout, drawn by `Scripts/render-pixel-icons.py`).

## 5. App Review Information (same version page)

- **Sign-in required:** unchecked. Fernlet has no accounts.
- **Contact:** your name, phone and email. App Review uses these only to reach you.
- **Attachment (optional, recommended):** a short screen recording of two iPhones meeting on Home and
  starting a hangout. The friends features need two devices and the reviewer usually has one, so a
  video saves a round of questions.

### Which build App Review gets

Owner's call (2026-10-29): only Demo builds carry "Look around with sample data", so the App Store
build (Release) has no demo button. Its review notes say how to see everything from a fresh install:

> Fernlet has no accounts, sign-in or server; all data stays on the device. A fresh install opens on an eight-step onboarding: any answers work, and the app then opens on Home, a map of your surroundings. The tabs along the bottom open Food, Move, Log, Album, Private and Settings, and most screens fill in as you log. The Private area (journal, cycle) is protected by a passcode you create yourself, which onboarding offers to set.
>
> Meeting friends in person needs two iPhones running Fernlet: with both on Home, holding them together (about 15 cm, for under a second) starts a hangout over Ultra Wideband and the local network, with no server. The attached video shows it. Nearby chat additionally requires the device's Apple Account to share an age range of 13 or older through Declared Age Range, by design.

If you would rather App Review see sample data, the alternative is submitting the Demo build. It
ships the "Look around with sample data" button to everyone, and the 2026-10-29 call would have to
change. The Demo build's notes are in [App-Review-Demo-Mode.md](App-Review-Demo-Mode.md).

## Before pressing Submit

- [ ] The two App Privacy rows marked for legal are settled.
- [ ] The export memo (rev 2) is signed, or availability is limited to the US and Canada.
- [ ] France is unticked under Availability.
- [ ] The friends video is attached.
- [ ] Spanish: App Store Connect lists a language for every localization compiled into the build. If
      the build carries Spanish, a Spanish listing can follow later, but English is the only listing
      needed to submit.
