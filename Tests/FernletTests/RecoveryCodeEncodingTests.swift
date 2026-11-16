// RecoveryCodeEncodingTests.swift
// FernletTests
//
// G9-2: the recovery code's BIP39 encoding (plan Part 2, "Tests"): the published 12-word BIP39
// English vectors both ways, the checksum, 4-letter prefixes, case and spacing, and the word list
// itself pinned to the published file.

import CryptoKit
import Foundation
import Testing
@testable import FernletCrypto

/// The recovery code's encoding: 128 bits ↔ 12 BIP39 English words with the 4-bit checksum.
struct RecoveryCodeEncodingTests {

    /// The 128-bit vectors of the BIP39 reference set (trezor/python-mnemonic `vectors.json`,
    /// `english`), entropy hex → mnemonic. Only the mnemonic column is used: Fernlet never derives
    /// BIP39's PBKDF2 seed.
    static let vectors: [(entropy: String, words: String)] = [
        ("00000000000000000000000000000000", "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"),
        ("7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f", "legal winner thank year wave sausage worth useful legal winner thank yellow"),
        ("80808080808080808080808080808080", "letter advice cage absurd amount doctor acoustic avoid letter advice cage above"),
        ("ffffffffffffffffffffffffffffffff", "zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo wrong"),
        ("9e885d952ad362caeb4efe34a8e91bd2", "ozone drill grab fiber curtain grace pudding thank cruise elder eight picnic"),
        ("c0ba5a8e914111210f2bd131f3d5e08d", "scheme spot photo card baby mountain device kick cradle pact join borrow"),
        ("23db8160a31d3e0dca3688ed941adbf3", "cat swing flag economy stadium alone churn speed unique patch report train"),
        ("f30f8c1da665478f49b001d94c5fc452", "vessel ladder alter error federal sibling chat ability sun glass valve picture")
    ]

    @Test(arguments: vectors.indices)
    func encodesEachBIP39Vector(_ index: Int) throws {
        let vector = Self.vectors[index]
        let code = try RecoveryCode(entropy: Self.data(hex: vector.entropy))
        #expect(code.words.joined(separator: " ") == vector.words)
        #expect(code.words.count == RecoveryCode.wordCount)
    }

    @Test(arguments: vectors.indices)
    func decodesEachBIP39Vector(_ index: Int) throws {
        let vector = Self.vectors[index]
        #expect(try RecoveryCode(typing: vector.words).entropy == Self.data(hex: vector.entropy))
    }

    @Test func aRandomCodeRoundTripsThroughItsWords() throws {
        for _ in 0..<32 {
            let code = try RecoveryCode.generate()
            #expect(code.entropy.count == RecoveryCode.entropyByteCount)
            #expect(try RecoveryCode(typing: code.words.joined(separator: " ")) == code)
        }
    }

    // MARK: Checksum

    @Test func aRealWordInTheWrongPlaceFailsTheChecksum() {
        // Twelve real words, but the last is "abandon" where the checksum needs "about".
        let typed = Array(repeating: "abandon", count: 12).joined(separator: " ")
        #expect(throws: RecoveryCodeError.checksumMismatch) { try RecoveryCode(typing: typed) }
    }

    @Test func swappingTwoWordsIsCaught() {
        // "legal winner …" with words 1 and 2 swapped: same words, wrong order.
        let typed = "winner legal thank year wave sausage worth useful legal winner thank yellow"
        #expect(throws: RecoveryCodeError.checksumMismatch) { try RecoveryCode(typing: typed) }
    }

    // MARK: Typing

    @Test func caseSpacingCommasAndNumberingAreIgnored() throws {
        let typed = "  1. LEGAL, 2) Winner\n3. thank  year\twave; sausage 7 worth useful legal winner thank yellow  "
        #expect(try RecoveryCode(typing: typed).entropy == Self.data(hex: "7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f"))
    }

    @Test func fourLetterPrefixesAreEnough() throws {
        let typed = "lega winn than year wave saus wort usef lega winn than yell"
        #expect(try RecoveryCode(typing: typed).entropy == Self.data(hex: "7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f"))
    }

    @Test func aPrefixLongerThanFourMustStillBeAPrefix() throws {
        #expect(try RecoveryCode(typing: "legal winn thank year wave sausa worth useful legal winner thank yellow").entropy
                == Self.data(hex: "7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f"))
        // "sausga" shares "saus" with "sausage" but is not a prefix of it: named, not guessed.
        #expect(throws: RecoveryCodeError.unknownWord(position: 6)) {
            try RecoveryCode(typing: "legal winner thank year wave sausga worth useful legal winner thank yellow")
        }
    }

    @Test func threeLetterPrefixesAreRefused() {
        #expect(throws: RecoveryCodeError.unknownWord(position: 1)) {
            // "tha" is three letters of "thank" and no word itself ("leg" and "win" are words).
            try RecoveryCode(typing: "tha winner thank year wave sausage worth useful legal winner thank yellow")
        }
    }

    @Test func aMisspeltWordIsNamedByPosition() {
        #expect(throws: RecoveryCodeError.unknownWord(position: 5)) {
            try RecoveryCode(typing: "abandon abandon abandon abandon abandn abandon abandon abandon abandon abandon abandon about")
        }
    }

    @Test func theWrongNumberOfWordsIsCounted() {
        #expect(throws: RecoveryCodeError.wrongWordCount(11)) {
            try RecoveryCode(typing: "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about")
        }
        #expect(throws: RecoveryCodeError.wrongWordCount(0)) { try RecoveryCode(typing: "  \n ") }
        #expect(throws: RecoveryCodeError.wrongWordCount(64)) {
            try RecoveryCode(typing: Array(repeating: "zoo", count: 500).joined(separator: " "))
        }
    }

    @Test func entropyOfTheWrongLengthIsRefused() {
        #expect(throws: RecoveryCodeError.wrongEntropyLength) { try RecoveryCode(entropy: Data(count: 15)) }
        #expect(throws: RecoveryCodeError.wrongEntropyLength) { try RecoveryCode(entropy: Data(count: 32)) }
    }

    // MARK: The list

    @Test func theWordListIsThePublishedBIP39EnglishList() {
        let list = RecoveryCodeWordList.english
        #expect(list.count == 2_048)
        let file = Data((list.joined(separator: "\n") + "\n").utf8)
        let hash = SHA256.hash(data: file).map { String(format: "%02x", $0) }.joined()
        #expect(hash == RecoveryCodeWordList.publishedSHA256)
        #expect(hash == "2f5eed53a4727b4bf8880d8f3f199efc90e58503646d9ff8eff3a2ed3b24dbda")
    }

    @Test func everyWordIsUniqueByItsFirstFourLetters() {
        let prefixes = RecoveryCodeWordList.english.map { String($0.prefix(RecoveryCode.identifyingPrefixLength)) }
        #expect(Set(prefixes).count == RecoveryCodeWordList.english.count)
    }

    // MARK: Helpers

    static func data(hex: String) -> Data {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        return Data(bytes)
    }
}
