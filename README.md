<div align="center">

# Fernlet

**A tamagotchi of yourself.**

An iOS self-care companion where a small creature reflects how you have been treating
yourself — not how optimized you have been. No streaks. No calorie targets. No leaderboards.
No servers anyone operates.

[fernlet.com](https://fernlet.com) · [Privacy policy](Docs/Privacy-Policy.md) ·
[Verifiability](Docs/Verifiability.md) · [Specification](Docs/FernletSpecificationV3.md)

</div>

---

## What it is

Feed it when you eat, rest it when you sleep, take it outside when you move. The companion reads a
rolling 24-hour window of food, movement, sleep, cycle, journaling and hygiene signals and simply
*looks* how the day has gone — thriving, okay, tired. That is the whole feedback loop. Absence is
met with silence, never a nudge, and every unlock you earn is cumulative and can never be taken
back.

The social half works **only in person**: two phones held ~15 cm apart for about 0.8 s is the entire
friend handshake. Hearts, recipes and hand-drawn clothing travel device-to-device over a signed,
sealed peer-to-peer mesh. There is no friend server, no follow button and no discovery feed.

**Status:** in active development, pre-App-Store.

**Free and open source, permanently.** Fernlet has no purchase price, no subscription, no in-app
purchases and no ads, and its full source — including every line of the cryptography — is published
here under Apache-2.0. These are commitments rather than launch pricing: they are load-bearing for
the app's US export-control position, where being a free, publicly available app is what keeps the
shipped binary outside the EAR. See [Docs/Export-Compliance-Encryption.md](Docs/Export-Compliance-Encryption.md) §6A.

**Requires:** iOS 26 or later. iPhone 15 Pro or newer for the full on-device AI features; the 15 cm
handshake needs a phone with precise ranging (U1/UWB), with an on-screen confirm as the fallback.

## Privacy is the architecture, not a policy paragraph

Two independent, mechanically-enforced walls hold the privacy claims up. Both fail CI rather than
ship.

**The S3 wall — sealed data is structurally unreachable.** Period/cycle data, journal text,
sensitive memories, Worry Box notes and intimate-activity notes live in encrypted `Private*` stores.
The walled on-device-AI (`AIProviders`) and iCloud-sync (`CloudKitSync`) modules cannot import them:
a forbidden cross-wall `import` is a **compile error**, not a code-review note. Enforced by
[`Scripts/spm-wall-check.sh`](Scripts/spm-wall-check.sh) (building with
`DIAGNOSE_MISSING_TARGET_DEPENDENCIES=YES_ERROR`), proven by
[`Scripts/spm-wall-selftest.sh`](Scripts/spm-wall-selftest.sh), backstopped by the
`Tests/FernletTests/S3BoundaryTests` grep-wall, and run in CI by
[`.github/workflows/s3-wall.yml`](.github/workflows/s3-wall.yml).

**The no-tracking wall — an exact allowlist of outbound destinations.** No advertising, attribution
or analytics SDK anywhere, and every network destination is enumerated in
[`Docs/No-Tracking-Wall.md`](Docs/No-Tracking-Wall.md). Adding an endpoint or an SPM dependency
fails `Tests/FernletTests/NoTrackingBoundaryTests` until it is deliberately allowlisted **and** documented
in the same commit. All outbound fetching goes through `WebScrapingKit`'s `EphemeralWebSession` — a
private-tab `URLSession` with no cookie jar, cache, or credential store; `URLSession.shared` is
banned outright in shipping code.

On top of that: the sealed store's key is bound to the Secure Enclave (so sealed data cannot be
lifted out of a device backup), the app lock supports a duress PIN with decoy / silent-wipe /
recovery-lock responses, and local data files are excluded from device backups by default.

Don't take any of it on faith — [`Docs/Verifiability.md`](Docs/Verifiability.md) names the exact
command, test or file behind every guarantee, and there is a standing invitation to point a proxy
at the app and check that the published egress list is the whole list.

## Repository layout

| Path | What lives there |
| --- | --- |
| [`App/Fernlet/`](App/Fernlet) | The app target — composition root, `FernletStore`, and the tab surfaces. |
| [`FernletKit/`](FernletKit) | Local SPM package: 24 modules (domain, persistence, crypto, the sealed `Private*` stores, the walled `AIProviders` + `CloudKitSync`, `ProximityKit`, UI kits, services). |
| [`App/FernletWidgets/`](App/FernletWidgets), [`App/FernletShareExtension/`](App/FernletShareExtension) | Widget and recipe-share extension targets. |
| [`Tests/FernletTests/`](Tests/FernletTests), [`Tests/FernletUITests/`](Tests/FernletUITests) | Unit tests (including the grep-walls) and UI tests. |
| [`Site/`](Site) | The whole public web presence — static files only. See [`Site/README.md`](Site/README.md). |
| [`Docs/`](Docs) | Spec, privacy policy, the wall documents, and the file/function indexes. |
| [`Scripts/`](Scripts) | Wall checks, git hooks, doc-coverage scan, release checksum. |

Start with [`Docs/FernletSpecificationV3.md`](Docs/FernletSpecificationV3.md) for the product and
architecture in one document and [`Docs/FileIndex.md`](Docs/FileIndex.md) for a map of every source
file, then the DocC landing page for
whichever module you are touching (`FernletKit/Sources/<Module>/Documentation.docc/<Module>.md`) —
every type in the codebase carries a `///` doc comment, and
[`Scripts/doc-coverage-scan.py`](Scripts/doc-coverage-scan.py) keeps it that way.

## Build and test

```bash
xcodebuild build-for-testing -project App/Fernlet.xcodeproj -scheme Fernlet -destination 'platform=iOS Simulator,name=iPhone 17'
```

```bash
xcodebuild test-without-building -project App/Fernlet.xcodeproj -scheme Fernlet -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:FernletTests
```

The full suite takes several minutes; run it in batches by suite when iterating. Before pushing,
install the git hooks once so the wall check runs on wall-relevant pushes:

```bash
Scripts/install-git-hooks.sh
```

## The website

[`Site/`](Site) is the entire public web presence — landing page, privacy policy, support page —
as static HTML/CSS/JS with no build step, no cookies, no analytics and no external requests. It
deploys to GitHub Pages from `main` via [`.github/workflows/pages.yml`](.github/workflows/pages.yml)
(Settings → Pages → Source: **GitHub Actions**); [`Site/README.md`](Site/README.md) covers the
one-time setup, the custom-domain step, and the Cloudflare Pages alternative that can also serve
the security headers GitHub Pages cannot.

`Site/privacy/index.html` is a generated copy of [`Docs/Privacy-Policy.md`](Docs/Privacy-Policy.md).
That document is the source of truth, and the same text is pinned in three places — the document,
the in-app view (`App/Fernlet/PrivacyPolicyView.swift`), and the hosted page. They are held in sync by
`Tests/FernletTests/PrivacyPolicyParityTests` and re-checked in the Pages workflow before every deploy.

## Found a privacy hole?

That is the most valuable bug report this project can receive — traffic that is not in the published
egress inventory, a cross-wall data path, anything that contradicts the policy. Email
**fernletapp@gmail.com** with "privacy" in the subject.

## License

[Apache License 2.0](LICENSE) — see [`NOTICE`](NOTICE). Fernlet is a wellness and self-care
companion, not a medical device; it does not provide medical advice, diagnosis, or treatment.
