# ``FernletMessagesExtension``

Fernlet's iMessage app: a composer that shares a recipe or one day's planned workout as a Messages
card, and a viewer that hands a received card to Fernlet for review.

## Overview

FernletMessagesExtension is a `com.apple.message-payload-provider` app extension whose principal
class, ``FernletMessagesViewController``, is an `MSMessagesAppViewController` built in UIKit — the
only UIKit target Fernlet ships. It links exactly one FernletKit product, `FernletExchange`, and no
repository: `MessagesExtensionBoundaryTests` scans the whole target directory and allows only
`FernletExchange`, `Foundation`, `Messages` and `UIKit` imports, because this code runs in a process
Messages hosts, and a store opened here would be a second persistence stack in the wrong process.

### Composing

The composer's whole view of the user's library is the bounded catalog the containing app
publishes into the App Group after each durable save (`FernletMessagesCatalogFileStore`: at most
100 recipes and 100 one-day workout plans). It never reads the app's stores. The compact
presentation shows up to four cards — the card picked in this session pinned first — and the
expanded one adds search over the whole catalog. **Share** builds an `ExchangeMessageEnvelope`,
wraps it in an `MSMessage` with a template layout, and *inserts* it into the conversation's input
field; the person still presses Messages' own send button. An item larger than a Messages URL can
carry (`ExchangeLimits`: Apple's 5,000-character URL limit, a 3,711-byte envelope) gets the "too
large — export a file instead" status rather than a card Messages would refuse.

The card artwork is drawn locally — an SF Symbol and a wordmark on a 1200×630 canvas — so Messages
never fetches, and a recipient never sees, a private food photo.

### Receiving

When a Fernlet card is opened (`willBecomeActive(with:)` with a selected message, or
`didSelect(_:conversation:)`), the controller decodes the message URL itself and re-validates the
packet and its card through `FernletExchange`; it never trusts what the bubble displays, and an
envelope it cannot validate shows "This Fernlet item can't be opened" and writes nothing. **Review
in Fernlet** enqueues the validated packet into the App Group review inbox and opens
`fernlet://messages/recipe?id=…` (or `/workout`) — a link that carries an opaque inbox identifier
and nothing else. Nothing is imported here: the containing app presents the review, applies the
replay ledger and the calendar and safety checks, and saves only when the person confirms.

A card minted by this extension belongs to Fernlet, so a recipient without Fernlet gets Messages'
standard install prompt for Fernlet itself — the property that made an `MSMessage` card the wrong
transport for the separate Coach app, and the right one here.

### What it keeps

Nothing of its own. The composer used to remember the last-picked recipe in the extension's own
`UserDefaults.standard` — a defaults domain the containing app cannot open, so "Delete everything"
could never clear it — and that write was removed on 2026-09-23. Its only writes are the review-inbox
records, which the app consumes and its wipe clears (`Docs/PrivacyWipeCoverage.md`).

The appex ships its own `PrivacyInfo.xcprivacy`, because App Store Connect checks each executable
against the manifest of the bundle that carries it.
`MessagesExtensionBoundaryTests.theExtensionManifestDeclaresExactlyTheRequiredReasonAPIsItsBinaryUses`
holds that manifest to every source file compiled into the binary — this target plus the package
modules it links — and today they use no required-reason API, so it declares none.
`NoTrackingBoundaryTests` pins the same file for tracking flags.

### Icon

An iMessage app must ship an iMessage App Icon set — App Store Connect otherwise refuses the upload
(ITMS-90644 and relatives). `Assets.xcassets/iMessage App Icon.stickersiconset` carries Xcode's
twelve slots, including the 1024×768 Messages App Store image, and is wired through
`ASSETCATALOG_COMPILER_APPICON_NAME`. **The art is a placeholder** (2026-09-23): the app icon scaled
and padded onto each ~4:3 canvas in its own background colour, awaiting purpose-made art.

### Localization and accessibility

Every sentence lives in ``FernletMessagesCopy`` and this target's `Localizable.xcstrings`, synced by
`Scripts/sync-string-catalogs.sh`; `LocalizationBoundaryTests` rules H1 and H2 hold every literal
here to "catalogued, or an argued token". No `bundle:` argument appears: an appex's `Bundle.main` is
its own bundle. Labels scale with Dynamic Type, each catalog card is one accessibility element whose
label is the item's title, and the target is inside the accessibility wall's scan.

### Concurrency

The target builds in the Swift 5 language mode with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so
the controller and the copy vault are main-actor isolated. The two framework callbacks it passes —
`MSConversation.insert(_:completionHandler:)` and `NSExtensionContext.open(_:completionHandler:)` —
document no callback queue, so both hop to the main queue before touching UIKit, and the unannotated
one is marked `@Sendable` so it cannot silently inherit main-actor isolation.

### Testing

`FernletTests` does not link this target, so the controller itself cannot be exercised there. What
holds it instead: `FernletExchangeTests` (the envelope, card, limits, catalog and inbox logic the
controller drives), `MessagesExtensionBoundaryTests` (imports, the copy vault's catalog, the
manifest), `LocalizationBoundaryTests` H1/H2, and every shipping-code wall, which since 2026-09-23
is held to the full set of shipping roots by
`PowerOfTenBoundaryTests.everyShippingCodeWallScansEveryShippingRoot`. What a simulator cannot check
— two phones, real delivery, locked devices — is the checklist in
`Docs/MessagesExtensionReleaseChecklist.md`.

``MessageTransportProbe`` is the Phase-0 device probe for carrying opaque bytes in `MSMessage.url`.
It has no call site, in shipping code or tests.

## Topics

### Composer and viewer

- ``FernletMessagesViewController``

### Copy

- ``FernletMessagesCopy``

### Phase-0 transport probe

- ``MessageTransportProbe``
- ``MessageTransportProbeError``
