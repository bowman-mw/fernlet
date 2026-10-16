// SessionMessageFilterTests.swift
// FernletTests
//
// App Review guideline 1.2 (owner decision 2026-10-15): the live-session chat's on-device send
// filter, `SessionMessageFilter`, and its one caller, `MeshSessionChat.sendTempMessage(_:)`.
//
// The shipping list's words are kept out of the repository — these tests included — so the
// matching rules are held over PLACEHOLDER words through `SessionMessageFilter.List(words:)`, the
// same code path the shipping list's digests go through, and the shipping list itself is held to
// its shape and to the words that must stay unmatched: innocent words that contain a listed word,
// and ordinary profanity, which is not on the list.

import Foundation
import Testing
import FernletDomainModel
@testable import FernletSocial
@testable import ProximityKit
@testable import Fernlet

/// The send filter: whole words, the normalization, no Scunthorpe hits, empty input, the shipping
/// list's shape, and the chat's send path refusing before anything is minted.
@Suite(.serialized) @MainActor
struct SessionMessageFilterTests {

    /// Placeholder entries: `blorp` and `zorbit` are spelled with no doubled letter; `quibble` is
    /// spelled with one, so it matches only a word that held a repeated letter.
    private static let placeholders = SessionMessageFilter.List(words: ["blorp", "zorbit", "quibble"])

    private func refused(_ text: String) -> Bool {
        SessionMessageFilter.refuses(text, list: Self.placeholders)
    }

    // MARK: - Matching

    /// Whole words only: a listed word refuses wherever it stands as a word — between spaces, at an
    /// edge, beside punctuation, either side of an apostrophe or a hyphen — and a word that merely
    /// CONTAINS it does not, nor does an unlisted plural.
    @Test func onlyWholeWordsMatch() {
        #expect(refused("blorp"))
        #expect(refused("well, blorp."))
        #expect(refused("the blorp's hat"))
        #expect(refused("re-blorp it"))
        #expect(refused("(blorp)"))
        #expect(!refused("blorpish"), "a longer word that starts with a listed one")
        #expect(!refused("unblorp"), "or ends with one")
        #expect(!refused("unblorpable"), "or holds one in the middle")
        #expect(!refused("blorps"), "a plural is its own entry, and this one is not listed")
        #expect(!refused("b lorp"), "a word split by a space is two words")
    }

    /// The normalization: case, diacritics, full-width letters, the common substitutions (`0`→o,
    /// `1`→i, `3`→e, `4`→a, `5`→s, `7`→t, `@`→a, `$`→s, `!`→i, and a leading or trailing `!` is
    /// punctuation), and runs of a repeated letter.
    @Test func caseDiacriticsSubstitutionsAndRepeatsAreUndone() {
        #expect(refused("BLORP"))
        #expect(refused("Blörp"), "a diacritic is folded")
        #expect(refused("ｂｌｏｒｐ"), "full-width letters fold to plain ones")
        #expect(refused("bl0rp"))
        #expect(refused("z0rb1t"))
        #expect(refused("z0rb!t"), "an inner `!` stands for i")
        #expect(refused("zorbit!!!"), "a trailing `!` is punctuation")
        #expect(refused("!zorbit"), "and so is a leading one")
        #expect(refused("bllooorrrp"), "runs of a repeated letter collapse")
        let substituted = SessionMessageFilter.word(from: "4bc3$5017@!")
        #expect(substituted?.form == "abcesoita" && substituted?.hadRepeatedLetter == true,
                "each substitution maps to its letter; the two `s`s are a run; the trailing `!` is dropped")
    }

    /// An entry spelled with a doubled letter matches only a word that held a repeated letter, so
    /// collapsing runs cannot fold it onto an innocent word spelled with a single letter.
    @Test func anEntryWithADoubledLetterNeedsARepeatedLetter() {
        #expect(SessionMessageFilter.entry(for: "quibble")?.needsRepeatedLetter == true)
        #expect(SessionMessageFilter.entry(for: "blorp")?.needsRepeatedLetter == false)
        #expect(refused("quibble"))
        #expect(refused("QUIBBBLE"))
        #expect(refused("quiibble"))
        #expect(refused("quiible"), "a repeated letter anywhere in the word is the elongation")
        #expect(!refused("quible"), "the single-letter spelling collapses to the same form and is not matched")
    }

    /// Empty and whitespace-only input is never refused and holds no word.
    @Test func emptyAndWhitespaceInputIsNeverRefused() {
        // R2: bounded by the literal list.
        for text in ["", " ", "   \n\t ", "\u{00A0}", "!!!"] {
            #expect(!refused(text), "`\(text)` is not refused")
            #expect(!SessionMessageFilter.refuses(text), "by the shipping list either")
        }
        #expect(SessionMessageFilter.words(in: "").isEmpty)
        #expect(SessionMessageFilter.words(in: " \n ").isEmpty)
        #expect(SessionMessageFilter.word(from: "!!!") == nil, "nothing is left of a word of `!`s")
    }

    // MARK: - The shipping list

    /// The shipping list is digests only: 26 + 20 lowercase hex SHA-256 strings, in two disjoint
    /// sets — and the digest is SHA-256 of the form's UTF-8 bytes (FIPS 180-2's "abc" vector), so
    /// `printf '%s' <form> | shasum -a 256` reproduces an entry.
    @Test func theShippingListIsDigestsOnly() {
        let list = SessionMessageFilter.List.shipping
        #expect(list.anySpelling.count == 26 && list.doubledSpelling.count == 20,
                "46 spellings, as the type's note says; a change to the list changes this cell in the same commit")
        let all = list.anySpelling.union(list.doubledSpelling)
        #expect(all.count == 46, "no digest is in both sets")
        let hex = Set("0123456789abcdef")
        #expect(all.allSatisfy { $0.count == 64 && $0.allSatisfy(hex.contains) }, "every entry is 64 lowercase hex digits")
        #expect(SessionMessageFilter.digest(of: "abc")
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    /// No Scunthorpe hits: innocent words that contain a listed word — a country, a laugh, a
    /// nation, a measure, a fire retardant, the town the problem is named for — pass the shipping
    /// list, and so does ordinary profanity and everyday identity language, which the list
    /// deliberately leaves alone.
    @Test func theShippingListLeavesInnocentWordsAndProfanityAlone() {
        let innocent = ["Niger", "Nigeria", "snigger", "Pakistan", "standard", "retardant", "tardy",
                        "Mongolia", "darkness", "Scunthorpe"]
        let profanity = ["fuck", "shit", "damn", "bitch", "bastard", "ass", "crap", "piss", "hell"]
        let identity = ["gay", "lesbian", "queer", "trans", "disabled", "Black", "Asian", "Jewish"]
        // R2: bounded by the three literal lists.
        for word in innocent + profanity + identity {
            #expect(!SessionMessageFilter.refuses("We talked about \(word) today."), "`\(word)` passes")
        }
    }

    /// `entry(for:)` is the extension tool: one word's digest and set, case-insensitive, and nil for
    /// anything that is not exactly one word.
    @Test func entryIsTheExtensionTool() {
        let entry = SessionMessageFilter.entry(for: "Blorp")
        #expect(entry?.digest == SessionMessageFilter.digest(of: "blorp"))
        #expect(entry?.digest == SessionMessageFilter.entry(for: "BLORP")?.digest)
        #expect(SessionMessageFilter.entry(for: "two words") == nil)
        #expect(SessionMessageFilter.entry(for: "") == nil)
        #expect(SessionMessageFilter.List(words: ["blorp", "quibble"])
                == SessionMessageFilter.List(
                    anySpelling: [SessionMessageFilter.digest(of: "blorp")],
                    doubledSpelling: [SessionMessageFilter.digest(of: "quible")]))
    }

    // MARK: - The send path

    /// The chat's send refuses a draft holding a listed word BEFORE anything is framed or minted:
    /// the outcome is `.filtered`, reported once, nothing is echoed, and a word hidden by an
    /// invisible scalar is still caught, because the filter reads the sanitized draft. A draft with
    /// no listed word goes on to the mint (here: no mesh, so `.noDestinations`). The panel's sentence
    /// for it is calm and its own.
    @Test func theSendPathRefusesAFilteredDraftBeforeTheMint() {
        let store = makeTestStore()
        store.ageAssurance.applyDetermination(
            lowerBound: AgeGate.chat.minimumAge, upperBound: AgeGate.intimacy.minimumAge,
            provenance: .guardianDeclared
        )
        let chat = store.meshFeatures.chat
        #expect(chat.sendFilterList == .shipping, "the app consults the shipping list")
        chat.sendFilterList = Self.placeholders
        var outcomes: [MeshTextSendOutcome] = []
        chat.onTextSendForTesting = { outcomes.append($0) }

        #expect(chat.sendTempMessage("you are such a bl0rp") == .filtered)
        #expect(chat.sendTempMessage("blo\u{200B}rp") == .filtered, "a zero-width space is sanitized away first")
        #expect(chat.sendTempMessage("see you at the blorpish place") == .noDestinations,
                "an innocent draft goes on to the mint")
        #expect(outcomes == [.filtered, .filtered, .noDestinations], "each send reported exactly once")
        #expect(chat.sessionMessages.messages.isEmpty, "a refused draft is never echoed")

        let notice = RoutedShareRefusalCopy.chatNotice(.filtered)
        #expect(notice != nil, "the refusal is said in place")
        #expect(notice != RoutedShareRefusalCopy.chatNotice(.noDestinations)
                && notice != RoutedShareRefusalCopy.chatNotice(.ageGated), "in its own sentence")
    }
}
