import Foundation
import Testing
import FernletDomainModel

/// Covers the shared free-text number parser behind every decimal field in the app.
///
/// The bug it exists for: iOS shows `.decimalPad` with the *locale's* separator, so es/fr/de users
/// type `"2,5"`, and bare `Double("2,5")` is nil — the value was silently dropped. The cases below
/// pin both spellings, the grouped forms, the ambiguous `"1,500"` split, and the charset guard
/// that keeps `Double(_:)`'s hex/inf/nan spellings out of clinical samples and macro totals.
struct LocaleTolerantNumberTests {
    private let en = Locale(identifier: "en_US")
    private let de = Locale(identifier: "de_DE")
    private let fr = Locale(identifier: "fr_FR")
    private let es = Locale(identifier: "es_ES")

    // MARK: - Either separator, either locale

    @Test func acceptsTheLocalesOwnDecimalSeparator() {
        #expect(LocaleTolerantNumber.double(from: "2.5", locale: en) == 2.5)
        #expect(LocaleTolerantNumber.double(from: "2,5", locale: de) == 2.5)
        #expect(LocaleTolerantNumber.double(from: "2,5", locale: fr) == 2.5)
        #expect(LocaleTolerantNumber.double(from: "2,5", locale: es) == 2.5)
    }

    @Test func acceptsTheOtherLocalesSeparatorToo() {
        // A paste, a hardware keyboard, or muscle memory from a previous phone.
        #expect(LocaleTolerantNumber.double(from: "2,5", locale: en) == 2.5)
        #expect(LocaleTolerantNumber.double(from: "2.5", locale: de) == 2.5)
    }

    @Test func parsesBothGroupedSpellings() {
        #expect(LocaleTolerantNumber.double(from: "1,234.5", locale: en) == 1234.5)
        #expect(LocaleTolerantNumber.double(from: "1.234,5", locale: de) == 1234.5)
        #expect(LocaleTolerantNumber.double(from: "1.234.567", locale: de) == 1234567)
    }

    @Test func stripsGroupingWhitespaceAndApostrophes() {
        // fr groups with a narrow no-break space; de-CH with an apostrophe (either spelling).
        #expect(LocaleTolerantNumber.double(from: "1\u{202F}234,5", locale: fr) == 1234.5)
        #expect(LocaleTolerantNumber.double(from: "1'234.5", locale: Locale(identifier: "de_CH")) == 1234.5)
        #expect(LocaleTolerantNumber.double(from: "1\u{2019}234.5", locale: Locale(identifier: "de_CH")) == 1234.5)
        #expect(LocaleTolerantNumber.double(from: " 62,5 ", locale: de) == 62.5)
    }

    // MARK: - The ambiguous case

    @Test func lonelySeparatorWithThreeDigitsFollowsTheLocale() {
        // "1,500" is 1500 to an American and 1.5 to a German. Only here does the locale decide.
        #expect(LocaleTolerantNumber.double(from: "1,500", locale: en) == 1500)
        #expect(LocaleTolerantNumber.double(from: "1,500", locale: de) == 1.5)
        #expect(LocaleTolerantNumber.double(from: "1.500", locale: de) == 1500)
        #expect(LocaleTolerantNumber.double(from: "1.500", locale: en) == 1.5)
    }

    @Test func lonelySeparatorWithOtherWidthsIsAlwaysDecimal() {
        #expect(LocaleTolerantNumber.double(from: "12,34", locale: en) == 12.34)
        #expect(LocaleTolerantNumber.double(from: "1,2345", locale: en) == 1.2345)
        // Three digits *and* a valid group width — grouped, per the rule above.
        #expect(LocaleTolerantNumber.double(from: "12,345", locale: en) == 12345)
    }

    // MARK: - Guards

    @Test func rejectsTheSpellingsBareDoubleWouldAccept() {
        // R5: these reach `Double(_:)` intact and would become a non-finite clinical sample or a
        // macro total that makes the day snapshot's JSONEncoder throw.
        #expect(LocaleTolerantNumber.double(from: "0x1p3", locale: en) == nil)
        #expect(LocaleTolerantNumber.double(from: "inf", locale: en) == nil)
        #expect(LocaleTolerantNumber.double(from: "nan", locale: en) == nil)
        #expect(LocaleTolerantNumber.double(from: "1e400", locale: en) == nil)
    }

    @Test func rejectsMalformedInput() {
        #expect(LocaleTolerantNumber.double(from: "", locale: en) == nil)
        #expect(LocaleTolerantNumber.double(from: ",", locale: de) == nil)
        #expect(LocaleTolerantNumber.double(from: "12kg", locale: en) == nil)
        #expect(LocaleTolerantNumber.double(from: "2,5.5", locale: de) == nil)
    }

    @Test func rejectsMalformedGroupingRatherThanInventingANumber() {
        // Dropping separators blindly would read the typo "1,2,3" as 123 and log it silently.
        #expect(LocaleTolerantNumber.double(from: "1,2,3", locale: de) == nil)
        #expect(LocaleTolerantNumber.double(from: "1,23,456", locale: en) == nil)
    }

    @Test func boundsTheInputItWillScan() {
        let overlong = String(repeating: "9", count: LocaleTolerantNumber.maxInputCharacters + 1)
        #expect(LocaleTolerantNumber.double(from: overlong, locale: en) == nil)
    }

    @Test func handlesSignsAndBareSeparators() {
        #expect(LocaleTolerantNumber.double(from: "-3,25", locale: de) == -3.25)
        #expect(LocaleTolerantNumber.double(from: "+7", locale: en) == 7)
        #expect(LocaleTolerantNumber.double(from: ".5", locale: en) == 0.5)
        #expect(LocaleTolerantNumber.double(from: "5.", locale: en) == 5)
    }

    // MARK: - Integers

    @Test func integerParsingAcceptsGroupingAndRefusesFractions() {
        #expect(LocaleTolerantNumber.int(from: "12", locale: en) == 12)
        #expect(LocaleTolerantNumber.int(from: "1.500", locale: de) == 1500)
        // Matches what the bare `Int(_:)` call sites this replaced already did — never rounds.
        #expect(LocaleTolerantNumber.int(from: "12.5", locale: en) == nil)
        #expect(LocaleTolerantNumber.int(from: "12,5", locale: de) == nil)
    }
}
