import Testing
import FernletDomainModel

/// The egress permit is data-modelled, not inferred from UI state: these tests cover the exact
/// predicates the app's only web-product dispatch path reads before it can construct a request.
struct WebNutritionLookupConsentTests {
    @Test func firstUseAndRejectionKeepTheWebLaneClosed() {
        var settings = FernletSettings()
        settings.aiStatus = .ready

        #expect(!settings.allowsWebNutritionLookup)
        #expect(settings.shouldOfferWebNutritionLookupConsent)

        settings.webNutritionLookupConsent = .declined
        #expect(!settings.allowsWebNutritionLookup)
        #expect(!settings.shouldOfferWebNutritionLookupConsent)
    }

    @Test func acceptancePermitsOnlyTheRequestedLaneAndRevocationClosesIt() {
        var settings = FernletSettings()
        settings.aiStatus = .ready
        settings.webNutritionLookupEnabled = true

        #expect(!settings.allowsWebNutritionLookup)

        settings.webNutritionLookupConsent = .accepted
        #expect(settings.allowsWebNutritionLookup)

        settings.webNutritionLookupEnabled = false
        settings.webNutritionLookupConsent = .revoked
        #expect(!settings.allowsWebNutritionLookup)
        #expect(!settings.shouldOfferWebNutritionLookupConsent)
    }

    @Test func legacyToggleAndFutureConsentTokenFailClosed() throws {
        let legacy = try JSONDecoder().decode(
            FernletSettings.self,
            from: Data(#"{"aiStatus":"ready","webNutritionLookupEnabled":true}"#.utf8)
        )
        #expect(legacy.webNutritionLookupConsent == .undecided)
        #expect(!legacy.allowsWebNutritionLookup)

        let future = try JSONDecoder().decode(
            FernletSettings.self,
            from: Data(#"{"aiStatus":"ready","webNutritionLookupEnabled":true,"webNutritionLookupConsent":"future"}"#.utf8)
        )
        #expect(future.unknownWebNutritionLookupConsentToken == "future")
        #expect(!future.allowsWebNutritionLookup)
    }
}
