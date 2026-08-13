# ``WebScrapingKit``

The zero-dependency substrate under Fernlet's two web importers: the shared HTML/JSON-LD scraping helpers, and the single private-browsing `URLSession` every outbound fetch in the app goes through.

## Overview

Fernlet fetches web pages in exactly two places — the product/nutrition importer in the app target
(`App/Fernlet/FoodProductWebImporter.swift`) and the recipe importer in the walled `AIProviders` module
(`FernletKit/Sources/AIProviders/RecipeWebImporter.swift`). Both scrape schema.org JSON-LD out of a
page, both flatten a page to plain text for on-device extraction, and both had grown their own copy
of the same regex, entity-decoding, and JSON-LD-walking helpers. WebScrapingKit is where that shared
half now lives, plus one thing neither had: a deliberately amnesiac ``EphemeralWebSession``.

**Why this is its own module, and why it has no dependencies.** The obvious home for shared string
helpers would be `FernletFoundation`, but `AIProviders` is a *walled* target on the S3 privacy wall —
its dependency list is the enforcement mechanism, and every edge added to it widens what walled AI
code can name. Adding `FernletFoundation` to reach two regex helpers would also hand `AIProviders`
`KeychainHelpers`, `StoragePreferences`, and everything else that lives there. So this module was
carved deliberately narrow instead: **Layer 0, zero in-package dependencies, pure Foundation.**
Nothing here can reach a `Private*` store because nothing here can reach anything at all. When
extending it, keep it that way — a new dependency edge on this target is a wall change, not a
refactor, because `AIProviders` inherits it transitively.

### The scraping half

``HTMLScraper`` holds the regex capture reads, HTML-entity decoding, and the "reduce a page to
model-ready plain text" pass. ``JSONLDScraper`` holds `<script type="application/ld+json">`
extraction, `@type` reading, and the recursive search that finds a `Product` or a `Recipe` buried in
an `@graph` or an `itemListElement`.

The merge was done by line-by-line comparison, and the places where the two importers genuinely
*differed* are surfaced as parameters or as two functions rather than flattened to whichever
behaviour happened to be shorter:

- ``HTMLScraper/htmlDecoded(_:decodingNumericEntities:)`` takes a **required** flag because the recipe
  importer decoded numeric character references (`&#8217;`, `&#x2019;`) and the product importer did
  not. Both behaviours are preserved exactly; there is no default, so a caller must state its policy.
- ``HTMLScraper/allLastCaptures(in:pattern:)`` and
  ``HTMLScraper/firstMatchLastCapture(in:pattern:)`` are two functions because the two importers'
  "first capture" helpers differed when a first match's capture group did not participate. For every
  pattern in use today they agree, but that is a property of today's patterns.
- ``HTMLScraper/cleanedBodyText(from:decodingNumericEntities:characterLimit:)`` returns `nil` on an
  empty page instead of throwing, because each importer threw its *own* error case with its own
  user-facing copy and retry semantics. Each caller maps `nil` to its own error.
- ``HTMLScraper/metaContent(named:in:)`` reads the `content` of a `<meta>` tag by its `property` or
  `name` — the OpenGraph/Twitter-card shape (`og:image`, `twitter:image`, `og:title`) both importers
  match with the identical pattern. The captured value is returned raw; entity decoding stays each
  caller's stated policy.
- ``JSONLDScraper/object(ofType:in:)`` carries one intentional behaviour change, in the safe
  direction: the recipe importer's version returned early out of the `@graph` branch and never
  reached `itemListElement`, while the product importer's fell through. The merged version falls
  through, so the recipe path can now find a recipe on pages where it previously found none — strictly
  more, never different.

Three helpers were deliberately **not** merged, because they are semantically different functions
that happen to share a name. `stringValue` accepts an `NSNumber` on the product side and only a
`String` on the recipe side. `nutritionDoubleValue` applies thousands/decimal-separator normalization
on the product side (`"1,234"` versus `"1,5"`) and native `Int`/`Double` unwrapping on the recipe
side. And `fetchHTML` differs in almost every policy dimension — scheme guard, `User-Agent`,
content-type check, and most importantly what happens at the size cap (the product importer *throws*,
the recipe importer *truncates*). Those stay with their owners.

### The private-browsing half

``EphemeralWebSession`` is the transport every fetch now uses. Before it, both importers called
`URLSession.shared`, which is backed by the process-wide `HTTPCookieStorage.shared`,
`URLCache.shared`, and `URLCredentialStorage.shared` — a shared, persistent jar. A site could set a
cookie during a recipe import and read it back weeks later during an unrelated product import, which
is textbook cross-request tracking. ``EphemeralWebSession/makeConfiguration()`` starts from
`URLSessionConfiguration.ephemeral` and then explicitly disables cookie acceptance, cookie storage,
cookie sending, the URL cache, cache reads, and the credential store. Several of those are redundant
under `.ephemeral`; they are set anyway, each with a comment saying why, so the guarantee stays legible
and cannot silently regress if a future edit swaps the base configuration.

What this module does **not** own is per-caller request policy. Timeouts, `Accept` and `User-Agent`
headers, redirect handling (the recipe importer attaches an SSRF-revalidating per-task delegate),
content-type checks, and body caps all stay in the importers, because they differ on purpose.

**Position relative to the walls.** On the S3 wall: Layer 0, no dependencies, imported by
`AIProviders` and by the app target through the `FernletKit` umbrella product. On the no-tracking
wall: `EphemeralWebSession.swift` is one of the three files permitted to hold an HTTP client, and
`Tests/FernletTests/NoTrackingBoundaryTests` asserts that no shipping file uses `URLSession.shared` or a
`.default` configuration, that any `URLSession(configuration:)` is the ephemeral one, and that both
importers route through this type. See `Docs/No-Tracking-Wall.md` §2a.

**Concurrency.** The target sets no `defaultIsolation(MainActor.self)`, so everything is nonisolated —
these are pure statics called from a MainActor-default app target and a MainActor-default
`AIProviders`, and from off-main parsing paths. ``EphemeralWebSession/shared`` is a plain `static let`
because `URLSession` is thread-safe and `Sendable`.

## Topics

### Private-browsing transport

- ``EphemeralWebSession``

### HTML scraping

- ``HTMLScraper``

### JSON-LD scraping

- ``JSONLDScraper``
