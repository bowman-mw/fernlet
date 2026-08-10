# The No-Tracking Wall

**Status:** Enforced. Mechanical enforcement lives in
[`FernletTests/NoTrackingBoundaryTests.swift`](../FernletTests/NoTrackingBoundaryTests.swift); this
document is the human half — what the guarantee actually says, what a machine checks, what only a
human can check, and what a contributor does when they legitimately need a new network destination.

**Sibling wall:** the [S3 privacy wall](SPM-Module-Carveup-Plan.md) answers *"which code may touch
sealed data?"* This one answers *"where may bytes go at all?"* They are independent: the S3 wall
would happily let a fully de-identified payload be POSTed to an analytics endpoint, and this wall
would happily let sealed data flow to a permitted destination. You need both.

---

## 1. The guarantee

**No user data is sent to the developer, or to any third party, for advertising, attribution,
analytics, crash telemetry, or any other form of tracking — in this version or any future one.**

Three concrete commitments follow from it:

1. **There is no developer-operated server.** Fernlet has no backend. `fernlet.com` hosts a static,
   JS-free marketing/privacy site ([`Site/`](../Site/README.md)) and nothing else — the app never
   contacts it. There is no account, no login, no device ID, no install ping, no crash reporter, no
   feature-flag fetch, no "anonymous usage statistics".
2. **The advertising ecosystem is not merely unused, it is not linked.** No `AdSupport`, no
   `AppTrackingTransparency`, no IDFA, no SKAdNetwork, no third-party SDK of any kind except one
   crypto library. The app has never shown an ATT prompt and structurally cannot.
3. **Everything the app sends leaves for a reason the user chose.** The complete outbound surface is
   enumerated in §4 and is either Apple-operated infrastructure the user opted into (iCloud sync,
   WeatherKit), a single search endpoint behind an explicit off-by-default toggle, a URL the *user*
   pasted, or a link-local peer in the same room.

The point of writing this down mechanically is not that the current code is clean — it is, and the
numbers in §7 prove it. The point is the **next** commit. A well-meaning contributor adding Firebase
Crashlytics to debug a crash report should not need a reviewer who happens to remember this policy.
They should get a red CI run that explains it.

---

## 2. What is enforced mechanically

All of it is in one test file, in the house style of
[`S3BoundaryTests`](../FernletTests/S3BoundaryTests.swift): inputs are **discovered** from the file
system (so new files are covered automatically), every scan carries a **hard floor** (so a moved root
fails loudly instead of passing over zero files), and every pure matcher has a **planted-violation
fixture** (so the matcher cannot rot into always-returning-nothing).

| Test | What it forbids | How it fails |
|---|---|---|
| `noAdvertisingOrTrackingSDKIsReferencedAnywhere` | 45 banned SDK/framework module names and 11 banned tracking symbols, in **every** Swift file of **every** target — app, all 24 package modules, both extensions, and both test targets. | `import FirebaseAnalytics`, `#if canImport(AppTrackingTransparency)`, `ASIdentifierManager.shared().advertisingIdentifier`, `identifierForVendor`. |
| `thirdPartyPackageDependenciesAreExactlyTheOneAllowedPackage` | Any package dependency other than CryptoSwift, in `FernletKit/Package.swift` **or** the pbxproj's `XCRemoteSwiftPackageReference` / `packageProductDependencies`. | Adding *any* new SPM dependency, named or not — the rule is an exact-set match, not a blocklist. |
| `hardcodedNetworkDestinationsAreExactlyTheAllowlist` | Any hardcoded host in shipping code outside the §3 allowlist — **and** any stale allowlist entry the code no longer uses. | `URL(string: "https://telemetry.fernlet.com/v1/events")`. |
| `onlyThePinnedWebImportersMayHoldAnHTTPClient` | A raw HTTP/socket client (`URLSession`, `URLRequest`, `NWConnection`, `WKWebView`, …) anywhere in shipping code except the two pinned web importers and the session factory they share. | A new `URLSession` in a "TelemetryUploader.swift" — *even if its hostname is assembled at runtime*, which is the gap the host allowlist alone cannot close. |
| `everyOutboundFetchUsesTheEphemeralPrivateTabSession` | `URLSession.shared`, `URLSessionConfiguration.default`, or `.background` **anywhere** in shipping code; a `URLSession(configuration:)` built outside the one reviewed factory or without `.ephemeral`; a factory that has quietly stopped setting one of its seven privacy knobs; an importer that no longer routes through it. See §2a. | Someone "just quickly" fetching something with `URLSession.shared`, which silently re-attaches the process-wide cookie jar. |
| `noPersistentWebViewExistsAndInAppBrowsersArePinned` | Any `WKWebView` / `WKWebViewConfiguration` / `WKProcessPool` / `WKHTTPCookieStore` in shipping code (there are none), and, forward-compatibly, any that appears without `WKWebsiteDataStore.nonPersistent()`. Plus an exact-set pin on which file may present an out-of-process browser. | Adding a `WKWebView` for an OAuth flow or a help page — its default data store is an on-disk cookie/localStorage jar shared app-wide. |
| `privacyManifestsDeclareNoTrackingOrAdvertising` | `NSPrivacyTracking: true`, a non-empty `NSPrivacyTrackingDomains`, or a collected data type flagged for tracking / third-party advertising / developer advertising / analytics, in any of the three `PrivacyInfo.xcprivacy` files. | Flipping the manifest to match a newly added SDK — which is what an SDK's own integration guide tells you to do. |
| `plistFamilyFilesDeclareNoTrackingPermissionOrForeignContainer` | `NSUserTrackingUsageDescription`, `SKAdNetworkItems`, or `NSAdvertisingAttributionReportEndpoint` in any Info.plist/entitlements, plus any iCloud container other than the user's own `iCloud.MBO.Fernlet`. | Adding the ATT usage string, or repointing sync at somebody else's CloudKit container. |

### Two design decisions worth knowing

**Banned SDK names are matched as `import` declarations only, never as free text.** Several SDK names
are ordinary English words a health app uses constantly — *Adjust* servings, a *Branch* of the graph,
a *Segment* of a workout, a *Singular* value. A substring rule would produce false CI hard-fails, and
a wall that cries wolf gets disabled, which is how walls die. `import Adjust` is unambiguous; the word
"adjust" is not. Unambiguous *symbols* (`ATTrackingManager`, `advertisingIdentifier`) are matched
everywhere, at identifier boundaries, so `advertisingIdentifierPolicyDoc` does not trip.

**Hardcoded destinations are distinguished from user-supplied ones by construction.** The host
extractor reads the literal run of hostname characters immediately after `://`. Swift interpolation
(`"https://\(trimmed)"`), concatenation (`"https://" + host`) and a plain variable
(`URL(string: pastedString)`) all yield an empty run and contribute nothing. That is not a loophole —
it is the rule that keeps the recipe and product web importers legitimate: **they fetch whatever URL
the user pasted or shared, by design.** A URL the user typed is the user's decision about their own
data; a URL the developer compiled in is the developer's. Only the second is this wall's business.

### 2a. The private-tab guarantee

> **The rule:** every web fetch Fernlet makes behaves like a private browsing tab. No cookies are
> accepted, stored, or sent. Nothing is cached. No credentials are retained. Two fetches cannot be
> linked to each other by anything the app carries between them.

**The problem this fixes.** Both web importers used to fetch through `URLSession.shared`. That is not
a neutral default — it is backed by `HTTPCookieStorage.shared`, `URLCache.shared`, and
`URLCredentialStorage.shared`: one jar for the whole process, persisted across launches. A recipe page
imported in March could set a cookie, and a product page on the same domain imported in June would
hand it straight back. Nothing in that code looked like tracking; the tracking was in the default.

**The fix.** One shared session, built once, in
[`FernletKit/Sources/WebScrapingKit/EphemeralWebSession.swift`](../FernletKit/Sources/WebScrapingKit/EphemeralWebSession.swift).
Both importers fetch through `EphemeralWebSession.shared` and nothing else builds a session:

| Setting | Value | Redundant under `.ephemeral`? |
|---|---|---|
| base configuration | `URLSessionConfiguration.ephemeral` | — nothing is written to disk at all |
| `httpCookieAcceptPolicy` | `.never` | **No.** Ephemeral inherits `.onlyFromMainDocumentDomain` and would accept first-party cookies into RAM. |
| `httpCookieStorage` | `nil` | **No.** Ephemeral supplies an in-memory jar; `nil` means there is no jar to write to at all. |
| `httpShouldSetCookies` | `false` | Yes — set anyway. It governs the *send* direction where the two above govern *store*; two independent locks. |
| `urlCache` | `nil` | **No.** Ephemeral supplies an in-memory cache, and a replayed `ETag` / `Last-Modified` validator is a well-known cookie substitute. |
| `requestCachePolicy` | `.reloadIgnoringLocalAndRemoteCacheData` | Yes — set anyway, so re-adding a cache later cannot quietly reintroduce validator tracking without also changing this line. |
| `urlCredentialStorage` | `nil` | **No.** Ephemeral keeps an in-memory credential store; `nil` means an auth challenge answered once can never be silently replayed. |

The redundant rows are set **on purpose**. A privacy guarantee that depends on the reader knowing what
`.ephemeral` implies is one edit away from silently regressing — swap the base configuration and
nothing else in the diff looks different. Written out, the guarantee is legible without that knowledge,
and `everyOutboundFetchUsesTheEphemeralPrivateTabSession` fails if any row is deleted.

**What the shared session deliberately does *not* touch.** Timeouts, `Accept` / `User-Agent` headers,
redirect handling, content-type checks, and body caps stay with each importer, because they differ on
purpose. The product importer spoofs a Safari User-Agent (retailer bot-walls serve nothing otherwise),
checks the raw `Content-Type` header, and **throws** on an oversized body. The recipe importer
identifies itself honestly as `Fernlet/1.0`, checks `httpResponse.mimeType`, **truncates** at the cap,
and attaches a per-task `RedirectValidator` delegate that re-runs its SSRF guard on every redirect hop.
That delegate is a *task* delegate, so it works identically on the custom session — the SSRF guards
were not touched by this change.

**Web views.** There is **no** `WKWebView`, `WKWebViewConfiguration`, or `WKProcessPool` anywhere in
the app — verified by scan, not memory. That matters because a web view carries a second, completely
separate storage jar (`WKWebsiteDataStore.default()` — cookies, localStorage, and IndexedDB on disk,
shared by every web view in the process), so making the URL sessions ephemeral while leaving a web view
on the default store would move the tracking channel rather than close it. The rule is therefore
written *now*, while the answer is "there are none": the first `WKWebView` to appear must use
`WKWebsiteDataStore.nonPersistent()` and must edit this document.

**`SFSafariViewController` is the one exception, and it is honest about being one.** `Fernlet/FoodView.swift`
presents one — the "view the source page" affordance on the product-import review sheet, opening the
page the user is already looking at. It is **not** a surface this app can make ephemeral: it runs out
of process against Safari's own storage, which the app can neither read nor write nor configure (there
is no private-mode API). What the wall does instead is pin *where* it may be presented, as an exact
set, so a second in-app browser is a deliberate decision. In practice this is the user's own browser
opened on a page they chose, with Safari's own protections (ITP) applying — but it is not covered by
the private-tab guarantee above, and this document does not pretend otherwise.

---

## 3. The permitted-destination allowlist

Five hosts. Each has to earn its row, and the test fails in **both** directions — an unlisted host is
a breach, and a listed host the code no longer uses is a stale claim that must be pruned.

| Host | Why it exists |
|---|---|
| `html.duckduckgo.com` | **The only host the app itself chooses to contact.** DuckDuckGo's no-JS HTML search endpoint, used by the packaged/branded food lookup. It receives the typed product query ("costco chicken melts nutrition facts") and nothing else: no account, no identifier, no cookies, no health data. Behind the **off-by-default** `webNutritionLookupEnabled` toggle (`SettingsModel.swift:66`), with the egress spelled out in the Settings copy. Call site: `Fernlet/FoodProductWebImporter.swift:65`. |
| `duckduckgo.com` | **Not fetched.** Used only as the relative-URL base that unwraps `uddg=` redirect links out of that search page's HTML, so the real product page is opened directly rather than through DuckDuckGo's redirector. `Fernlet/FoodProductWebImporter.swift:109`. |
| `example.com` | RFC 2606 reserved documentation domain. Appears as UI **placeholder text** in the product-import field (`Fernlet/FoodView.swift`) and as fixture URLs in the DEBUG-only LinkPresentation prototype. Never a live destination. |
| `www.apple.com` | Apple-operated. A DEBUG-only fixture in `Fernlet/LinkMetadataPrototypeView.swift` — the D11 test matrix needs one real page with rich Open Graph tags. |
| `fernlet-prototype.invalid` | RFC 2606 `.invalid` TLD, guaranteed never to resolve. The DEBUG-only "unfetchable domain" row of the same prototype. |

> The last three rows are scaffolding, not product. `LinkMetadataPrototypeView.swift` is marked for
> deletion once [D11](D11-LinkMetadata-Prototype.md) is decided; delete these rows in the same commit
> and the "stale allowlist entry" assertion will tell you if you forget.

**Conspicuously absent: `fernlet.com`.** The developer's own domain is not on this list because the
app never talks to it. If a row for a developer-operated host ever appears here, that is the moment to
ask what it carries.

---

## 4. What the app actually talks to — the full inventory

The allowlist covers hardcoded hosts. Three other categories of outbound traffic exist and cannot
appear as a literal host in source, so they are enumerated here instead. This is the complete list; it
was produced by grepping every URL literal and every networking API in the tree, not from memory.

### 4a. Apple-operated, reached through system frameworks

| Service | Where | What leaves the device |
|---|---|---|
| **CloudKit — private database** | `CloudKitSync/CloudKitDataService.swift:243`, container `iCloud.MBO.Fernlet` | The user's own encrypted snapshot, in the user's own iCloud account. Off unless the user enables sync. Apple operates the storage; the developer has no read access to a private database. |
| **CloudKit — public database** | `CloudKitSync/HeartDropCloudTransport.swift:54` | The heart dead-drop only: a rotating pseudonymous day tag plus a sealed (ChaChaPoly) payload. See §6 for the honest caveat about this one. |
| **WeatherKit** | `AppServices/WeatherKitService.swift:233` | A coarse location, to Apple, only when weather-aware prompts are enabled. |
| **APNs / App Store** | `aps-environment` entitlement; the platform | Standard OS-level traffic. No payload of ours. |

None of these can carry data *to the developer*, and none is a channel the developer chooses the
contents of — with the single documented exception in §6.

### 4b. User-supplied URLs, fetched at runtime

| Path | Where | Notes |
|---|---|---|
| Recipe web import | `AIProviders/RecipeWebImporter.swift` (`fetchHTML`) | Fetches the URL the user pasted or shared into the app. HTTPS-only, SSRF-guarded on the initial URL *and* every redirect hop (`isSafePublicHTTPSURL`), 3 MB and 15 s bounded. |
| Recipe image download | `AIProviders/RecipeWebImporter.swift` (`downloadImage`), called only from `Fernlet/FernletStore.swift` (`fetchRecipeWebImageIfNeeded`) | One GET for the recipe page's own main food picture (a host the *page* named — JSON-LD `image` / `og:image`), which becomes the recipe's default photo, sealed through the private media store. **Owner decision 2026-08-09, consciously reversing the 2026-07-16 "no external image fetch" tester decision.** Runs on USER-PRESENT paths only — the foreground paste-a-URL import, the first open of a recipe's detail, and the post-"Re-import from source" refresh — never the share-extension background queue drain. **One attempt per device, suppression syncs**: each device gets one automatic attempt (device-local `RecipeWebImageAttemptMemory` sidecar, re-armed only by the explicit re-import; cancellation by navigating away does not spend it), while deleting the photo — or the user already having their own — sets the synced `webImageSuppressed`, pinning the recipe photo-less on every device. Same guard rigor as the page fetch: SSRF-checked on the initial URL and every redirect hop (IP literals canonicalized, so decimal/hex/octal/IPv4-mapped spellings classify like their dotted form), an image MIME requirement (`image/*`, or a generic octet-stream declaration whose bytes must pass a magic-number image sniff — mislabeled image CDNs work, HTML error pages fail), 15 s timeout, 10 MB streaming cap that aborts oversize. Proximity recipe shares carry a downscaled copy of the picture *in the sealed payload*, so a receiving device performs **no** web fetch. |
| Product page import | `Fernlet/FoodProductWebImporter.swift` (`fetchHTML`, `fetchImage`) | Fetches the product page the user chose (or the page the allowlisted search returned), plus candidate nutrition-label images for OCR. `fetchImage` routes through `RecipeWebImporter.downloadImage` (2026-08-09), so images now get the full SSRF/redirect/MIME guard, 12 MB streaming cap. |
| Source-link connection pre-warm | `Fernlet/FoodView.swift` (`SourceLinkPrewarmModifier`) | `SFSafariViewController.prewarmConnections(to:)` on the recipe detail page and the saved-recipe notes sheet: the recipe's own https source host is now contacted **on detail-appear** — a DNS lookup + TLS handshake for the eventual Safari presentation, no HTTP request, no page load (**owner decision 2026-08-09**: pre-warm only, no snapshot, no `WKWebView`; `SFSafariViewController` stays the opening surface). The token is invalidated on disappear. Like the Safari presentation itself (§2a exception), this runs out of process and outside the private-tab session; it reveals only "a Fernlet user who saved this recipe opened its page" to a host the user already chose by importing from it. Repeat imports of an already-saved URL now skip the network entirely (normalized source-URL match), so this pre-warm is paired with strictly *less* re-fetching, not more. |

These are the feature working as designed. The wall deliberately does not police them, but it *does*
police where such a fetch may live (§2, `onlyThePinnedWebImportersMayHoldAnHTTPClient`) and how it
must be made (§2a — all three call sites go through the ephemeral private-tab session, so no state
carries from one user-supplied URL to the next).

### 4c. Local-only, never leaves the room

MultipeerConnectivity + NearbyInteraction (`ProximityKit/Transport/`, `ProximityKit/Ranging/`) over
the `_fernlet-*` Bonjour service types declared in `Fernlet/Info.plist`. Link-local peer-to-peer with
signed/sealed envelopes; no server is involved at any point.

---

## 5. If you legitimately need a new network destination

The wall is meant to be *passable* — deliberately, with a paper trail. It is not meant to be
unpleasant enough that someone routes around it.

1. **First, check whether you actually need one.** Most reasons to add an endpoint (crash reports,
   usage metrics, remote config, feature flags, A/B tests, error aggregation) are precisely what this
   wall exists to refuse. There is no version of "just anonymous analytics" that is in scope.
2. **Prefer a user-supplied URL over a hardcoded one.** If the user types, pastes, or configures the
   destination, it is their data going where they chose — and the host extractor already ignores it.
   The planned **BYOK AI providers** (`AIDestination.externalAnthropic`,
   `.externalOpenAICompatible`) are the model here: the user brings the endpoint and the key. When
   that path is implemented it will still trip `onlyThePinnedWebImportersMayHoldAnHTTPClient`, and it
   should — a new HTTP client is exactly the change that deserves a deliberate review.
3. **If it must be hardcoded**, in one commit:
   - add a `PermittedDestination` to `NoTrackingBoundaryTests.permittedDestinations`, with a `reason`
     that states *what data reaches it* and *which consent gate guards it*;
   - add a row to §3 of this document;
   - if it needs a new HTTP client, add the file to `pinnedWebImporterFiles` and say why here — and
     fetch through `EphemeralWebSession.shared`, never a session of your own (§2a);
   - put the egress behind an explicit, off-by-default user setting whose copy names the destination,
     the way `webNutritionLookupEnabled` does.
4. **A new SPM dependency** additionally needs a `allowedPackageURLs` entry. Adding *any* package
   fails the wall, not just a recognised tracker — the blocklist can only catch SDKs someone thought
   to name, so the dependency rule is an exact-set match instead.

If the PR touches the allowlist, the reviewer's job is the `reason` string, not the diff.

---

## 6. Honest limits — what this does **not** guarantee

A privacy claim that overstates itself is worse than none. Specifically:

- **This cannot stop a malicious fork.** Anyone can clone the repo, delete
  `NoTrackingBoundaryTests.swift`, and ship a build that phones home. The wall protects **this
  repository** against **accidental regression** — a well-meaning commit, a dependency added on
  autopilot, an SDK pulled in for one debugging session and never removed. It is a guardrail, not a
  cage. What it *does* give a fork's users is a diff: removing the wall is a visible, reviewable
  deletion in a public repo, not a silent addition.
- **This cannot stop a determined insider with commit access.** Anyone who can edit the test can edit
  the allowlist in the same commit. The mitigation is social, not mechanical: the wall is structured
  so that doing so requires *writing down what the new endpoint receives*, in two places, in the same
  change — which makes the intent legible in review and in `git log` forever.
- **The heart dead-drop uses the CloudKit *public* database**, and public-DB records carry a
  `creatorUserRecordID`. An observer with dashboard access — including the developer — can see that
  *some* iCloud user wrote N records on a given day. They cannot see who, to whom, or what: tags are
  pseudonymous, rotate daily, are uncorrelatable across days, and payloads are sealed. This is a
  documented, accepted residual (`HeartDropCloudTransport.swift`), not an oversight, and it is the one
  place where a developer-visible byte exists at all.
- **The scan is lexical, not semantic.** It reads source text; it does not run the app or inspect the
  linked binary. A sufficiently indirect construction — reflection, a hostname decoded from base64 at
  runtime, an endpoint fetched from a permitted destination — would not be caught by grep. The
  HTTP-client pin (§2) is the answer to the realistic version of this: however the URL is built, the
  *client* has to live somewhere, and there are exactly two places it may live.
- **Apple frameworks are trusted, not audited.** CloudKit, WeatherKit, and APNs make network calls we
  do not see. The wall asserts we use the user's own iCloud container and nothing else; it cannot
  audit Apple's own telemetry, which is governed by the user's system-level Apple settings.
- **The private tab (§2a) is not anonymity, and stops at the connection layer.** It removes the state
  *the app carries between requests*. It does not hide the device's IP address, and there is no public
  API to disable TLS session-ticket resumption or HTTP/2 connection coalescing — so a server can still
  correlate two fetches that reuse one live connection within the process lifetime, and can always
  correlate by IP. A user who needs network-layer unlinkability needs a VPN or Private Relay; this
  guarantee is about Fernlet not being the one doing the linking.
- **`SFSafariViewController` is outside the private-tab guarantee.** The one in-app browser
  presentation (`Fernlet/FoodView.swift`) runs out of process against Safari's own storage. The app
  cannot read it, cannot write it, and cannot make it ephemeral — there is no API. The wall pins
  *where* one may be presented, which is all it can do; the browsing itself is governed by the user's
  Safari settings, not by ours.
- **It says nothing about on-device data handling.** That is the S3 wall's job, plus
  [`PrivacyWipeCoverage.md`](PrivacyWipeCoverage.md) for deletion and the sealed-store design for
  encryption at rest.
- **Floors are heuristics.** The scan floors (§7) are set well below current counts so ordinary churn
  and the ongoing SPM carve-up do not trip them. They catch a *broken* scan, not a scan that has
  narrowed by 20%. Per-root non-empty assertions cover the realistic failure (one root renamed).

---

## 7. Running it, and the numbers it sees today

```
xcodebuild test-without-building -scheme Fernlet \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:FernletTests/NoTrackingBoundaryTests
```

It runs as part of `FernletTests`, needs no simulator state, and should be a **required status
check** alongside [`.github/workflows/s3-wall.yml`](../.github/workflows/s3-wall.yml) — the same
argument that makes the S3 grep-wall a gate applies here, and more so, because this wall has no
compiler half to fall back on.

Coverage at the time of writing (2026-08-09):

| Scan | Files seen | Floor | Result |
|---|---|---|---|
| All Swift, all targets | 536 | 400 | 0 banned SDKs, 0 banned symbols |
| Shipping Swift (app + package + extensions) | 345 | 250 | 5 hardcoded hosts, all allowlisted |
| Raw HTTP clients in shipping code | 3 | pinned by name | `FoodProductWebImporter.swift`, `RecipeWebImporter.swift`, `EphemeralWebSession.swift` |
| `URLSession.shared` / `.default` / `.background` in shipping code | 0 | banned outright | every fetch goes through `EphemeralWebSession.shared` |
| Files constructing a `URLSession` | 1 | exact set | `EphemeralWebSession.swift`, on `.ephemeral`, with all 7 privacy settings present |
| WebKit web views in shipping code | 0 | forward rule | none exist; the first one must use `WKWebsiteDataStore.nonPersistent()` |
| Out-of-process in-app browsers | 1 | exact set | `FoodView.swift` (`SFSafariViewController`) |
| Package manifests | 2 | must be non-empty | 1 dependency: CryptoSwift |
| `PrivacyInfo.xcprivacy` | 3 | pinned by path | tracking `false`, 0 tracking domains, 0 collected data types |
| Info.plist + entitlements + manifests | 9 | 6 | no ATT key, no ad network, 1 iCloud container (`iCloud.MBO.Fernlet`) |

> The two Swift file counts move with every commit (the SPM carve-up is ongoing and a concurrent
> branch was adding and removing app files while these were measured). They are reported for context;
> the *floors* are what the tests assert, and they sit far below on purpose — they catch a broken
> enumerator, not ordinary churn.

**Why there is no compiler half.** The S3 wall gets one for free: its forbidden edge is a *missing*
package dependency, which `DIAGNOSE_MISSING_TARGET_DEPENDENCIES=YES_ERROR` turns into a build error.
A tracking SDK arrives as a *new, honest* dependency — the DAG simply grows an edge and compiles
clean. There is nothing for the compiler to object to, so the grep wall is not a backstop here. It is
the whole enforcement, which is why it is deliberately broader than `S3BoundaryTests`: every target
including tests, three independent network checks rather than one, and both manifests plus every
plist.

---

## 8. Related

- [`FernletTests/NoTrackingBoundaryTests.swift`](../FernletTests/NoTrackingBoundaryTests.swift) — the enforcement.
- [`FernletKit/Sources/WebScrapingKit/EphemeralWebSession.swift`](../FernletKit/Sources/WebScrapingKit/EphemeralWebSession.swift) — the private-tab session itself, with the per-setting rationale (§2a).
- [`FernletTests/S3BoundaryTests.swift`](../FernletTests/S3BoundaryTests.swift) — the sibling wall, and the source of the matchers this one reuses so the two agree on what an `import` is.
- [`Docs/Privacy-Policy.md`](Privacy-Policy.md) — the user-facing statement this wall backs up.
- [`Docs/Verifiability.md`](Verifiability.md) — how anyone can verify this wall (and the rest of
  the privacy claims) themselves: the per-claim verification table, the standing traffic-audit
  invitation, the device-binding story, and the hardening items awaiting an owner decision.
- [`Docs/App-Privacy-Nutrition-Labels.md`](App-Privacy-Nutrition-Labels.md) — the App Store declarations that must stay consistent with the manifests.
- [`Docs/PrivacyWipeCoverage.md`](PrivacyWipeCoverage.md) — the same enforcement pattern applied to deletion.
- [`Site/_headers`](../Site/_headers) — the marketing site's matching stance: `default-src 'none'`, no JS, no cookies, no third-party requests.
