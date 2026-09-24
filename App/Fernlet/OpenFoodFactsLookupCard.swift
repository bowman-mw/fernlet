import Foundation
import AIContext
import FernletDomainModel
import FernletFoundation

// The consent gate, audit trail, persistence and UI of the optional online UPC lookup (tracker
// §3.3). When a scanned barcode misses every local catalog, the not-found screen offers ONE explicit
// tap to look it up on Open Food Facts. Nothing is fetched unless the web-nutrition-lookup consent
// is granted; nothing is saved until the user reviews the values on the naming screen and taps
// "Remember this food"; nothing is logged until they confirm the serving count.

// MARK: - Access

/// What the lookup card may offer, derived from the web-nutrition-lookup consent — the SAME
/// fail-closed predicates the typed-product web search reads, so the two paths can never disagree.
nonisolated enum OpenFoodFactsLookupAccess: Equatable, Sendable {
    /// Consent granted: each tap performs one lookup.
    case permitted
    /// No decision yet (or re-requested in Settings): a tap first asks, exactly as the typed
    /// product search asks at its first eligible lookup. Nothing is sent unless the user allows.
    case askFirst
    /// AI features are off, which closes the whole web-nutrition lane.
    case offBecauseAIOff
    /// Declined or revoked: the card explains and points to Settings. Never fetches.
    case off

    /// The access `settings` grants right now.
    static func access(for settings: FernletSettings) -> OpenFoodFactsLookupAccess {
        if settings.allowsWebNutritionLookup { return .permitted }
        if settings.shouldOfferWebNutritionLookupConsent { return .askFirst }
        return settings.aiStatus == .off ? .offBecauseAIOff : .off
    }
}

// MARK: - The audited lookup

/// Runs one consent-gated, audited lookup — the only caller of `OpenFoodFactsClient`.
///
/// Follows the web-nutrition lane's contract exactly: the consent predicate is checked first (and
/// again inside the client), the egress is recorded in the device-local AI activity log at
/// DISPATCH with a provisional outcome — so a crash mid-lookup still leaves the "this left my
/// device" record — and settled with the real outcome at completion. A failure also leaves a
/// device-local audit line naming its kind (never the barcode).
enum OpenFoodFactsBarcodeLookup {
    /// The app's marketing version, for the User-Agent.
    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    /// Looks `barcode` up once. Returns `.notPermitted` — having recorded nothing and sent
    /// nothing — when `settings` does not grant the web-nutrition lane.
    static func run(
        _ barcode: OpenFoodFactsBarcode,
        settings: FernletSettings,
        auditLog: AIAuditLog = .shared,
        transport: any OpenFoodFactsTransporting = EphemeralOpenFoodFactsTransport()
    ) async -> OpenFoodFactsLookupOutcome {
        guard settings.allowsWebNutritionLookup else { return .notPermitted }
        let payload = BarcodeLookupPayload(barcode: barcode.lookupCode)
        let auditID = await auditLog.record(
            payloadKind: payload.payloadKind,
            destination: .webNutritionLookup,
            includedFields: payload.includedFieldNames,
            outcome: .fellBack
        )
        let outcome = await OpenFoodFactsClient.lookUp(
            barcode, under: settings, appVersion: appVersion, transport: transport
        )
        await auditLog.updateOutcome(id: auditID, to: outcome.succeeded ? .succeeded : .fellBack)
        if case .failed(let failure) = outcome {
            FernletAuditLog.log("openFoodFacts.lookup.failed", context: ["reason": failure.rawValue])
        }
        return outcome
    }
}

// MARK: - Persistence

extension FernletStore {
    /// Saves a reviewed Open Food Facts product as a local USER food, under the name the user
    /// settled on — never into the bundled catalog. Upserts by barcode among earlier OFF imports
    /// (``OpenFoodFactsImport``), so the row keeps its id across a repeat lookup, and the next scan
    /// of the same code resolves locally with no network at all. Logs nothing: the caller hands the
    /// returned food to the serving step, where the user confirms before a meal exists.
    ///
    /// - Returns: The stored food, or `nil` for a blank name or a product without usable nutrition.
    func saveOpenFoodFactsFood(_ product: OpenFoodFactsProduct, named name: String) -> FoodItem? {
        guard let item = product.foodItem(named: name, verifiedAt: Date()) else { return nil }
        var items = foodItems
        let stored = OpenFoodFactsImport.upsert(item, into: &items)
        foodItems = items
        scheduleSnapshotSave()
        return stored
    }
}

#if canImport(UIKit)
import SwiftUI
import FernletUI

// MARK: - The card

/// Where the lookup card is in its one-lookup-per-tap cycle.
enum OpenFoodFactsLookupPhase: Equatable {
    /// Nothing asked yet (or the last attempt was refused for lack of consent).
    case idle
    /// A request is in flight.
    case looking
    /// Open Food Facts knows the product; `hasNutrition` says whether it had usable values.
    case found(hasNutrition: Bool)
    /// Open Food Facts has no product under this code.
    case notFound
    /// The request failed; `rateLimited` picks the calmer "busy" copy.
    case failed(rateLimited: Bool)
}

/// The "look it up online" card on the barcode not-found screen.
///
/// Offers one explicit tap per lookup — never an automatic request — and only when the
/// web-nutrition-lookup consent is granted or can be asked for. When the lane is off it explains why
/// and where to turn it on, and has no button at all. A found product is handed to `onFound`, which
/// prefills the naming screen so the screen's existing review gate runs over OFF's values; the card
/// then carries the ODbL attribution. Retries are manual and capped per visit
/// (``maxAttemptsPerVisit``), so a failing lookup cannot become a retry storm.
struct OpenFoodFactsLookupCard: View {
    var store: FernletStore
    let barcode: OpenFoodFactsBarcode
    /// Handed the product when Open Food Facts knows it, with or without nutrition.
    var onFound: (OpenFoodFactsProduct) -> Void

    @State private var phase: OpenFoodFactsLookupPhase = .idle
    @State private var attempts = 0
    @State private var showingConsent = false
    /// The single in-flight lookup; cancelled when a new one starts and when the card goes away.
    @State private var lookupTask: Task<Void, Never>?

    /// Most lookups one visit to the screen may start (the first try plus two manual retries) —
    /// well inside Open Food Facts' 15-reads-per-minute limit.
    static let maxAttemptsPerVisit = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Look it up online", systemImage: "globe")
                .font(.fernlet(.label))
                .foregroundStyle(Color.bark)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.bark.opacity(0.10), lineWidth: 1))
        .alert("Look products up online?", isPresented: $showingConsent) {
            Button("Not now", role: .cancel) { store.declineWebNutritionLookupConsent() }
            Button("Allow online lookup") {
                store.acceptWebNutritionLookupConsent()
                startLookup()
            }
        } message: {
            Text("Fernlet will send only this barcode's number to Open Food Facts, a free, open food database, and show you what it finds before anything is saved. Allowing this turns on Web nutrition lookup, which also lets a product you search for by name go to DuckDuckGo. No account, cookies or health data are sent. You can turn it off in Settings at any time, and each lookup is noted only on this device, in the AI activity log.")
        }
        // No identifier on this container: a container's `.accessibilityIdentifier` propagates DOWN
        // and overrides the button's and the attribution's own ids, which UI tests key on.
        .onDisappear(perform: stopLookup)
    }

    /// Cancels an in-flight lookup when the card leaves the screen (a pushed label scanner, a pop)
    /// and returns it to the offer, so it can never come back stuck on "Checking…". The spent
    /// attempt stays spent — the request may already have left.
    private func stopLookup() {
        lookupTask?.cancel()
        lookupTask = nil
        if phase == .looking { phase = .idle }
    }

    /// The body for the current phase.
    @ViewBuilder private var content: some View {
        switch phase {
        case .looking:
            HStack(spacing: 8) {
                ProgressView().accessibilityHidden(true)
                Text("Checking Open Food Facts…")
            }
            .font(.fernlet(.bodySmall))
            .foregroundStyle(Color.slate)
        case .found(let hasNutrition):
            foundContent(hasNutrition: hasNutrition)
        case .notFound:
            message("Open Food Facts doesn't know this barcode yet. You can still name it and scan the label below.")
        case .failed(let rateLimited):
            failedContent(rateLimited: rateLimited)
        case .idle:
            idleContent
        }
    }

    /// The offer (or, when the lane is closed, the explanation — with no button).
    @ViewBuilder private var idleContent: some View {
        switch OpenFoodFactsLookupAccess.access(for: store.settings) {
        case .permitted, .askFirst:
            message("Fernlet can check Open Food Facts, a free, open food database. Only this barcode's number is sent — nothing about you.")
            lookUpButton(title: "Check Open Food Facts")
        case .offBecauseAIOff:
            message("Looking barcodes up online needs AI features and Web nutrition lookup turned on in Settings.")
        case .off:
            message("Looking barcodes up online is off. You can turn on Web nutrition lookup in Settings.")
        }
    }

    /// What was found, and the licence notice for it.
    @ViewBuilder private func foundContent(hasNutrition: Bool) -> some View {
        if hasNutrition {
            message("Found on Open Food Facts. Check the name and macros below before you remember it — they come from a shared, community-built database.")
        } else {
            message("Open Food Facts knows this product but has no nutrition facts for it yet. Scan the label below to add them.")
        }
        // The ODbL attribution, already localized in the domain model's catalog.
        Text(verbatim: FoodItemSource.openFoodFactsAttribution)
            .font(.fernlet(.labelSmall))
            .foregroundStyle(Color.slate)
            .accessibilityIdentifier("openFoodFactsAttribution")
    }

    /// The failure line, plus a manual retry while attempts remain.
    @ViewBuilder private func failedContent(rateLimited: Bool) -> some View {
        if rateLimited {
            message("Open Food Facts is busy right now. Give it a minute, or name it yourself below.")
        } else {
            message("Couldn't reach Open Food Facts right now. You can try again, or name it yourself below.")
        }
        if attempts < Self.maxAttemptsPerVisit {
            lookUpButton(title: "Try again")
        }
    }

    /// One calm line of card copy.
    private func message(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.fernlet(.bodySmall))
            .foregroundStyle(Color.slate)
            .fernletWrappingText()
    }

    /// The single tap that starts (or asks permission for) one lookup.
    private func lookUpButton(title: LocalizedStringKey) -> some View {
        Button(action: lookUpTapped) {
            Text(title)
                .font(.fernlet(.label))
                .foregroundStyle(Color.onMoss)
                .frame(maxWidth: .infinity)
                .padding(12)
                .background(Color.moss, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("openFoodFactsLookupButton")
    }

    /// Routes a tap through the consent state: look up, ask first, or (defensively — the button is
    /// not shown then) stay put.
    private func lookUpTapped() {
        switch OpenFoodFactsLookupAccess.access(for: store.settings) {
        case .permitted: startLookup()
        case .askFirst: showingConsent = true
        case .off, .offBecauseAIOff: phase = .idle
        }
    }

    /// Starts one lookup, unless one is running or this visit's attempts are spent.
    private func startLookup() {
        guard phase != .looking, attempts < Self.maxAttemptsPerVisit else { return }
        attempts += 1
        phase = .looking
        let settings = store.settings
        let code = barcode
        lookupTask?.cancel()
        lookupTask = Task {
            let outcome = await OpenFoodFactsBarcodeLookup.run(code, settings: settings)
            guard !Task.isCancelled else { return }
            apply(outcome)
        }
    }

    /// Moves the card to the outcome's phase and hands a found product to the screen.
    private func apply(_ outcome: OpenFoodFactsLookupOutcome) {
        switch outcome {
        case .found(let product):
            phase = .found(hasNutrition: product.hasNutrition)
            onFound(product)
        case .notFound:
            phase = .notFound
        case .notPermitted:
            phase = .idle
        case .failed(let failure):
            phase = .failed(rateLimited: failure == .rateLimited)
        }
    }
}
#endif
