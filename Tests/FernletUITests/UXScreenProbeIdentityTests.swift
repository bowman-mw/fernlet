import XCTest

// MARK: - The audit ratchet's key function, tested as a pure function
//
// `UXScreenProbe.normalisedLabel(_:)` is what stops the frozen audit baseline from being a dated
// time bomb: three of the identities it keys are rendered from the clock or the demo seed, and a
// literal pinned there stops reproducing the day the date rolls while its replacement fails as an
// unrecognised appearance.
//
// It lives in the UI-test target because `identity(_:)` consumes `XCUIAccessibilityAuditIssue`,
// which cannot be constructed — so `FernletTests` can only assert on this file's *source*
// (`AuditRatchetBoundaryTests`), never on its behaviour. This is the behavioural half, and it needs
// no simulator app: nothing here launches anything.
//
// The two halves are complementary and both are required. The source wall catches "someone deleted
// the call to it"; these fixtures catch "someone changed what it does" — including the failure that
// matters most, a widened placeholder that quietly merges two genuinely different defects into one
// baseline entry.

/// Fixtures for the audit ratchet's identity normalisation.
final class UXScreenProbeIdentityTests: XCTestCase {

    /// A label with no numeral is returned byte-for-byte, including one that *mentions* a month.
    ///
    /// This is the rule that keeps the substitution off ordinary copy. "May" and "March" are
    /// ordinary English words as well as month names, and the app's copy is full of sentences; the
    /// numeral requirement is what separates a rendered date from a sentence.
    @MainActor
    func testLabelsWithoutNumeralsAreUntouched() {
        for label in ["Quick log", "I'm unwell today", "May we suggest a walk", "Personal care"] {
            XCTAssertEqual(UXScreenProbe.normalisedLabel(label), label,
                           "a label with no numeral must survive normalisation unchanged")
        }
    }

    /// The three shapes that actually appear in the frozen baseline, which are the reason this
    /// function exists.
    @MainActor
    func testWallClockAndSeedDerivedLabelsNormalise() {
        XCTAssertEqual(UXScreenProbe.normalisedLabel("SUNDAY, AUGUST 23"), "<date-word>, <date-word> #")
        XCTAssertEqual(UXScreenProbe.normalisedLabel("August 2026"), "<date-word> #")
        XCTAssertEqual(UXScreenProbe.normalisedLabel("2 entries"), "# entries")
        XCTAssertEqual(UXScreenProbe.normalisedLabel("2 of 8"), "# of #")
    }

    /// Tomorrow, next month and a re-seeded demo must all produce the SAME key as today's.
    ///
    /// The single assertion this whole file exists for: if these ever stop being equal, the wall
    /// goes red on a calendar boundary rather than on an accessibility regression.
    @MainActor
    func testDatesThatDifferOnlyByWhenTheyWereRenderedShareOneIdentity() {
        let today = UXScreenProbe.normalisedLabel("SUNDAY, AUGUST 23")
        for later in ["MONDAY, AUGUST 24", "TUESDAY, SEPTEMBER 1", "FRIDAY, JANUARY 2"] {
            XCTAssertEqual(UXScreenProbe.normalisedLabel(later), today,
                           "\(later) must key the same as today's date eyebrow")
        }
        XCTAssertEqual(UXScreenProbe.normalisedLabel("September 2026"),
                       UXScreenProbe.normalisedLabel("August 2026"))
        XCTAssertEqual(UXScreenProbe.normalisedLabel("7 entries"),
                       UXScreenProbe.normalisedLabel("2 entries"),
                       "a re-seeded count must not mint a new identity")
    }

    /// **The collapse guard.** Distinct labels must stay distinct after normalisation.
    ///
    /// Normalising the 136 harvested identities yielded 135 — one benign merge, Home's "1 logged"
    /// and "3 logged", which are the same `QuickLogButton` component rendered twice. That merge is
    /// asserted here so it stays the *only* one: everything below differs by something other than a
    /// numeral, and if a future widening of the placeholder starts merging these, a real defect
    /// would be able to hide behind a fixed one.
    @MainActor
    func testDistinctLabelsStayDistinct() {
        let distinct = ["2 entries", "2 of 8", "6 bottles", "8h", "Shed · 22 items",
                        "Care score 90 percent", "0g", "Log at least 3 cycles to see predictions."]
        let keys = Set(distinct.map { UXScreenProbe.normalisedLabel($0) })
        XCTAssertEqual(keys.count, distinct.count,
                       "normalisation merged two labels that describe different elements: \(keys)")

        XCTAssertEqual(UXScreenProbe.normalisedLabel("1 logged"),
                       UXScreenProbe.normalisedLabel("3 logged"),
                       """
                       The one deliberate merge in the baseline. Both are QuickLogButton tiles \
                       differing only by a seeded count, so they are two instances of one defect. \
                       If this assertion is what broke, the baseline needs re-harvesting.
                       """)
    }

    /// Digits are collapsed per RUN, not per digit — otherwise "2026" would key differently from
    /// "26" and the month title would still move every year.
    @MainActor
    func testEachRunOfDigitsCollapsesToOnePlaceholder() {
        XCTAssertEqual(UXScreenProbe.normalisedLabel("Roast at 425 for 25 minutes"),
                       "Roast at # for # minutes")
        XCTAssertEqual(UXScreenProbe.normalisedLabel("1999"), "#")
    }
}
