// NoTrackingBoundaryTests.swift
// FernletTests
//
// The "no-tracking wall" (Docs/No-Tracking-Wall.md), a sibling of the S3 privacy wall.
//
// THE RULE: no user data may ever be sent to the DEVELOPER — or to any third party — for
// advertising, attribution, analytics, crash telemetry, or any other tracking purpose. The S3 wall
// answers "which code may touch sealed data"; this wall answers "where may bytes go at all".
//
// The S3 wall has a compiler half (DIAGNOSE_MISSING_TARGET_DEPENDENCIES=YES_ERROR) and a grep half
// (S3BoundaryTests). This wall has NO compiler half available: a tracking SDK arrives as a NEW
// package dependency, so the dependency DAG would simply grow an honest edge and compile clean.
// Everything here is therefore the grep half — but it is the whole enforcement, so it is deliberately
// broader than S3BoundaryTests: it scans EVERY Swift file in every target, both package manifests,
// and every plist-family file, and it pins network reach in three independent ways (banned SDK,
// pinned HTTP-client files, exact destination allowlist) so no single check is load-bearing alone.
//
// Every scan DISCOVERS its inputs from the file system and carries a hard FLOOR, so a moved root or
// a broken enumerator fails loudly instead of passing vacuously over zero files (the S3BoundaryTests
// house rule). The pure matchers are exercised by planted-token fixtures below for the same reason.
//
// The matchers `S3BoundaryTests.importedModules(in:)` and
// `S3BoundaryTests.containsAtIdentifierBoundary(_:_:)` are REUSED rather than re-implemented: the two
// walls must agree on what an `import` is and on identifier-boundary matching, and a divergence
// between them would be a silent hole in one of the two.

import Foundation
import Testing

/// Grep-wall enforcing the no-tracking boundary: no advertising/attribution/analytics SDK anywhere in
/// the tree, no outbound network destination outside the reviewed allowlist, and privacy manifests
/// that keep declaring zero tracking.
///
/// Eight enforcement tests plus five pure-matcher fixtures:
/// - ``noAdvertisingOrTrackingSDKIsReferencedAnywhere()`` — banned frameworks/symbols in any Swift file.
/// - ``thirdPartyPackageDependenciesAreExactlyTheOneAllowedPackage()`` — the SPM/pbxproj dependency sets.
/// - ``hardcodedNetworkDestinationsAreExactlyTheAllowlist()`` — every hardcoded host in shipping code.
/// - ``onlyThePinnedWebImportersMayHoldAnHTTPClient()`` — where an HTTP client may exist at all.
/// - ``everyOutboundFetchUsesTheEphemeralPrivateTabSession()`` — HOW those clients fetch: no shared
///   cookie jar, cache, or credential store.
/// - ``noPersistentWebViewExistsAndInAppBrowsersArePinned()`` — the WebKit/Safari surface.
/// - ``privacyManifestsDeclareNoTrackingOrAdvertising()`` — the three `PrivacyInfo.xcprivacy` files.
/// - ``plistFamilyFilesDeclareNoTrackingPermissionOrForeignContainer()`` — Info.plist + entitlements.
///
/// Scope and honest limits are documented in Docs/No-Tracking-Wall.md; the short version is that this
/// stops accidental regression in THIS repo, not a determined fork.
struct NoTrackingBoundaryTests {

    // MARK: - Scan roots & floors

    /// Every root holding Swift source in this repo — app, package modules, both extensions, and BOTH
    /// test targets. Test code is included deliberately: an analytics SDK linked "only for tests" is
    /// still a dependency in the project file and still a thing a contributor can promote later.
    private static let allSwiftRoots = [
        "Fernlet",
        "FernletKit/Sources",
        "FernletWidgets",
        "FernletShareExtension",
        "FernletTests",
        "FernletUITests"
    ]

    /// The roots that actually SHIP. The destination allowlist is enforced only here, because test
    /// fixtures legitimately name throwaway hosts (`example.com`, `www.costco.com`, RFC 1918 literals
    /// used by the SSRF-guard tests) that must not be mistaken for real destinations.
    private static let shippingSwiftRoots = [
        "Fernlet",
        "FernletKit/Sources",
        "FernletWidgets",
        "FernletShareExtension"
    ]

    /// Floor for the all-target Swift scan (536 files at the time of writing). Set well below the real
    /// count so ordinary churn — including the ongoing SPM carve-up moving files BETWEEN these roots —
    /// never trips it, but a root that stops resolving does.
    private static let minimumSwiftFilesScanned = 400

    /// Floor for the shipping-only Swift scan (345 files at the time of writing).
    private static let minimumShippingFilesScanned = 250

    /// The three bundle roots that carry an Info.plist / entitlements / privacy manifest. A subset of
    /// ``shippingSwiftRoots`` (the package sources ship no bundle of their own).
    private static let bundleRoots = ["Fernlet", "FernletWidgets", "FernletShareExtension"]

    /// Floor for the plist-family scan (9 files at the time of writing: 3 Info.plist, 3 entitlements,
    /// 3 PrivacyInfo.xcprivacy).
    private static let minimumPlistFamilyFilesScanned = 6

    // MARK: - Banned SDKs & symbols

    /// Module names that may never be imported, in any target, by any file.
    ///
    /// Matched ONLY as an `import` declaration or a `canImport(...)` condition — never as free text.
    /// That distinction is load-bearing: several of these SDK names are ordinary English words that
    /// appear all over a health app's UI copy ("Adjust servings", "Branch", "Segment", "Singular"), so
    /// a plain substring rule would produce false CI hard-fails and get disabled — which is how walls
    /// die. `import Adjust` is unambiguous; the word "adjust" is not.
    ///
    /// Two Apple frameworks lead the list because they are the ONLY supported way to obtain the IDFA
    /// or ask for tracking permission on iOS: without them, App-Store-legal cross-app tracking is not
    /// merely forbidden here, it is not implementable.
    private static let bannedSDKModules = [
        // Apple's advertising/tracking frameworks — the IDFA and the ATT prompt.
        "AdSupport", "AppTrackingTransparency",
        // Google / Firebase.
        "Firebase", "FirebaseAnalytics", "FirebaseCore", "FirebaseCrashlytics", "FirebaseMessaging",
        "GoogleAnalytics", "GoogleMobileAds", "Crashlytics",
        // Product analytics.
        "Amplitude", "AmplitudeSwift", "Mixpanel", "Segment", "Analytics", "PostHog", "Flurry",
        "FlurryAnalytics", "Countly", "MatomoTracker", "TelemetryDeck", "TelemetryClient",
        // Attribution / install tracking.
        "AppsFlyerLib", "Adjust", "AdjustSdk", "Branch", "BranchSDK", "Kochava", "KochavaTracker",
        "Singular", "SingularSDK", "Umeng", "UMCommon",
        // Crash / APM telemetry.
        "Sentry", "Bugsnag", "Datadog", "DatadogCore", "DatadogRUM", "DatadogLogs",
        // Marketing automation / push-with-profiles.
        "OneSignal", "OneSignalFramework", "Appboy", "BrazeKit", "Iterable", "IterableSDK"
    ]

    /// Symbols that may never appear ANYWHERE — matched at identifier boundaries in any file of any
    /// kind (Swift, plist, entitlements, project file), including comments.
    ///
    /// Unlike the module names above these are unambiguous identifiers with exactly one meaning, so
    /// the stricter rule is safe. `identifierForVendor` is included even though it is not an
    /// advertising identifier: it is the standard substitute device ID once the IDFA is unavailable,
    /// and the app has no legitimate use for a stable device handle.
    private static let bannedTrackingSymbols = [
        "ASIdentifierManager",
        "advertisingIdentifier",
        "isAdvertisingTrackingEnabled",
        "ATTrackingManager",
        "requestTrackingAuthorization",
        "trackingAuthorizationStatus",
        "NSUserTrackingUsageDescription",
        "identifierForVendor",
        "SKAdNetwork",
        "SKAdNetworkItems",
        "NSAdvertisingAttributionReportEndpoint"
    ]

    // MARK: - Dependency allowlist

    /// The ONLY third-party package this project may depend on, in the local SPM manifest and in the
    /// Xcode project's remote-package references alike.
    ///
    /// CryptoSwift supplies the memory-hard Scrypt KDF behind `FernletLock`'s passphrase derivation —
    /// pure local computation, no network code. Any other package URL fails here, whether or not its
    /// name is on ``bannedSDKModules``: the banned list can only catch SDKs someone thought to name,
    /// while this exact-set rule catches the ones nobody has heard of yet.
    private static let allowedPackageURLs: Set<String> = [
        "https://github.com/krzyzanowskim/CryptoSwift"
    ]

    // MARK: - Destination allowlist

    /// One permitted outbound destination: a host that may appear as a hardcoded URL in shipping code,
    /// and the reviewed reason it is there.
    ///
    /// Pure data — the reason string is never matched against, it exists so that a contributor reading
    /// a failure sees WHY each neighbour on the list was allowed, and has to write the same kind of
    /// justification for a new one.
    struct PermittedDestination: Sendable {
        /// Lowercased host exactly as it appears after the `https://` in source.
        let host: String
        /// Why this destination is permitted, and under which consent gate it is reached.
        let reason: String
    }

    /// The complete set of hardcoded network destinations allowed in shipping code.
    ///
    /// Notably ABSENT and intentionally so: `fernlet.com`. The developer's own domain hosts the static
    /// marketing/privacy site (`Site/`) and, eventually, universal-link landing pages — it is never a
    /// destination the app POSTs to. If a row for a developer-operated host ever appears below, that
    /// is the moment to ask what it carries.
    ///
    /// Apple-operated services (CloudKit, WeatherKit, push, the App Store) reach the network through
    /// system frameworks with no host in our source, so they cannot appear in this list; the mesh
    /// (MultipeerConnectivity/NearbyInteraction) is link-local and never leaves the room. Both are
    /// covered in Docs/No-Tracking-Wall.md rather than here.
    private static let permittedDestinations: [PermittedDestination] = [
        PermittedDestination(
            host: "html.duckduckgo.com",
            reason: """
            The ONLY host the app itself chooses to contact. DuckDuckGo's no-JS HTML search endpoint, \
            behind the web-nutrition-lookup opt-in: it receives the typed product query and nothing \
            else — no account, no identifier, no health data (Fernlet/FoodProductWebImporter.swift).
            """
        ),
        PermittedDestination(
            host: "duckduckgo.com",
            reason: """
            Not fetched. Used only as the relative-URL base that unwraps `uddg=` redirect links out of \
            the search page's HTML so the real product page can be opened directly \
            (FoodProductWebSearch.resultURL).
            """
        ),
        PermittedDestination(
            host: "example.com",
            reason: """
            RFC 2606 reserved documentation domain. Appears as UI placeholder TEXT in the product-import \
            field (Fernlet/FoodView.swift) and as fixture URLs in the DEBUG-only LinkPresentation \
            prototype. Never a live destination.
            """
        ),
        PermittedDestination(
            host: "www.apple.com",
            reason: """
            Apple-operated. A DEBUG-only fixture in Fernlet/LinkMetadataPrototypeView.swift — the \
            matrix needs one real page with rich Open Graph tags. Delete this row with the prototype.
            """
        ),
        PermittedDestination(
            host: "fernlet-prototype.invalid",
            reason: """
            RFC 2606 `.invalid` TLD — guaranteed never to resolve. A DEBUG-only fixture in \
            Fernlet/LinkMetadataPrototypeView.swift testing the unfetchable-domain row. Delete this \
            row with the prototype.
            """
        )
    ]

    /// The two files in shipping code that may PERFORM an outbound fetch.
    ///
    /// This closes the gap the host allowlist cannot: a host assembled at runtime from string pieces
    /// (`"api." + "tracker.io"`) has no `https://` literal to find. Pinning WHERE an HTTP client may
    /// exist means such a call site has to live in one of these two reviewed files — both of which are
    /// user-initiated web importers whose destinations are either the allowlisted search endpoint or a
    /// URL the user supplied, and both of which are already SSRF-guarded and consent-gated.
    private static let pinnedWebImporterFiles: Set<String> = [
        "FoodProductWebImporter.swift",  // product-page lookup (opt-in web nutrition lookup)
        "RecipeWebImporter.swift"        // recipe import from a URL the user pasted/shared
    ]

    /// The one file that may CONSTRUCT a `URLSession` — `WebScrapingKit`'s private-browsing factory.
    ///
    /// Separated from ``pinnedWebImporterFiles`` because the two rules are different: the importers
    /// may *fetch* but must not build their own session, and this file builds the session but never
    /// fetches. Splitting them is what lets ``everyOutboundFetchUsesTheEphemeralPrivateTabSession()``
    /// say "exactly one file constructs a session, and it is the ephemeral one".
    private static let ephemeralSessionFactoryFile = "EphemeralWebSession.swift"

    /// Every file allowed to name a raw HTTP-client API: the two importers plus the session factory.
    private static let permittedHTTPClientFiles: Set<String> =
        pinnedWebImporterFiles.union([ephemeralSessionFactoryFile])

    /// Markers naming a raw HTTP/socket client API. Matched at identifier boundaries with comment
    /// lines stripped, so a file that merely DISCUSSES `URLSession` in prose is not pinned.
    private static let httpClientMarkers = [
        "URLSession", "URLRequest", "NSURLConnection", "NWConnection", "NWBrowser",
        "CFURLRequest", "WKWebView"
    ]

    // MARK: - Private-tab session policy

    /// Session/configuration APIs that carry PROCESS-WIDE, PERSISTENT state, and so may not appear in
    /// shipping code at all.
    ///
    /// `URLSession.shared` is backed by `HTTPCookieStorage.shared`, `URLCache.shared`, and
    /// `URLCredentialStorage.shared` — one jar for the whole process, persisted across launches. A
    /// site could set a cookie during a recipe import and read it back weeks later during an unrelated
    /// product import: cross-request tracking with no code that looks like tracking. The two web
    /// importers used exactly this until the private-tab change; the ban is what stops it coming back.
    ///
    /// `.default` is the same storage under a different name. `.background(withIdentifier:)` is
    /// necessarily persistent (the whole point is surviving app death) and has no place here.
    private static let forbiddenSessionConfigurations = [
        "URLSession.shared",
        "URLSessionConfiguration.default",
        "URLSessionConfiguration.background"
    ]

    /// Every privacy setting ``ephemeralSessionFactoryFile`` must still name in CODE (comment lines are
    /// stripped before matching, so documenting a setting is not the same as setting it).
    ///
    /// Some of these are redundant under `.ephemeral` — that is precisely why they are asserted.
    /// A privacy guarantee that relies on the reader knowing what `.ephemeral` implies is one line
    /// away from silently regressing when someone swaps the base configuration; each knob is set
    /// explicitly so the guarantee survives that edit, and this list is what makes deleting one a
    /// failing test rather than a diff nobody questions.
    private static let requiredEphemeralSessionSettings = [
        "URLSessionConfiguration.ephemeral",             // the base: nothing on disk
        "httpCookieAcceptPolicy",                        // .never — refuse Set-Cookie outright
        "httpCookieStorage",                             // nil — not even an in-memory jar
        "httpShouldSetCookies",                          // false — never attach a cookie outbound
        "urlCache",                                      // nil — no ETag/Last-Modified replay
        "requestCachePolicy",                            // reload-ignoring — belt to that brace
        "reloadIgnoringLocalAndRemoteCacheData",
        "urlCredentialStorage"                           // nil — no silent auth replay
    ]

    // MARK: - Web view / in-app browser surface

    /// WebKit markers. A `WKWebView` carries its own cookie/localStorage/IndexedDB jar which, by
    /// default, is `WKWebsiteDataStore.default()` — persistent on disk and shared between every web
    /// view in the app. There are none today; the rule below is written so that the first one to
    /// appear has to be non-persistent.
    private static let webViewMarkers = [
        "WKWebView", "WKWebViewConfiguration", "WKProcessPool", "WKHTTPCookieStore"
    ]

    /// The call that makes a web view's data store amnesiac — the WebKit equivalent of
    /// `URLSessionConfiguration.ephemeral`.
    private static let nonPersistentDataStoreMarker = "WKWebsiteDataStore.nonPersistent"

    /// Out-of-process in-app browsers. These are NOT WebKit views the app configures: `SFSafariViewController`
    /// runs in Safari's own process against Safari's own storage, which the app cannot read, cannot
    /// write, and — importantly — cannot make ephemeral (there is no public API for it). So the rule
    /// here is not "configure it privately", it is "there is exactly one of these and we know where".
    private static let inAppBrowserMarkers = ["SFSafariViewController", "ASWebAuthenticationSession"]

    /// The one shipping file that may present an out-of-process browser: the product-import review
    /// sheet's "view source page" affordance, which opens the page the user is already looking at.
    /// Pinned in BOTH directions — a second one is a review moment, and losing this one means the
    /// scan broke rather than the code got cleaner.
    private static let permittedInAppBrowserFiles: Set<String> = [
        "FoodView.swift"  // FoodProductReviewSheet -> SafariView(url: preview.sourceURL)
    ]

    /// The privacy manifests that must exist and must keep declaring zero tracking. Pinned by path: a
    /// manifest that is deleted or renamed is a HARD failure, not a silently smaller scan.
    private static let privacyManifestPaths = [
        "Fernlet/PrivacyInfo.xcprivacy",
        "FernletShareExtension/PrivacyInfo.xcprivacy",
        "FernletWidgets/PrivacyInfo.xcprivacy"
    ]

    /// Declared-purpose values that mean "this data feeds advertising or developer-side measurement".
    /// A collected data type carrying any of these contradicts the guarantee even when
    /// `NSPrivacyCollectedDataTypeTracking` is false, because tracking-as-Apple-defines-it (linking
    /// across apps/sites) is narrower than what this wall forbids.
    private static let bannedCollectedDataPurposes: Set<String> = [
        "NSPrivacyCollectedDataTypePurposeThirdPartyAdvertising",
        "NSPrivacyCollectedDataTypePurposeDeveloperAdvertising",
        "NSPrivacyCollectedDataTypePurposeAnalytics"
    ]

    /// The one iCloud container the app may use — the user's own private Apple container. A different
    /// identifier would mean sync had been repointed at somebody else's CloudKit container.
    private static let allowedICloudContainers: Set<String> = ["iCloud.MBO.Fernlet"]

    // MARK: - Enforcement

    /// No advertising, attribution, analytics, or crash-telemetry SDK is imported anywhere, and no
    /// tracking-identifier symbol is named anywhere.
    ///
    /// This is the check a well-meaning "let's add Firebase to see what's crashing" commit must fail.
    /// Scans EVERY Swift file in every target (including tests), skipping only this file — which names
    /// every banned token as data and would otherwise indict itself.
    @Test func noAdvertisingOrTrackingSDKIsReferencedAnywhere() throws {
        let repoRoot = Self.repoRoot()
        let selfName = URL(fileURLWithPath: #filePath).lastPathComponent

        var scanned = 0
        for root in Self.allSwiftRoots {
            var scannedInRoot = 0
            for url in Self.swiftFiles(under: root, repoRoot: repoRoot) {
                guard url.lastPathComponent != selfName else { continue }
                let source = try String(contentsOf: url, encoding: .utf8)
                scanned += 1
                scannedInRoot += 1

                let sdks = Self.bannedSDKs(in: source)
                #expect(
                    sdks.isEmpty,
                    "\(url.lastPathComponent) imports tracking/analytics SDK(s) \(sdks). Fernlet sends no user data to the developer or any third party — see Docs/No-Tracking-Wall.md."
                )

                let symbols = Self.bannedSymbols(in: source)
                #expect(
                    symbols.isEmpty,
                    "\(url.lastPathComponent) names tracking symbol(s) \(symbols). Advertising identifiers and the ATT prompt are forbidden — see Docs/No-Tracking-Wall.md."
                )
            }
            // Per-root floor: one broken root must not be masked by the other five still finding files.
            #expect(scannedInRoot > 0, "Scanned zero Swift files under '\(root)' — the root moved and the no-tracking scan is silently narrower.")
        }
        #expect(
            scanned >= Self.minimumSwiftFilesScanned,
            "Scanned only \(scanned) Swift files (floor \(Self.minimumSwiftFilesScanned)) — discovery is broken; the wall would pass vacuously."
        )
    }

    /// The project depends on exactly one third-party package, in both manifests.
    ///
    /// The banned-name list catches SDKs someone thought to enumerate; this catches the rest. Adding
    /// ANY package — to `FernletKit/Package.swift` or as an `XCRemoteSwiftPackageReference` in the
    /// pbxproj — fails until it is deliberately allowlisted here, which is the review moment.
    @Test func thirdPartyPackageDependenciesAreExactlyTheOneAllowedPackage() throws {
        let repoRoot = Self.repoRoot()
        for relativePath in ["FernletKit/Package.swift", "Fernlet.xcodeproj/project.pbxproj"] {
            let url = repoRoot.appendingPathComponent(relativePath)
            guard let manifest = try? String(contentsOf: url, encoding: .utf8) else {
                Issue.record("Could not read \(relativePath) — renamed or moved? The dependency allowlist is unenforced.")
                continue
            }

            let declared = Self.declaredPackageURLs(in: manifest)
            #expect(
                !declared.isEmpty,
                "Found zero package URLs in \(relativePath) — the parser or the file changed shape; the dependency allowlist is passing vacuously."
            )
            let unexpected = declared.subtracting(Self.allowedPackageURLs).sorted()
            #expect(
                unexpected.isEmpty,
                "\(relativePath) declares package dependencies \(unexpected) outside the allowlist. A new dependency needs a deliberate entry + a line in Docs/No-Tracking-Wall.md."
            )

            // Belt-and-braces: a banned SDK could also arrive as a product/target reference (e.g. a
            // `packageProductDependencies` entry) with no URL of its own.
            let named = Self.bannedSDKModules.filter { Self.namesSymbol(manifest, $0) }
            #expect(named.isEmpty, "\(relativePath) names tracking/analytics SDK product(s) \(named).")
            let symbols = Self.bannedSymbols(in: manifest)
            #expect(symbols.isEmpty, "\(relativePath) names tracking symbol(s) \(symbols).")
        }
    }

    /// The set of hardcoded network destinations in shipping code is EXACTLY the reviewed allowlist.
    ///
    /// Both directions are asserted for different reasons. An UNEXPECTED host is the wall breach: a new
    /// endpoint — most of all a developer-operated one — cannot land without someone writing it down
    /// and saying why. A STALE allowlist entry is hygiene: it means the wall is claiming to permit
    /// something the code no longer does, and the list must shrink so it keeps describing reality.
    ///
    /// User-supplied URLs are NOT destinations in this sense and do not appear here: the recipe and
    /// product importers fetch whatever URL the user pasted or shared, which is the feature working.
    /// ``hardcodedHosts(in:)`` sees a literal host only, so `URL(string: "https://\(userText)")` and
    /// `URL(string: pastedString)` contribute nothing — see
    /// ``hostExtractorSeparatesHardcodedDestinationsFromUserSuppliedURLs()``.
    @Test func hardcodedNetworkDestinationsAreExactlyTheAllowlist() throws {
        let repoRoot = Self.repoRoot()

        var found: [String: [String]] = [:]   // host -> the file names that hardcode it (failure evidence)
        var scanned = 0
        for root in Self.shippingSwiftRoots {
            var scannedInRoot = 0
            for url in Self.swiftFiles(under: root, repoRoot: repoRoot) {
                let source = try String(contentsOf: url, encoding: .utf8)
                scanned += 1
                scannedInRoot += 1
                for host in Self.hardcodedHosts(in: source) {
                    found[host, default: []].append(url.lastPathComponent)
                }
            }
            #expect(scannedInRoot > 0, "Scanned zero Swift files under '\(root)' — the destination allowlist is silently narrower.")
        }
        #expect(
            scanned >= Self.minimumShippingFilesScanned,
            "Scanned only \(scanned) shipping Swift files (floor \(Self.minimumShippingFilesScanned)) — discovery is broken."
        )
        // Discovery must find the allowlisted hosts it is supposed to find; an empty result would mean
        // the extractor stopped working and every future endpoint would sail through.
        #expect(!found.isEmpty, "Found zero hardcoded hosts in shipping code — the host extractor is broken, not the code clean.")

        let allowed = Set(Self.permittedDestinations.map(\.host))
        let unexpected = Set(found.keys).subtracting(allowed).sorted()
        let evidence = unexpected
            .map { host in host + " (in " + (found[host] ?? []).sorted().joined(separator: ", ") + ")" }
            .joined(separator: "; ")
        #expect(
            unexpected.isEmpty,
            "Unallowlisted network destination(s): \(evidence). Fernlet talks to a fixed, reviewed set of hosts. To add one, add a PermittedDestination with a reason here AND a row in Docs/No-Tracking-Wall.md, in the same commit."
        )

        let stale = allowed.subtracting(Set(found.keys)).sorted()
        #expect(
            stale.isEmpty,
            "Allowlisted destination(s) \(stale) no longer appear in shipping code — remove them here and in Docs/No-Tracking-Wall.md so the allowlist keeps describing reality."
        )
    }

    /// A raw HTTP client may exist only in the two pinned web importers and the session factory they
    /// share, and the only hosts hardcoded inside them are the DuckDuckGo search endpoint and its
    /// redirect base.
    ///
    /// The host allowlist alone can be evaded by assembling a hostname at runtime; this cannot. A new
    /// `URLSession` anywhere else in shipping code — a "telemetry uploader", a "config fetcher" — fails
    /// here regardless of how its URL is built.
    ///
    /// This test governs WHERE a client may live. ``everyOutboundFetchUsesTheEphemeralPrivateTabSession()``
    /// governs HOW it must fetch; neither implies the other.
    @Test func onlyThePinnedWebImportersMayHoldAnHTTPClient() throws {
        let repoRoot = Self.repoRoot()

        var clients: Set<String> = []
        var hostsInClients: Set<String> = []
        var scanned = 0
        for root in Self.shippingSwiftRoots {
            for url in Self.swiftFiles(under: root, repoRoot: repoRoot) {
                let source = try String(contentsOf: url, encoding: .utf8)
                scanned += 1
                guard Self.namesHTTPClientAPI(in: source) else { continue }
                clients.insert(url.lastPathComponent)
                hostsInClients.formUnion(Self.hardcodedHosts(in: source))
            }
        }
        #expect(scanned >= Self.minimumShippingFilesScanned, "Scanned only \(scanned) shipping Swift files (floor \(Self.minimumShippingFilesScanned)) — discovery is broken.")

        let unexpected = clients.subtracting(Self.permittedHTTPClientFiles).sorted()
        #expect(
            unexpected.isEmpty,
            "\(unexpected) hold(s) a raw HTTP client. Outbound HTTP lives in exactly \(Self.permittedHTTPClientFiles.sorted()) — see Docs/No-Tracking-Wall.md."
        )
        let missing = Self.permittedHTTPClientFiles.subtracting(clients).sorted()
        #expect(
            missing.isEmpty,
            "Pinned HTTP-client file(s) \(missing) no longer match the client markers — renamed/moved, or the markers went stale. Coverage dropped."
        )

        #expect(
            hostsInClients == ["duckduckgo.com", "html.duckduckgo.com"],
            "The hosts hardcoded inside the web importers are \(hostsInClients.sorted()), expected the DuckDuckGo search endpoint and its redirect base only."
        )
    }

    /// Every outbound fetch in shipping code goes through the shared ephemeral "private tab" session:
    /// no cookie jar, no URL cache, no credential store, nothing that survives one request to be read
    /// back on the next.
    ///
    /// Four independent assertions, because each one alone has an obvious way around it:
    /// 1. **No process-wide session anywhere.** `URLSession.shared`, `URLSessionConfiguration.default`,
    ///    and `.background` are banned in ALL shipping code — not just the pinned files — because the
    ///    ban has to hold for whatever file holds the *next* fetch.
    /// 2. **Exactly one file constructs a session, and it uses `.ephemeral`.** Otherwise rule 1 is
    ///    trivially satisfied by `URLSession(configuration: someConfigVariable)`.
    /// 3. **The factory still sets every privacy knob.** Otherwise `.ephemeral` alone would pass while
    ///    quietly keeping an in-memory cookie jar and credential store for the process lifetime.
    /// 4. **Both importers actually reference the factory.** Otherwise deleting the call site and
    ///    reverting to `URLSession.shared` would fail rule 1 — but deleting the fetch and reintroducing
    ///    it as, say, an `NWConnection` would not, and coverage would silently drop to zero.
    ///
    /// What this deliberately does NOT check: timeouts, `User-Agent`, `Accept`, redirect delegates,
    /// content-type checks, and body caps. Those differ between the two importers on purpose (see
    /// Docs/No-Tracking-Wall.md §2a) and flattening them would be a behaviour change dressed as a
    /// privacy rule.
    @Test func everyOutboundFetchUsesTheEphemeralPrivateTabSession() throws {
        let repoRoot = Self.repoRoot()

        var scanned = 0
        var offenders: [String: [String]] = [:]        // banned token -> files naming it
        var sessionConstructors: Set<String> = []      // files calling URLSession(configuration:)
        var ephemeralConstructors: Set<String> = []    // ...of which name .ephemeral
        var factoryReferences: Set<String> = []        // files naming EphemeralWebSession

        for root in Self.shippingSwiftRoots {
            var scannedInRoot = 0
            for url in Self.swiftFiles(under: root, repoRoot: repoRoot) {
                let code = Self.codeOnly(try String(contentsOf: url, encoding: .utf8))
                let name = url.lastPathComponent
                scanned += 1
                scannedInRoot += 1

                for token in Self.forbiddenSessionConfigurations where Self.namesSymbol(code, token) {
                    offenders[token, default: []].append(name)
                }
                if code.contains("URLSession(configuration:") {
                    sessionConstructors.insert(name)
                    if Self.namesSymbol(code, "URLSessionConfiguration.ephemeral") {
                        ephemeralConstructors.insert(name)
                    }
                }
                if Self.namesSymbol(code, "EphemeralWebSession") {
                    factoryReferences.insert(name)
                }
            }
            #expect(scannedInRoot > 0, "Scanned zero Swift files under '\(root)' — the private-tab scan is silently narrower.")
        }
        #expect(
            scanned >= Self.minimumShippingFilesScanned,
            "Scanned only \(scanned) shipping Swift files (floor \(Self.minimumShippingFilesScanned)) — discovery is broken; the private-tab rule would pass vacuously."
        )

        // 1) No shared/persistent session anywhere in shipping code.
        let evidence = offenders
            .sorted { $0.key < $1.key }
            .map { "\($0.key) (in \($0.value.sorted().joined(separator: ", ")))" }
            .joined(separator: "; ")
        #expect(
            offenders.isEmpty,
            "Persistent/shared URL session(s) in shipping code: \(evidence). Every fetch must go through WebScrapingKit's EphemeralWebSession — URLSession.shared carries the process-wide cookie jar, URL cache, and credential store, which is cross-request tracking by another name. See Docs/No-Tracking-Wall.md §2a."
        )

        // 2) Exactly one file builds a session, and it is the ephemeral factory.
        #expect(
            sessionConstructors == [Self.ephemeralSessionFactoryFile],
            "Files constructing a URLSession are \(sessionConstructors.sorted()), expected exactly [\(Self.ephemeralSessionFactoryFile)]. A session built anywhere else is a session nobody has reviewed the storage policy of."
        )
        #expect(
            ephemeralConstructors == sessionConstructors,
            "\(sessionConstructors.subtracting(ephemeralConstructors).sorted()) construct a URLSession without naming URLSessionConfiguration.ephemeral — the private-tab guarantee starts with the ephemeral base configuration."
        )

        // 3) The factory still sets every knob, in code rather than only in prose.
        let factoryURL = Self.locate(Self.ephemeralSessionFactoryFile, under: Self.shippingSwiftRoots, repoRoot: repoRoot)
        if let factoryURL {
            let factoryCode = Self.codeOnly(try String(contentsOf: factoryURL, encoding: .utf8))
            let missingSettings = Self.requiredEphemeralSessionSettings.filter { !Self.namesSymbol(factoryCode, $0) }
            #expect(
                missingSettings.isEmpty,
                "\(Self.ephemeralSessionFactoryFile) no longer sets \(missingSettings). Each of these is part of the private-tab guarantee — several are redundant under .ephemeral and are set anyway so the guarantee survives a change of base configuration. Removing one needs a deliberate edit here and in Docs/No-Tracking-Wall.md §2a."
            )
        } else {
            Issue.record("Could not find \(Self.ephemeralSessionFactoryFile) under \(Self.shippingSwiftRoots) — the private-browsing session factory was renamed or deleted, and this whole rule is unenforced.")
        }

        // 4) Both importers actually route through it (coverage cannot silently drop to zero).
        let importersMissingFactory = Self.pinnedWebImporterFiles.subtracting(factoryReferences).sorted()
        #expect(
            importersMissingFactory.isEmpty,
            "Pinned web importer(s) \(importersMissingFactory) no longer reference EphemeralWebSession. They fetch the web; they must do it through the private-tab session."
        )
    }

    /// No `WKWebView` exists in shipping code today — and if one ever appears it must use a
    /// non-persistent data store. Out-of-process in-app browsers are pinned to the one file that has
    /// one.
    ///
    /// A `WKWebView` is a second, entirely separate storage jar from `URLSession`'s: its default
    /// `WKWebsiteDataStore.default()` persists cookies, localStorage, and IndexedDB to disk and is
    /// shared by every web view in the app. Making the URL sessions ephemeral while leaving a web view
    /// on the default store would move the tracking channel rather than close it, so the rule is
    /// written now, while the answer is "there are none", instead of after the first one lands.
    ///
    /// `SFSafariViewController` is a different thing and is treated differently on purpose: it runs
    /// out of process against Safari's own storage, which this app can neither read nor make
    /// ephemeral — there is no API. It is the user's browser, opened on a page the user is already
    /// looking at. So the rule for it is locational: exactly one file may present one.
    @Test func noPersistentWebViewExistsAndInAppBrowsersArePinned() throws {
        let repoRoot = Self.repoRoot()

        var scanned = 0
        var webViewFiles: [String: [String]] = [:]   // file -> markers found (failure evidence)
        var browserFiles: Set<String> = []

        for root in Self.shippingSwiftRoots {
            for url in Self.swiftFiles(under: root, repoRoot: repoRoot) {
                let code = Self.codeOnly(try String(contentsOf: url, encoding: .utf8))
                let name = url.lastPathComponent
                scanned += 1

                let webViewHits = Self.webViewMarkers.filter { Self.namesSymbol(code, $0) }
                if !webViewHits.isEmpty {
                    webViewFiles[name] = webViewHits
                    // The forward-compatible half: a web view that DOES opt into a non-persistent
                    // store is not a wall breach, it is the correct way to add one.
                    #expect(
                        Self.namesSymbol(code, Self.nonPersistentDataStoreMarker),
                        "\(name) creates a web view (\(webViewHits)) without \(Self.nonPersistentDataStoreMarker)(). A WKWebView defaults to WKWebsiteDataStore.default() — an on-disk cookie/localStorage jar shared across the app, which is exactly the cross-request state the ephemeral URLSession exists to prevent."
                    )
                }
                if Self.inAppBrowserMarkers.contains(where: { Self.namesSymbol(code, $0) }) {
                    browserFiles.insert(name)
                }
            }
        }
        #expect(
            scanned >= Self.minimumShippingFilesScanned,
            "Scanned only \(scanned) shipping Swift files (floor \(Self.minimumShippingFilesScanned)) — discovery is broken."
        )

        // Today the answer is zero. Asserting that (rather than only the conditional rule above) makes
        // the FIRST web view a deliberate decision, since it must edit this expectation as well.
        #expect(
            webViewFiles.isEmpty,
            "Shipping code now contains WebKit web view(s): \(webViewFiles.keys.sorted()). Fernlet renders no remote web content in-process. If that changes, the view needs \(Self.nonPersistentDataStoreMarker)() AND a row in Docs/No-Tracking-Wall.md §2a explaining what it loads."
        )

        // The out-of-process browser surface is pinned in both directions. The non-empty side is also
        // this scan's floor: an empty result here means the matcher broke, not that the code got
        // cleaner (unlike the web-view scan above, which is legitimately empty).
        #expect(
            browserFiles == Self.permittedInAppBrowserFiles,
            "In-app browser presentation lives in \(browserFiles.sorted()), expected \(Self.permittedInAppBrowserFiles.sorted()). SFSafariViewController hands the user's browsing to Safari's own storage, which this app cannot make ephemeral — so a NEW presentation site is a decision, and a MISSING one means this scan stopped working."
        )
    }

    /// Every `PrivacyInfo.xcprivacy` keeps declaring zero tracking: `NSPrivacyTracking` false, no
    /// tracking domains, and no collected data type flagged for tracking or advertising/analytics.
    ///
    /// The manifest is what Apple publishes on the App Store product page as the privacy label, so a
    /// drift here is a public claim changing without anyone noticing. Manifests are pinned by path, so
    /// deleting one fails rather than shrinking the scan.
    @Test func privacyManifestsDeclareNoTrackingOrAdvertising() throws {
        let repoRoot = Self.repoRoot()
        var checked = 0

        for relativePath in Self.privacyManifestPaths {
            let url = repoRoot.appendingPathComponent(relativePath)
            guard let data = try? Data(contentsOf: url),
                  let manifest = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
                Issue.record("Privacy manifest '\(relativePath)' is missing or unreadable — deleted, renamed, or malformed. Every shipping target must declare one.")
                continue
            }
            checked += 1

            #expect(
                manifest["NSPrivacyTracking"] as? Bool == false,
                "\(relativePath): NSPrivacyTracking must be explicitly false — Fernlet does not track."
            )

            let trackingDomains = manifest["NSPrivacyTrackingDomains"] as? [String] ?? []
            #expect(
                trackingDomains.isEmpty,
                "\(relativePath): NSPrivacyTrackingDomains must stay empty, found \(trackingDomains)."
            )

            let collected = manifest["NSPrivacyCollectedDataTypes"] as? [[String: Any]] ?? []
            for entry in collected {
                let type = entry["NSPrivacyCollectedDataType"] as? String ?? "<unnamed>"
                #expect(
                    entry["NSPrivacyCollectedDataTypeTracking"] as? Bool != true,
                    "\(relativePath): collected data type '\(type)' is flagged as used for TRACKING."
                )
                let purposes = Set(entry["NSPrivacyCollectedDataTypePurposes"] as? [String] ?? [])
                let banned = purposes.intersection(Self.bannedCollectedDataPurposes).sorted()
                #expect(
                    banned.isEmpty,
                    "\(relativePath): collected data type '\(type)' declares advertising/analytics purpose(s) \(banned)."
                )
            }
        }

        #expect(
            checked == Self.privacyManifestPaths.count,
            "Read \(checked) of \(Self.privacyManifestPaths.count) privacy manifests — coverage dropped."
        )
    }

    /// No Info.plist or entitlements file asks for tracking permission, declares an attribution
    /// endpoint, or points iCloud at a container other than the user's own.
    ///
    /// The ATT prompt (`NSUserTrackingUsageDescription`) and `SKAdNetworkItems` are plist-only surfaces
    /// the Swift scan cannot see; a repointed `com.apple.developer.icloud-container-identifiers` is how
    /// synced data would end up somewhere other than the user's private CloudKit database.
    @Test func plistFamilyFilesDeclareNoTrackingPermissionOrForeignContainer() throws {
        let repoRoot = Self.repoRoot()

        var scanned = 0
        var sawContainerDeclaration = false
        for root in Self.bundleRoots {
            let rootURL = repoRoot.appendingPathComponent(root)
            guard let enumerator = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: nil) else {
                Issue.record("Could not enumerate '\(root)' — the plist-family scan is unenforced.")
                continue
            }
            for case let url as URL in enumerator {
                let isPlistFamily = url.pathExtension == "plist"
                    || url.pathExtension == "entitlements"
                    || url.pathExtension == "xcprivacy"
                guard isPlistFamily else { continue }
                scanned += 1

                if let text = try? String(contentsOf: url, encoding: .utf8) {
                    let symbols = Self.bannedSymbols(in: text)
                    #expect(
                        symbols.isEmpty,
                        "\(url.lastPathComponent) declares tracking key(s) \(symbols). Fernlet never shows the ATT prompt and registers no ad network."
                    )
                }

                guard let data = try? Data(contentsOf: url),
                      let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
                      let containers = plist["com.apple.developer.icloud-container-identifiers"] as? [String] else {
                    continue
                }
                sawContainerDeclaration = true
                let foreign = Set(containers).subtracting(Self.allowedICloudContainers).sorted()
                #expect(
                    foreign.isEmpty,
                    "\(url.lastPathComponent) declares iCloud container(s) \(foreign). Sync goes to the user's own Apple container only."
                )
            }
        }

        #expect(
            scanned >= Self.minimumPlistFamilyFilesScanned,
            "Scanned only \(scanned) plist-family files (floor \(Self.minimumPlistFamilyFilesScanned)) — discovery is broken."
        )
        #expect(
            sawContainerDeclaration,
            "No entitlements file declared an iCloud container — the container pin matched nothing and is passing vacuously."
        )
    }

    // MARK: - Fixtures (the matchers must actually catch a planted violation)

    /// Fixture: the SDK matcher flags planted imports, tolerates the ordinary English words several SDK
    /// names collide with, and is not fooled by a mention in prose or a longer module name.
    @Test func bannedSDKMatcherFlagsPlantedImportsOnly() {
        // Real imports of banned modules — flagged.
        #expect(NoTrackingBoundaryTests.bannedSDKs(in: "import FirebaseAnalytics").contains("FirebaseAnalytics"))
        #expect(NoTrackingBoundaryTests.bannedSDKs(in: "@preconcurrency import Mixpanel").contains("Mixpanel"))
        #expect(NoTrackingBoundaryTests.bannedSDKs(in: "import AdSupport.ASIdentifierManager").contains("AdSupport"))
        #expect(NoTrackingBoundaryTests.bannedSDKs(in: "#if canImport(AppTrackingTransparency)").contains("AppTrackingTransparency"))

        // The ambiguous-name guard: these are UI copy and ordinary identifiers, not SDKs.
        #expect(NoTrackingBoundaryTests.bannedSDKs(in: #"Text("Adjust servings")"#).isEmpty)
        #expect(NoTrackingBoundaryTests.bannedSDKs(in: "// the Branch of the DAG that Segment-ed the day").isEmpty)
        #expect(NoTrackingBoundaryTests.bannedSDKs(in: "let analytics = localOnlyAnalytics()").isEmpty)

        // Mentions in prose or strings, and unrelated modules — clean.
        #expect(NoTrackingBoundaryTests.bannedSDKs(in: "/// We deliberately do not use Firebase.").isEmpty)
        #expect(NoTrackingBoundaryTests.bannedSDKs(in: #"let s = "import Sentry""#).isEmpty)
        #expect(NoTrackingBoundaryTests.bannedSDKs(in: "import Foundation\nimport SwiftUI").isEmpty)
    }

    /// Fixture: the symbol matcher catches the tracking identifiers as whole symbols and does not fire
    /// on a longer, unrelated identifier that merely contains one.
    @Test func bannedSymbolMatcherFlagsWholeIdentifiersOnly() {
        #expect(NoTrackingBoundaryTests.bannedSymbols(in: "ASIdentifierManager.shared().advertisingIdentifier")
            .contains("advertisingIdentifier"))
        #expect(NoTrackingBoundaryTests.bannedSymbols(in: "await ATTrackingManager.requestTrackingAuthorization { _ in }")
            .contains("requestTrackingAuthorization"))
        #expect(NoTrackingBoundaryTests.bannedSymbols(in: "<key>NSUserTrackingUsageDescription</key>")
            .contains("NSUserTrackingUsageDescription"))

        // Longer identifiers that merely CONTAIN a banned token — no hit (no false CI hard-fails).
        #expect(NoTrackingBoundaryTests.bannedSymbols(in: "let x = advertisingIdentifierPolicyDoc").isEmpty)
        #expect(NoTrackingBoundaryTests.bannedSymbols(in: "struct ATTrackingManagerShimTests {}").isEmpty)
    }

    /// Fixture: the host extractor separates a HARDCODED destination (a literal host the app chose)
    /// from a USER-SUPPLIED one (a URL built at runtime from what the user pasted or shared).
    ///
    /// This is the distinction that keeps the recipe/product web import legitimate: those importers
    /// fetch arbitrary user URLs by design, and must not trip the allowlist.
    @Test func hostExtractorSeparatesHardcodedDestinationsFromUserSuppliedURLs() {
        // Hardcoded destinations — extracted, and normalized to a bare lowercased host.
        #expect(NoTrackingBoundaryTests.hardcodedHosts(in: #"URL(string: "https://api.tracker.io/v1/events")"#) == ["api.tracker.io"])
        #expect(NoTrackingBoundaryTests.hardcodedHosts(in: #"URLComponents(string: "https://HTML.DuckDuckGo.com/html/")"#) == ["html.duckduckgo.com"])
        #expect(NoTrackingBoundaryTests.hardcodedHosts(in: #"let u = "https://example.com:8443/x?q=1""#) == ["example.com"])

        // User-supplied at runtime — NOT destinations this wall governs.
        #expect(NoTrackingBoundaryTests.hardcodedHosts(in: ###"URL(string: "https://\(trimmed)")"###).isEmpty)
        #expect(NoTrackingBoundaryTests.hardcodedHosts(in: "URL(string: pastedString)").isEmpty)
        #expect(NoTrackingBoundaryTests.hardcodedHosts(in: #"URL(string: "https://" + host)"#).isEmpty)

        // Prose is not a destination.
        #expect(NoTrackingBoundaryTests.hardcodedHosts(in: "// see https://github.com/krzyzanowskim/CryptoSwift").isEmpty)
        #expect(NoTrackingBoundaryTests.hardcodedHosts(in: "/// Docs at https://developer.apple.com/documentation").isEmpty)
        #expect(NoTrackingBoundaryTests.hardcodedHosts(in: " * https://example.org/legacy").isEmpty)

        // A destination on a line that merely ENDS in a comment is still a destination.
        #expect(NoTrackingBoundaryTests.hardcodedHosts(in: #"let u = URL(string: "https://metrics.evil.test/i") // harmless, honest"#)
            == ["metrics.evil.test"])
    }

    /// Fixture: the private-tab matchers catch a planted shared/persistent session, tolerate the
    /// *documentation* of one (which both importers and the factory contain by the paragraph), and
    /// recognise a correctly configured web view.
    ///
    /// Without this, the whole private-tab rule could rot into a matcher that returns nothing — the
    /// classic way a grep wall dies quietly while still reporting green.
    @Test func privateTabMatchersFlagPlantedSharedSessionsOnly() {
        // Planted violations — caught.
        let leaky = NoTrackingBoundaryTests.codeOnly("let (d, _) = try await URLSession.shared.data(for: request)")
        #expect(NoTrackingBoundaryTests.namesSymbol(leaky, "URLSession.shared"))
        let defaulted = NoTrackingBoundaryTests.codeOnly("let s = URLSession(configuration: .default)\nlet c = URLSessionConfiguration.default")
        #expect(NoTrackingBoundaryTests.namesSymbol(defaulted, "URLSessionConfiguration.default"))
        #expect(defaulted.contains("URLSession(configuration:"))
        let backgrounded = NoTrackingBoundaryTests.codeOnly(#"URLSessionConfiguration.background(withIdentifier: "sync")"#)
        #expect(NoTrackingBoundaryTests.namesSymbol(backgrounded, "URLSessionConfiguration.background"))

        // Documentation of the very thing being banned — NOT a violation. Both importers and the
        // factory explain at length why they do not use URLSession.shared; a matcher that indicted
        // them for saying so would be disabled within a week.
        let documented = NoTrackingBoundaryTests.codeOnly("""
        /// Transport is EphemeralWebSession, never URLSession.shared: that one carries the
        /// process-wide cookie jar.
        // was: URLSessionConfiguration.default
         * WKWebsiteDataStore.default() persists to disk.
        """)
        #expect(!NoTrackingBoundaryTests.namesSymbol(documented, "URLSession.shared"))
        #expect(!NoTrackingBoundaryTests.namesSymbol(documented, "URLSessionConfiguration.default"))
        #expect(!NoTrackingBoundaryTests.namesSymbol(documented, "WKWebsiteDataStore"))

        // A trailing comment does not launder a real call.
        let sneaky = NoTrackingBoundaryTests.codeOnly("let s = URLSession.shared // just for one metric")
        #expect(NoTrackingBoundaryTests.namesSymbol(sneaky, "URLSession.shared"))

        // The ephemeral factory's own shape passes every required-setting check.
        let factory = NoTrackingBoundaryTests.codeOnly("""
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration)
        """)
        let missingFromFactory = NoTrackingBoundaryTests.requiredEphemeralSessionSettings
            .filter { !NoTrackingBoundaryTests.namesSymbol(factory, $0) }
        #expect(missingFromFactory.isEmpty, "required-setting matcher missed \(missingFromFactory)")
        // Drop one knob and the check must notice.
        let weakened = factory.replacingOccurrences(of: "configuration.urlCredentialStorage = nil", with: "")
        #expect(!NoTrackingBoundaryTests.namesSymbol(weakened, "urlCredentialStorage"))

        // Web views: the marker fires on a real one, and the non-persistent opt-in is detected.
        let badWebView = NoTrackingBoundaryTests.codeOnly("let view = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())")
        let badWebViewHits = NoTrackingBoundaryTests.webViewMarkers
            .filter { NoTrackingBoundaryTests.namesSymbol(badWebView, $0) }
        #expect(badWebViewHits.contains("WKWebView"))
        #expect(badWebViewHits.contains("WKWebViewConfiguration"))
        #expect(!NoTrackingBoundaryTests.namesSymbol(badWebView, NoTrackingBoundaryTests.nonPersistentDataStoreMarker))
        let goodWebView = NoTrackingBoundaryTests.codeOnly("""
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore.nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        """)
        #expect(NoTrackingBoundaryTests.namesSymbol(goodWebView, NoTrackingBoundaryTests.nonPersistentDataStoreMarker))

        // Identifier-boundary discipline: a longer, unrelated identifier is not a hit.
        #expect(!NoTrackingBoundaryTests.namesSymbol("struct URLSessionSharedFake {}", "URLSession.shared"))
        #expect(!NoTrackingBoundaryTests.namesSymbol("let x = WKWebViewController()", "WKWebView"))
    }

    /// Fixture: the HTTP-client marker sees a real API use and not a file that only discusses one, and
    /// the package-URL parser reads both manifest dialects.
    @Test func httpClientMarkerAndPackageURLParserSeeOnlyRealDeclarations() {
        #expect(NoTrackingBoundaryTests.namesHTTPClientAPI(in: "let (data, _) = try await URLSession.shared.data(for: request)"))
        #expect(NoTrackingBoundaryTests.namesHTTPClientAPI(in: "var request = URLRequest(url: url, timeoutInterval: 15)"))
        #expect(!NoTrackingBoundaryTests.namesHTTPClientAPI(in: "/// URLSession invokes this delegate off the main actor."))
        #expect(!NoTrackingBoundaryTests.namesHTTPClientAPI(in: "// A URLRequest never leaves this module."))
        // Identifier-boundary matching: a longer, unrelated identifier is not an HTTP client.
        #expect(!NoTrackingBoundaryTests.namesHTTPClientAPI(in: "struct URLSessionFakeHelper {}"))

        #expect(NoTrackingBoundaryTests.declaredPackageURLs(in: #"        .package(url: "https://github.com/krzyzanowskim/CryptoSwift", .upToNextMinor(from: "1.10.0")),"#)
            == ["https://github.com/krzyzanowskim/CryptoSwift"])
        #expect(NoTrackingBoundaryTests.declaredPackageURLs(in: #"			repositoryURL = "https://github.com/firebase/firebase-ios-sdk";"#)
            == ["https://github.com/firebase/firebase-ios-sdk"])
        #expect(NoTrackingBoundaryTests.declaredPackageURLs(in: #"// .package(url: "https://example.com/commented-out"),"#).isEmpty)
        #expect(NoTrackingBoundaryTests.declaredPackageURLs(in: "let x = 1").isEmpty)
    }

    // MARK: - Pure matchers

    /// The banned SDK modules `source` actually IMPORTS — as an `import` declaration or a
    /// `canImport(...)` condition. Never a free-text match: several SDK names are ordinary words.
    ///
    /// Reuses ``S3BoundaryTests/importedModules(in:)`` so both walls agree on what an import is.
    static func bannedSDKs(in source: String) -> [String] {
        let modules = S3BoundaryTests.importedModules(in: source)
            .union(conditionallyImportedModules(in: source))
        return bannedSDKModules.filter { modules.contains($0) }.sorted()
    }

    /// The banned tracking symbols present in `source`, matched at identifier boundaries so a token
    /// never fires as a substring of a longer, unrelated identifier.
    ///
    /// Reuses ``S3BoundaryTests/containsAtIdentifierBoundary(_:_:)`` for the same reason as above.
    static func bannedSymbols(in source: String) -> [String] {
        bannedTrackingSymbols.filter { namesSymbol(source, $0) }.sorted()
    }

    /// ``S3BoundaryTests/containsAtIdentifierBoundary(_:_:)`` behind a cheap substring pre-filter.
    ///
    /// The S3 grep-wall boundary-matches ~30 tokens against ~20 AI-facing files; this wall matches
    /// ~11 symbols against ~530 files across every target, and the boundary matcher rebuilds a
    /// `[Character]` of the whole source on each call. Boundary hits are a strict SUBSET of plain
    /// substring hits, so short-circuiting when the substring is absent cannot change any verdict —
    /// it only skips the walk. Semantics identical, roughly an order of magnitude less work.
    static func namesSymbol(_ source: String, _ token: String) -> Bool {
        source.contains(token) && S3BoundaryTests.containsAtIdentifierBoundary(source, token)
    }

    /// Module names appearing in a `canImport(<Module>)` condition.
    ///
    /// `#if canImport(AdSupport)` is a real linkage decision that ``S3BoundaryTests/importedModules(in:)``
    /// cannot see (it is not an `import` line), and it is exactly how an optional tracking dependency
    /// would be introduced "safely".
    static func conditionallyImportedModules(in source: String) -> Set<String> {
        var modules: Set<String> = []
        let characters = Array(source)
        let marker = Array("canImport(")
        var index = 0
        while index + marker.count <= characters.count {
            guard Array(characters[index..<(index + marker.count)]) == marker else {
                index += 1
                continue
            }
            var cursor = index + marker.count
            while cursor < characters.count, characters[cursor] == " " { cursor += 1 }
            var name = ""
            while cursor < characters.count, characters[cursor].isLetter || characters[cursor].isNumber || characters[cursor] == "_" {
                name.append(characters[cursor])
                cursor += 1
            }
            if !name.isEmpty { modules.insert(name) }
            index = max(cursor, index + 1)
        }
        return modules
    }

    /// The hardcoded hosts in `source`: the literal host of every `http://` / `https://` URL written
    /// into the code, lowercased, with comment-only lines skipped.
    ///
    /// A host is read as the run of `[A-Za-z0-9.-]` immediately after `://`. That single rule is what
    /// distinguishes a HARDCODED destination from a USER-SUPPLIED one: Swift interpolation
    /// (`"https://\(host)"`), concatenation (`"https://" + host`) and a plain variable
    /// (`URL(string: pasted)`) all yield an empty run and contribute nothing — the app did not choose
    /// that destination, the user did. Ports, paths, and query strings terminate the run and are
    /// dropped. Pure + testable.
    static func hardcodedHosts(in source: String) -> Set<String> {
        var hosts: Set<String> = []
        for line in source.components(separatedBy: "\n") {
            // Cheap pre-filter first: the overwhelming majority of lines hold no URL at all, and the
            // character-array walk below is the expensive part of this whole wall.
            guard line.contains("://") else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("//"), !trimmed.hasPrefix("*"), !trimmed.hasPrefix("/*") else { continue }
            let characters = Array(line)
            var index = 0
            while index < characters.count {
                guard let hostStart = schemeSeparatorEnd(characters, at: index) else {
                    index += 1
                    continue
                }
                var cursor = hostStart
                var host = ""
                while cursor < characters.count, isHostCharacter(characters[cursor]) {
                    host.append(characters[cursor])
                    cursor += 1
                }
                let normalized = host.lowercased()
                    .trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
                if !normalized.isEmpty { hosts.insert(normalized) }
                index = max(cursor, index + 1)
            }
        }
        return hosts
    }

    /// Index just past the `://` of an `http`/`https` scheme starting at `index`, or nil.
    ///
    /// The left-boundary check keeps a scheme embedded in a longer word (`xhttps://`) from counting.
    private static func schemeSeparatorEnd(_ characters: [Character], at index: Int) -> Int? {
        for scheme in ["https://", "http://"] {
            let marker = Array(scheme)
            guard index + marker.count <= characters.count,
                  Array(characters[index..<(index + marker.count)]) == marker else {
                continue
            }
            if index > 0, characters[index - 1].isLetter || characters[index - 1].isNumber { continue }
            return index + marker.count
        }
        return nil
    }

    /// Whether `character` may appear in a hostname. Everything else — `/`, `"`, `\`, `(`, `:`, `?`,
    /// whitespace — terminates the host run.
    private static func isHostCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "." || character == "-"
    }

    /// `source` with comment-only lines removed, so every network rule below matches what the file
    /// DOES rather than what it says.
    ///
    /// This matters more here than anywhere else in the wall: these files document their own network
    /// policy at length, naming `URLSession.shared` and `WKWebsiteDataStore` in prose precisely to
    /// explain why they do not use them. A rule that could not tell code from commentary would either
    /// hard-fail on its own documentation or have to be written so loosely it caught nothing.
    ///
    /// Line-based and deliberately simple (leading `//`, `*`, `/*`), matching the comment handling in
    /// ``hardcodedHosts(in:)`` and ``declaredPackageURLs(in:)`` so all three agree. A trailing comment
    /// on a code line is NOT stripped — a real call followed by `// harmless` is still a real call.
    static func codeOnly(_ source: String) -> String {
        source
            .components(separatedBy: "\n")
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.hasPrefix("//") && !trimmed.hasPrefix("*") && !trimmed.hasPrefix("/*")
            }
            .joined(separator: "\n")
    }

    /// Whether `source` uses a raw HTTP/socket client API in CODE (comment lines stripped first, so a
    /// file that only documents `URLSession` is not treated as a client). Pure + testable.
    static func namesHTTPClientAPI(in source: String) -> Bool {
        let code = codeOnly(source)
        return httpClientMarkers.contains { namesSymbol(code, $0) }
    }

    /// The package repository URLs declared in a manifest — SwiftPM's `.package(url: "…")` and the
    /// pbxproj's `repositoryURL = "…";`, which are the only two ways a dependency enters this project.
    ///
    /// Line-scoped (the URL is the first double-quoted run on a declaring line) and comment-aware, so a
    /// commented-out dependency is not counted. Pure + testable.
    static func declaredPackageURLs(in manifest: String) -> Set<String> {
        var urls: Set<String> = []
        for line in manifest.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("//"), !trimmed.hasPrefix("*"), !trimmed.hasPrefix("/*") else { continue }
            guard trimmed.contains(".package(url:") || trimmed.contains("repositoryURL") else { continue }
            let quoted = trimmed.components(separatedBy: "\"")
            guard quoted.count >= 2, quoted[1].contains("://") else { continue }
            urls.insert(quoted[1])
        }
        return urls
    }

    // MARK: - Discovery helpers

    /// The repo root, derived from this file's location (FernletTests/<self>.swift).
    private static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// Every `.swift` file under `root`, sorted for deterministic failure output. An unreachable root
    /// yields an empty array; callers assert their own floor on top (a silently empty root is the one
    /// failure mode a grep-wall must never tolerate).
    private static func swiftFiles(under root: String, repoRoot: URL) -> [URL] {
        let rootURL = repoRoot.appendingPathComponent(root)
        guard let enumerator = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: nil) else {
            return []
        }
        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            files.append(url)
        }
        return files.sorted { $0.path < $1.path }
    }

    /// The first file named `filename` under any of `roots`, or nil. Callers decide whether absence is
    /// a hard failure — for a pinned file it always is.
    private static func locate(_ filename: String, under roots: [String], repoRoot: URL) -> URL? {
        for root in roots {
            for url in swiftFiles(under: root, repoRoot: repoRoot) where url.lastPathComponent == filename {
                return url
            }
        }
        return nil
    }
}
