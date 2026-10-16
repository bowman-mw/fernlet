// SessionMessageFilter.swift
// FernletSocial/Messaging
//
// App Review guideline 1.2 (2026-10-15, owner decision "Report + a small filter", all on device):
// the live-session chat's send filter. A message holding a word from a short list of slurs is not
// sent; the chat's `sendTempMessage(_:)` answers `MeshTextSendOutcome.filtered` before anything is
// framed or minted, and the panel says so in place with the draft kept. The list is stored as
// SHA-256 digests because the repository is public.

import CryptoKit
import Foundation

/// The live-session chat's on-device send filter: whether a draft holds a word from a short list
/// of slurs, which ``MeshSessionChat/sendTempMessage(_:)`` then refuses to send
/// (``MeshTextSendOutcome/filtered``) before the text is framed, minted or reaches the mesh.
///
/// **What the list is.** A deliberately SMALL list of widely recognized English slurs — racial and
/// ethnic, homophobic and transphobic, and ableist — each with its plural (46 spellings of 21
/// words). It is kept to words with no common innocent meaning: a word that also has an everyday
/// innocent sense is left off, and ordinary profanity is never on it. The filter is a floor under App Review guideline 1.2 ("a method for
/// filtering objectionable material"), not a moderation system: the person on the other end can
/// always Report a message, which blocks its sender on their device.
///
/// **Why digests.** The repository is public, so the words are not written anywhere in it. Each
/// entry is the lowercase hex SHA-256 of a word's *matching form* (``word(from:)``), and a word of a
/// draft matches an entry when its own matching form hashes to the same digest.
///
/// **How a word matches — whole words only, after normalization.** The draft is NFKC-folded (so
/// full-width and styled letters read as plain ones), case-folded and diacritic-folded, then split
/// into words at every scalar that is not a letter, a digit or one of the substitution symbols
/// `@ $ !`. In each word a leading or trailing `!` is dropped (it is punctuation there), the common
/// substitutions are undone (`0`→o, `1`→i, `3`→e, `4`→a, `5`→s, `7`→t, `@`→a, `$`→s, `!`→i), and
/// every run of a repeated letter is collapsed to one letter. Matching whole words is what keeps
/// an innocent word that CONTAINS a listed word from matching (the Scunthorpe problem; the tests
/// hold a handful). Collapsing runs is what catches an elongated spelling; it would also fold an
/// entry spelled with a doubled letter onto an innocent word spelled without one (a place name, for
/// one), so such an entry is kept in ``List/doubledSpelling`` and matches only a word that held a
/// repeated letter too.
///
/// **What it does not do.** Received messages are NOT filtered: the sender's own device filters
/// (this type, on the send path), and the receiver can Report the message, which blocks its sender
/// — a receive-side filter would hide content from the one person able to report it. Letters spaced
/// out or split by other symbols, look-alike letters from other scripts and words in other
/// languages are not caught. Nothing is logged when a draft is refused: a line saying a person typed
/// a listed word would itself be a record about them, and the refusal is returned to the panel.
///
/// **How to extend it.** Add each spelling (a plural is its own entry): compute
/// ``entry(for:)`` for the word in a scratch test or a playground and put its `digest` into
/// ``List/doubledSpelling`` when `needsRepeatedLetter` is true, else into ``List/anySpelling`` —
/// by hand, `printf '%s' <form> | shasum -a 256` over the matching form gives the same digest. Keep
/// both sets sorted, and keep the plaintext out of the repository, its tests and its commit
/// messages. `SessionMessageFilterTests` pins the list's shape and the words that must stay
/// unmatched; run it after any change.
///
/// Concurrency: a stateless `nonisolated` namespace over immutable `Sendable` values, callable from
/// any actor.
nonisolated enum SessionMessageFilter {

    /// One list of digests, in two sets by how an entry matches. ``shipping`` is the one the send
    /// path consults; tests build their own from placeholder words (``init(words:)``).
    ///
    /// Concurrency: an immutable `Sendable` value.
    struct List: Equatable, Sendable {
        /// Digests of entries spelled with no doubled letter: any word whose matching form hashes
        /// here matches.
        let anySpelling: Set<String>
        /// Digests of entries whose own spelling holds a doubled letter: a word matches only when it
        /// held a repeated letter too, so a word collapsing onto an innocent spelling does not.
        let doubledSpelling: Set<String>

        /// A list over the given digests.
        ///
        /// - Parameters:
        ///   - anySpelling: Digests matched by any word.
        ///   - doubledSpelling: Digests matched only by a word that held a repeated letter.
        init(anySpelling: Set<String>, doubledSpelling: Set<String>) {
            self.anySpelling = anySpelling
            self.doubledSpelling = doubledSpelling
        }

        /// A list built from plaintext words through ``SessionMessageFilter/entry(for:)`` — for tests'
        /// placeholder words, never for the shipping list, whose words are kept out of the
        /// repository. A word with no matching form is skipped.
        ///
        /// - Parameter words: The words to list.
        init(words: [String]) {
            let entries = words.compactMap(SessionMessageFilter.entry(for:))
            self.init(
                anySpelling: Set(entries.filter { !$0.needsRepeatedLetter }.map(\.digest)),
                doubledSpelling: Set(entries.filter(\.needsRepeatedLetter).map(\.digest))
            )
        }

        /// Whether `word` matches an entry of this list.
        ///
        /// - Parameter word: One word of a draft, in its matching form.
        /// - Returns: true when its digest is listed in a set it may match.
        func contains(_ word: Word) -> Bool {
            guard !word.form.isEmpty else { return false }
            let digest = SessionMessageFilter.digest(of: word.form)
            return anySpelling.contains(digest) || (word.hadRepeatedLetter && doubledSpelling.contains(digest))
        }
    }

    /// One word of a draft in its matching form, and whether it held a repeated letter before the
    /// runs were collapsed.
    ///
    /// Concurrency: an immutable `Sendable` value.
    struct Word: Equatable, Sendable {
        /// The normalized, substituted, run-collapsed spelling the digest is taken over.
        let form: String
        /// Whether a run of one repeated letter was collapsed to make ``form``.
        let hadRepeatedLetter: Bool
    }

    /// The most scalars of a draft the filter reads: eight times the chat's 500-`Character` cap,
    /// well past what NFKC folding makes of any honest message (R3: the scan is bounded even if a
    /// caller hands in unsanitized text).
    static let maxScannedScalars = SessionMessageStore.maxTextLength * 8

    /// The common character substitutions, undone before matching.
    private static let substitutions: [Character: Character] = [
        "0": "o", "1": "i", "3": "e", "4": "a", "5": "s", "7": "t", "@": "a", "$": "s", "!": "i"
    ]

    /// The non-alphanumeric scalars that stay inside a word, because they stand for a letter.
    private static let substitutionSymbols = CharacterSet(charactersIn: "@$!")

    /// Whether `text` holds a word from `list`.
    ///
    /// - Parameters:
    ///   - text: The draft, as the chat sanitized it.
    ///   - list: The list to match against; the shipping one unless a test passes its own.
    /// - Returns: true when the draft must not be sent. Empty and whitespace-only text answers false.
    static func refuses(_ text: String, list: List = .shipping) -> Bool {
        guard !text.isEmpty else { return false }
        return words(in: text).contains { list.contains($0) }
    }

    /// The whole words of `text`, each in its matching form, in order.
    ///
    /// - Parameter text: Any text; at most ``maxScannedScalars`` of its folded scalars are read.
    /// - Returns: The words, none empty.
    static func words(in text: String) -> [Word] {
        guard !text.isEmpty else { return [] }
        let folded = text.precomposedStringWithCompatibilityMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .lowercased()
        var words: [Word] = []
        var current = String.UnicodeScalarView()
        // R2: bounded by `maxScannedScalars`.
        for scalar in folded.unicodeScalars.prefix(maxScannedScalars) {
            if CharacterSet.alphanumerics.contains(scalar) || substitutionSymbols.contains(scalar) {
                current.append(scalar)
                continue
            }
            if let word = word(from: String(current)) { words.append(word) }
            current = String.UnicodeScalarView()
        }
        if let word = word(from: String(current)) { words.append(word) }
        return words
    }

    /// The matching form of one already-folded word: a leading or trailing `!` dropped, the
    /// substitutions undone, and each run of a repeated letter collapsed to one.
    ///
    /// - Parameter raw: One word, case- and diacritic-folded.
    /// - Returns: The word in its matching form, or nil when nothing is left of it.
    static func word(from raw: String) -> Word? {
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "!"))
        guard !trimmed.isEmpty else { return nil }
        var form = ""
        var previous: Character?
        var hadRepeatedLetter = false
        // R2: bounded by the word's own length.
        for character in trimmed.map({ substitutions[$0] ?? $0 }) {
            guard character != previous else {
                hadRepeatedLetter = true
                continue
            }
            form.append(character)
            previous = character
        }
        return Word(form: form, hadRepeatedLetter: hadRepeatedLetter)
    }

    /// The list entry for one plaintext word: the digest of its matching form, and whether its own
    /// spelling holds a doubled letter (which set it belongs in). The extension tool — see the
    /// type's note.
    ///
    /// - Parameter word: One word, in any case.
    /// - Returns: The entry, or nil when `word` is not exactly one word.
    static func entry(for word: String) -> (digest: String, needsRepeatedLetter: Bool)? {
        let found = words(in: word)
        guard found.count == 1, let only = found.first else { return nil }
        return (digest(of: only.form), only.hadRepeatedLetter)
    }

    /// The lowercase hex SHA-256 of `form`'s UTF-8 bytes.
    ///
    /// - Parameter form: A matching form.
    /// - Returns: 64 lowercase hex digits.
    static func digest(of form: String) -> String {
        SHA256.hash(data: Data(form.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

nonisolated extension SessionMessageFilter.List {
    /// The list the chat's send path consults: 46 spellings of 21 words (see
    /// ``SessionMessageFilter``), 26 matched by any spelling and 20 only by a spelling that held a
    /// repeated letter. Digests only, sorted; the words themselves are deliberately not in the
    /// repository.
    static let shipping = SessionMessageFilter.List(
        anySpelling: [
            "0ca06fe6268c760d1dd795eb2baf07a0b76441598f2abb17078c624b89313fb4",
            "0ce875d620076b533c6e681abaa0dc5d9a941366bb000a02ec5351f341b96c61",
            "11b70ab66b5bcb879c6af0b346814ded43897fbf8105d71355118314b334f148",
            "12e6274e4309293e2d480272b49a6c7c73a6a6b22678ba226b533c67006c17d1",
            "158869a97379229b7681efae9d7f9c9214134e836d649ba53477c0c111414d59",
            "17a110e5332848721f27510e1e2bca710a321663bb8a5632e0e46a820fc9e28a",
            "22fc75e65a0e9d34324092a7c6a8dba961853294abca4e5914e60c550f48e0c2",
            "268651b3ece980102f18871fde07189372961e056f858ca147a28d004f876b03",
            "27eb0c4ad7072067f21558908a1d4fd42f43f2c812afb17eee1e9262dd7c80f6",
            "333f7618092958c75b8c5af6f1ec77b42803922a0fc6ff1570a8af3a3aab3b4a",
            "33740da8a87dc7defbdbb7d06549dd8d82a33000a25293ceb9af687eb16bef22",
            "3b1e0d7c5dd45583867e897943e37a940a7e7321022317dd3deea01963ee365e",
            "448b303c89bef07153d6625b53685248d5e81290259d0181808c3826d9e3e323",
            "6122fdf4ae1474fb9a413c83cf1d391627b66275d8978551f855770aadb2ffbe",
            "65961619eae0bfcd043bbc8f7035c36285d82baf20fc35a11fc0043415e9a6d6",
            "6cfcdedf5407199c93063d9ced359594c716fba7e9356aa028daa21076415187",
            "7122c9a14ba2d20ebb6ebc763eb8433eee8877a22d84ff75e6056a81bf7cd0ee",
            "86f624562262063ab57e65f9419ecccded9b72bb215f60772c10bbf642285c7d",
            "bb209d506bb8b17815af0e50923c3d8f65985dab91083f026f1881a7430c5cc7",
            "bd331fb1d24298f52943034a243a341877957b895f4372b11babb87262904ed6",
            "be00f1af522eaa99d3dc57b0e27162a5e8963e0e0e8b6cc5734f53d8e64ba2dc",
            "c1cabb6f6e431f9c4dea4c3b3264d6fe3829241d674f3496a2dfff6658f0363e",
            "c3de533e9b7fe63b79f648687a30d2861edd92fe7c3cd1f2c485e0a605367624",
            "c74677aba35aef499bbe96dcc049c77700ca13835bb4930706da85ecdba4e156",
            "da0a6b1b9213d48ff10cc45733cc8a925dbd2afb26320ed488ac2efa9a8ae33a",
            "eef3bd091670c3447022d619c06ad15de96da72b5a66f28bb8b75d1b1c12a05f"
        ],
        doubledSpelling: [
            "08973583e471d951160846cb388c60f946c797f471e2eebac3f5b8542140910a",
            "0c44ea5c78ea14dbbecd4e31c800d730ba39f2dade72cb5ef2fdbe31fd150693",
            "2804a1b616988c032869fac66f194ca140e89d14be2300a9576d57bb572328d0",
            "302e7fb4580240c24f37395037d9e3dfbca60b3404b2bd4a3442e7c543bfe808",
            "362234c02fd606c43f7d5411590962016ec17372cd17c089bc85d8aeade6bb50",
            "63bd9333b1a0b11da8d0b206c4b86cd2a5be63fb5e7b59cc5ac7131f3a257489",
            "65ffb1a3641348d624831b48f6342c6e4908a985a92490df02d9cf3067583362",
            "6843ca0984504b23cb440d975015b12cfb3d02d7d7d4ea9900d623dd2ff2875c",
            "693ee9961bef39c102f077c046c93cc97968f1acbef0a5491e7dfdb69ac842e5",
            "6bc3fc21a9fbf27258359e6656ff7f057f33ff2eb28ad1e62cf54b1a23e8bf2d",
            "76b30a2ce85f13c1a38343979a83db153f6a777fb4d9250889aeb0eaa4ce973b",
            "77d1228a9f021466f4ee061abbfe704332a34e89b754afad2c05397285b16997",
            "82c1d0996a0bb6285c569ed2574547972f55656a448fde67e9cbcc01139afb76",
            "831dd63fb98ecc6b1dc8ddae9cc0e7df437210ba70cd5e7ca4a0723bc1592faa",
            "b1106bd2a8594910c2e8e1c5b0e8cc948694f0fdc5235bfbbc41f5ec3e04d25e",
            "b27c1d7f1e7ff7b34e25ac2db5dc5f2fd75b6f0dfa83622e15122a3d78b24b11",
            "b81c922678e46b0bf233d07a1d5f70b66efc8323c7dc7c25faf8331b4c3b0d03",
            "beb31d7e32c2edd7177be262eb443f5eb0dd474d94c61e9b4a77afaa50b2fb35",
            "cd86eb060dedba3f12fcd6739a2947867c90198ff5f414db5f96be1a1003e589",
            "d9d815677fde3e8273566b2c0da6a41a1b9c35b8e5404eaebebea3404fbd62d0"
        ]
    )
}
