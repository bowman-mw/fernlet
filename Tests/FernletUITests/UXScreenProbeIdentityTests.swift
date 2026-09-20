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
        for label in ["Quick log", "I'm unwell today", "May we suggest a walk", "Personal care",
                      "Augment your evening walk", "Friends", "Sunscreen"] {
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
        XCTAssertEqual(UXScreenProbe.normalisedLabel("Aug 28"), "<date-word> #",
                       "the abbreviated date chip on Move · Progress photos")
    }

    /// **The abbreviated month chip**, added 2026-09-20 — the shape that got past both halves of the
    /// wall until then.
    ///
    /// `ProgressPhotoTimeline` renders `.month(.abbreviated).day()` over a seed dated relative to
    /// the wall clock, so on any given day the three cards can straddle a month boundary and the
    /// whole set walks forward every month. With only the full month names collapsing, that was two
    /// identities today ("Aug #" and "Sep #") and a different two next month — a red on a calendar
    /// boundary that the staleness wall could not see either, because neither literal carries a
    /// digit or a full month name. All of these must key as one line.
    @MainActor
    func testAbbreviatedMonthChipsCollapseToOneIdentity() {
        let keys = Set(["Aug 9", "Aug 30", "Sep 20", "Jan 1", "Dec 31", "Sept 5"]
            .map { UXScreenProbe.normalisedLabel($0) })
        XCTAssertEqual(keys, ["<date-word> #"],
                       "abbreviated month chips must collapse to ONE identity, not one per month: \(keys)")
    }

    /// The ordering invariant inside `volatileDateWords`: full names are replaced before
    /// abbreviations, so a full name is never collapsed twice.
    ///
    /// If the abbreviations were ever moved ahead of the full names, "August 2026" would go through
    /// "Aug" first and key as "<date-word>ust #" — distinct from the abbreviated chip and from
    /// today's frozen `Home tab` entry, i.e. a silent re-key of an existing baseline line.
    @MainActor
    func testFullMonthNamesAreCollapsedBeforeTheirAbbreviations() {
        XCTAssertEqual(UXScreenProbe.normalisedLabel("August 2026"), "<date-word> #")
        XCTAssertEqual(UXScreenProbe.normalisedLabel("August 2026"),
                       UXScreenProbe.normalisedLabel("Aug 2026"),
                       "a full month name and its abbreviation must key the same")
        XCTAssertEqual(UXScreenProbe.normalisedLabel("SUNDAY, AUGUST 23"), "<date-word>, <date-word> #",
                       "the date eyebrow must not pick up a second collapse from the abbreviations")
    }

    /// **Accepted over-reach, pinned so it stays a known shape.**
    ///
    /// Substring matching plus the numeral guard means an ordinary word that contains a month
    /// abbreviation is rewritten when the label also carries a digit. It is deterministic and
    /// harmless — an identity only has to be stable, not pretty — but it is worth being able to
    /// recognise in a delta instead of treating it as corruption.
    @MainActor
    func testAbbreviationOverReachIsDeterministic() {
        XCTAssertEqual(UXScreenProbe.normalisedLabel("3 Decaf coffees"), "# <date-word>af coffees")
        XCTAssertEqual(UXScreenProbe.normalisedLabel("Decaf coffees"), "Decaf coffees",
                       "without a numeral the label is still returned byte-for-byte")
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
