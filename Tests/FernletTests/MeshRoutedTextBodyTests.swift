// MeshRoutedTextBodyTests.swift
// FernletTests
//
// Network migration P6 item 4 (plan §12): the routed TEXT body — its frozen framing, its FOUR
// hostile shapes, and the cap formula the registry row is defined as.
//
// A body is sealed content inside an existing frame family, not a frame: `AEAD.meshRoutedItemV1`
// already has its crypto-domain row and an AEAD purpose never reaches `signingBytes(_:)`, so this
// owes a **golden only** — no new domain row, no framing-transcript case, no wire trio. That
// non-change is asserted in `MeshRoutedItemSealTests.theItemSealAddsNoSignatureFramingAndNoDomainRow`
// (75 domains, unmoved) rather than restated here.
//
// The fourth hostile shape is text's own and is the one a copy of `MeshRoutedPhotoBody.init(decoding:)`
// gets wrong: `String(decoding:as:)` cannot fail — it substitutes U+FFFD, which is neither a control
// character nor in `SessionMessageStore.sanitize`'s invisible-scalar list — so the tempting spelling
// admits arbitrary bytes as replacement characters and displays them.

@testable import ProximityKit
import Foundation
import Testing

@Suite(.serialized)
struct MeshRoutedTextBodyTests {

    /// The routed text body's frozen framing: `u64BE(95) ‖ headerJSON ‖ "hello there 👋"`,
    /// 119 bytes. Derived from the FORMAT (sorted keys, unescaped slashes, `.secondsSince1970`),
    /// independently of the encoder under test, and an INDEPENDENT new pin — never an edit to
    /// `goldenBodyHex`, which is the photo family's.
    static let goldenTextBodyHex = "000000000000005f7b226964223a2235413541354135412d364236422d344334432d384438442d334533453345334533453345222c2273656e6465724e616d65223a2246697874757265204f726967696e222c2273656e744174223a313730303030303438307d68656c6c6f20746865726520f09f918b"

    /// The golden text: multi-byte on purpose, so the raw-UTF-8 payload half is pinned rather than
    /// assumed from ASCII.
    static let goldenText = "hello there 👋"

    /// The golden header: item 1's item id, `base + 480`, the same fixed name the photo fixture uses.
    static func header() -> MeshRoutedTextHeader {
        MeshRoutedTextHeader(
            id: MeshRoutedManifestFixtures.itemID,
            sentAt: Date(timeIntervalSince1970: 1_700_000_480),
            senderName: "Fixture Origin"
        )
    }

    /// The golden body.
    static func body() -> MeshRoutedTextBody {
        MeshRoutedTextBody(header: header(), text: goldenText)
    }

    // MARK: - Framing

    @Test func theRoutedTextBodyRoundTrips() throws {
        let encoded = try Self.body().encoded()
        let decoded = try MeshRoutedTextBody(decoding: encoded)
        #expect(decoded == Self.body())
        #expect(decoded.text == Self.goldenText, "the payload is raw UTF-8, unescaped and unmangled")
    }

    @Test func theRoutedTextBodyGoldenIsPinned() throws {
        let actual = MeshRoutedItemSealFixtures.hex(try Self.body().encoded())
        #expect(actual == Self.goldenTextBodyHex, "actual routed text body golden hex = \(actual)")
        #expect(actual.count == 119 * 2)
    }

    @Test func theTextBodyRoundTripsFromItsGoldenBytes() throws {
        let decoded = try MeshRoutedTextBody(
            decoding: MeshRoutedItemSealFixtures.bytes(fromHex: Self.goldenTextBodyHex)
        )
        #expect(decoded == Self.body())
    }

    /// The photo family's golden is UNMOVED: a second body family in the same file must add a pin,
    /// never edit one (the `91c3956` lesson — never re-pin a golden).
    @Test func thePhotoBodyGoldenIsUnmovedByTheTextFamily() throws {
        let actual = MeshRoutedItemSealFixtures.hex(try MeshRoutedItemSealFixtures.body().encoded())
        #expect(actual == MeshRoutedItemSealGoldenTests.goldenBodyHex)
    }

    // MARK: - The four hostile shapes, all on the one frozen token

    @Test func aTooShortTextBodyIsMalformed() {
        #expect(throws: MeshRoutedItemSealError.malformed) {
            _ = try MeshRoutedTextBody(decoding: Data([0, 0, 0]))
        }
    }

    @Test func aTextHeaderLengthPastTheEndIsMalformed() {
        var bytes = Data([0, 0, 0, 0, 0, 0, 0, 0xFF])
        bytes.append(Data("short".utf8))
        #expect(throws: MeshRoutedItemSealError.malformed) {
            _ = try MeshRoutedTextBody(decoding: bytes)
        }
    }

    @Test func anInBoundsSliceThatIsNotTheTextHeaderIsMalformed() {
        let junk = Data("not json at all".utf8)
        var bytes = Data()
        // R2: fixed width.
        for shift in stride(from: 56, through: 0, by: -8) {
            bytes.append(UInt8(truncatingIfNeeded: UInt64(junk.count) >> UInt64(shift)))
        }
        bytes.append(junk)
        #expect(throws: MeshRoutedItemSealError.malformed) {
            _ = try MeshRoutedTextBody(decoding: bytes)
        }
    }

    /// Text's OWN fourth shape. `String(decoding:as: UTF8.self)` would silently substitute U+FFFD
    /// here and hand the transcript arbitrary bytes as replacement characters. Refuse, do not repair.
    @Test func aTextPayloadThatIsNotUTF8IsMalformed() throws {
        let headerJSON = try MeshRoutedItemBodyFormat.headerEncoder().encode(Self.header())
        var writer = CanonicalByteWriter()
        writer.appendLengthPrefixed(headerJSON)
        // A lone continuation byte and a truncated four-byte sequence: not valid UTF-8 in any
        // position, and both of them survive `String(decoding:as:)` as U+FFFD.
        let invalid = writer.bytes + Data([0x80, 0xF0, 0x9F])
        #expect(throws: MeshRoutedItemSealError.malformed) {
            _ = try MeshRoutedTextBody(decoding: invalid)
        }
    }

    /// The negative control for the shape above, so the cell cannot be satisfied by refusing
    /// non-ASCII: a replacement character the ORIGIN honestly typed is well-formed UTF-8 and is
    /// carried, not refused.
    @Test func aReplacementCharacterInHonestTextIsNotRefused() throws {
        let honest = MeshRoutedTextBody(header: Self.header(), text: "what is this \u{FFFD}")
        let decoded = try MeshRoutedTextBody(decoding: try honest.encoded())
        #expect(decoded.text == "what is this \u{FFFD}")
    }

    // MARK: - The cap formula

    /// The registry row is defined AS the constant, and the constant is a formula over the three
    /// terms that own their own numbers (P6 item 3's idiom). 8 000 + 1 032 + 33 = 9 065.
    @Test func theTextRowsCapIsTheSanitizedMaximumsCiphertextBound() throws {
        #expect(MeshRoutedTextBody.maxTextUTF8ByteCount == 16 * SessionMessageStore.maxTextLength)
        #expect(MeshRoutedItemBodyFormat.maxFramedTextHeaderByteCount
                    == MeshRoutedItemBodyFormat.headerLengthPrefixByteCount
                        + MeshRoutedItemBodyFormat.maxTextHeaderJSONByteCount)
        #expect(MeshRoutedTextBody.maxSealedBlobByteCount
                    == MeshRoutedTextBody.maxTextUTF8ByteCount
                        + MeshRoutedItemBodyFormat.maxFramedTextHeaderByteCount
                        + MeshRoutedItemSealFormat.overheadByteCount)
        #expect(MeshRoutedTextBody.maxSealedBlobByteCount == 9_065,
                "the formula's value, stated once so a term that moves is visible")

        let entry = try #require(
            MeshRoutedTypeRegistry.increment1.entry(for: MeshRoutedTypeToken.tempMessage),
            "the narrowed row must still be REGISTERED: the registry init DROPS a row whose cap is outside the wire bound, and a dropped row fails closed at every door with no compile error"
        )
        #expect(entry.maxItemByteCount == UInt64(MeshRoutedTextBody.maxSealedBlobByteCount))
        #expect(entry.canonicalStore == .sessionTranscript)
        #expect(entry.maxItemByteCount < MeshRoutedItemSealFormat.maxResidentBlobByteCount,
                "and it really is NARROWER than the shared resident bound — otherwise it is not a cap")
    }

    /// The narrowed header allowance covers a maximal well-formed header with room to spare — the
    /// photo header's measured claim, against a text fixture of its own and at a **4× floor**.
    ///
    /// 4× rather than 8× is a fact about the two headers. The photo header's dominant term is a
    /// gossiped list of up to 32 participant names that arrive from peers, so its allowance has to
    /// absorb growth this build does not control; a text header is a UUID, a date and ONE display
    /// name whose byte bound `MeshRoutedTextBody.maxSenderNameUTF8ByteCount` sets. The floor is a
    /// floor, not the measured multiple, so an honest field can grow without a test edit.
    @Test func theTextHeaderAllowanceCoversAMaximalHeader() throws {
        let maximal = MeshRoutedTextHeader(
            id: MeshRoutedManifestFixtures.itemID,
            sentAt: Date(timeIntervalSince1970: 1_700_000_480),
            senderName: MeshRoutedTextBody.boundedSenderName(String(repeating: "🇫🇷", count: 32))
        )
        let measured = try MeshRoutedItemBodyFormat.headerEncoder().encode(maximal).count
        #expect(measured * 4 <= MeshRoutedItemBodyFormat.maxTextHeaderJSONByteCount,
                "a maximal text header measures \(measured) B against a \(MeshRoutedItemBodyFormat.maxTextHeaderJSONByteCount) B allowance")
        #expect(maximal.senderName.utf8.count <= MeshRoutedTextBody.maxSenderNameUTF8ByteCount,
                "and the one variable-length field really is bounded before it is framed")
    }

    /// A maximal MESSAGE seals inside the row's cap, and one byte above the payload bound does not.
    /// Both directions, because item 3's review found that asserting only the over-cap refusal
    /// leaves the `<=` boundary unpinned.
    @Test func aTextAtTheCapIsAdmittedAndOneByteAboveIsRefused() throws {
        let atBound = String(repeating: "a", count: MeshRoutedTextBody.maxTextUTF8ByteCount)
        let sealedSize = try MeshRoutedTextBody(header: Self.header(), text: atBound).encoded().count
            + MeshRoutedItemSealFormat.overheadByteCount
        #expect(sealedSize <= MeshRoutedTextBody.maxSealedBlobByteCount,
                "the widest honest message seals INSIDE the cap the manifest door checks")

        #expect(MeshRoutedTextBody.boundedText(atBound) == atBound, "and is not trimmed")
        let overBound = atBound + "a"
        #expect(MeshRoutedTextBody.boundedText(overBound).utf8.count
                    == MeshRoutedTextBody.maxTextUTF8ByteCount,
                "while one byte above it is trimmed back to the bound")
    }

    /// `boundedText` drops whole `Character`s, which is the whole point — and can therefore empty a
    /// message the product's 500-`Character` cap admitted. The sender re-checks; this pins the
    /// mechanism that makes the re-check necessary.
    @Test func boundedTextIsCharacterAlignedAndCanEmptyAMessage() {
        let flood = "a" + String(repeating: "\u{0301}", count: 4_000)
        #expect(flood.count == 1, "one grapheme cluster")
        #expect(flood.utf8.count > MeshRoutedTextBody.maxTextUTF8ByteCount)
        #expect(MeshRoutedTextBody.boundedText(flood).isEmpty, """
            there is no prefix of ONE Character that fits, so the bound empties it — which is why \
            `sendTempMessage` guards emptiness AFTER this and answers `.empty`
            """)

        let flag = String(repeating: "🇫🇷", count: 2_000)
        let bounded = MeshRoutedTextBody.boundedText(flag)
        #expect(bounded.utf8.count <= MeshRoutedTextBody.maxTextUTF8ByteCount)
        #expect(bounded.unicodeScalars.count % 2 == 0,
                "and a regional-indicator pair is never split in half")
    }

    @Test func theSenderNameIsByteBoundedToo() {
        let long = String(repeating: "🇫🇷", count: 500)
        let bounded = MeshRoutedTextBody.boundedSenderName(long)
        #expect(bounded.utf8.count <= MeshRoutedTextBody.maxSenderNameUTF8ByteCount)
        #expect(!bounded.isEmpty)
    }

    // MARK: - The epoch wall's own claim, for the new file

    /// The routed text body names no epoch, group key, branch or partition symbol — the same
    /// precondition `theRoutedPathNamesNoEpochSymbol` states for the manager's routed sections,
    /// asserted for the file the body lives in because an epoch inside a routed body would put
    /// back exactly what P5 item 13 retired.
    @Test func theRoutedTextBodyNamesNoEpoch() throws {
        let source = MeshRoutedSourceScan.codeOnly(
            try RepoRoot.source("FernletKit/Sources/ProximityKit/Mesh/MeshRoutedItemBody.swift")
        )
        for forbidden in ["keyEpoch", "currentGroupKey", "branchView", "partition"] {
            #expect(!source.contains(forbidden), "the routed body names \(forbidden)")
        }
    }
}
