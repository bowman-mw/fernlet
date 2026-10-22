import Foundation
import FernletDomainModel

/// The language an on-device model prompt is written for, and the lines that tell the model so
/// (localization plan §5.1).
///
/// Every prompt's INSTRUCTIONS stay English — they are prompt vocabulary, frozen like every other
/// token. What changes per language is a line or two appended to them:
/// - **Prose prompts** (day summary, companion thought, journal memory line) produce text a person
///   reads, so they append ``replyInstruction``: answer in the app's language, in the glossary's
///   register (tú, neutral Latin American Spanish), and with the person's grammatical gender for
///   words that describe them.
/// - **Catalog prompts** (dish decomposition, candidate selection, ingredient substitution, the
///   workout adjuster) produce words CODE matches against English tables, so they append
///   ``inputInstruction(keepingEnglish:writingInLanguage:)``: the person may write in Spanish; the
///   matched fields stay English (which is also how a Spanish dish description reaches the English
///   catalog before regional data exists); the display fields, if any, are written in Spanish.
///
/// In English every line is nil, so an English prompt is byte-identical to the prompt before this
/// type existed, and ``includedFieldNames`` is empty, so an English audit row is unchanged too.
///
/// **What it adds to a prompt, honestly declared.** The language is not personal data. The term of
/// address is: it is derived from the body profile's Sex answer. It is sent only for a language
/// whose grammar needs it (``gendersWordsAboutThePerson``) and only by a prose payload that is given
/// one, and it reaches the model as a grammatical instruction ("use its feminine form"), never as
/// the word "sex" or the profile value. Each payload carrying one appends ``includedFieldNames`` to
/// its own, so the audit log names it.
///
/// Whether the on-device model may be asked to work in the app's language at all is decided once,
/// in `AIProviders`' `OnDeviceModelLanguage`, which the capability provider consults: an
/// unsupported language turns the model off for routing, and every call site takes its
/// deterministic path. A value of this type is therefore only ever built for a language the gate
/// has already let through. ``resolve(appLanguage:modelSupportsLanguage:address:)`` is that rule as
/// a pure function.
public nonisolated struct AIPromptLanguage: Sendable, Equatable {
    /// The language the model writes display text in.
    public let language: FernletLanguage
    /// The grammatical form for words describing the person, kept only when ``language`` genders
    /// them and the prompt writes about the person; nil otherwise.
    public let address: TermOfAddress?

    /// A prompt language for `language`. `address` is dropped for a language that does not gender
    /// words about the person (English), so an English prompt never carries one.
    public init(language: FernletLanguage, address: TermOfAddress? = nil) {
        self.language = language
        self.address = Self.gendersWordsAboutThePerson(language) ? address : nil
    }

    /// English: every line nil, nothing added to the audit row.
    public static let english = AIPromptLanguage(language: .english)

    /// The app's interface language (``FernletLanguage/app``) — what every payload builder passes.
    ///
    /// - Parameter address: The effective profile's `sex.termOfAddress` for a PROSE prompt; nil for a
    ///   catalog prompt, which writes nothing about the person.
    public static func forApp(addressing address: TermOfAddress? = nil) -> AIPromptLanguage {
        AIPromptLanguage(language: FernletLanguage.app, address: address)
    }

    /// The language gate as a pure rule: the model may be asked to work in `appLanguage` only when
    /// it supports that language; nil sends the caller to its deterministic path. English is always
    /// usable — the instructions themselves are English.
    public static func resolve(
        appLanguage: FernletLanguage, modelSupportsLanguage: Bool, address: TermOfAddress?
    ) -> AIPromptLanguage? {
        guard appLanguage == .english || modelSupportsLanguage else { return nil }
        return AIPromptLanguage(language: appLanguage, address: address)
    }

    /// For a PROSE prompt: the lines that say which language to answer in, how to address the
    /// person, and (when known) which grammatical gender words describing the person take. Nil in
    /// English.
    public var replyInstruction: String? {
        guard language != .english else { return nil }
        var lines = ["Write your reply in \(language.promptName)."]
        lines += Self.styleNotes(for: language)
        if let addressLine { lines.append(addressLine) }
        return lines.joined(separator: "\n")
    }

    /// For a CATALOG prompt: the person may write in the app's language; `keepingEnglish` (fields
    /// code matches against English tables — "ingredient names and preparations") stay English; and
    /// `writingInLanguage` (display fields — "the dish name"), when given, are written in the app's
    /// language in the glossary's register. Nil in English.
    public func inputInstruction(keepingEnglish: String, writingInLanguage: String? = nil) -> String? {
        guard language != .english else { return nil }
        var lines = [
            "The person may write in \(language.promptName).",
            "Always write \(keepingEnglish) in English, in the forms the examples show."
        ]
        if let writingInLanguage {
            lines.append("Write \(writingInLanguage) in \(language.promptName).")
            lines += Self.styleNotes(for: language)
        }
        return lines.joined(separator: "\n")
    }

    /// `base` with `line` appended on a new line, or `base` alone when `line` is nil — how a prompt
    /// takes a language line without changing by a byte in English.
    public static func joined(_ base: String, _ line: String?) -> String {
        guard let line else { return base }
        return base + "\n" + line
    }

    /// The prompt-input NAMES this adds to a payload's own, for the audit log: none in English;
    /// `promptLanguage` otherwise, and `termOfAddress` when an address is sent.
    public var includedFieldNames: [String] {
        guard language != .english else { return [] }
        return address == nil ? ["promptLanguage"] : ["promptLanguage", "termOfAddress"]
    }

    /// The gender line, or nil when no address is sent or it is neither masculine nor feminine.
    private var addressLine: String? {
        guard let address else { return nil }
        if address == .feminine { return "When a word describes the person, use its feminine form." }
        if address == .masculine { return "When a word describes the person, use its masculine form." }
        return nil
    }

    // MARK: - Per-language prompt style (add a case per language)

    /// The glossary's register rules, as prompt lines (Docs/Localization-es-Glossary.md for `es`).
    private static func styleNotes(for language: FernletLanguage) -> [String] {
        switch language {
        case .english:
            []
        case .spanish:
            ["Use neutral Latin American Spanish.",
             "Address the person informally, with tú, never usted."]
        }
    }

    /// Whether `language` changes the words that describe the person by their gender ("listo" /
    /// "lista"), so a prose prompt needs the person's term of address.
    public static func gendersWordsAboutThePerson(_ language: FernletLanguage) -> Bool {
        switch language {
        case .english: false
        case .spanish: true
        }
    }
}
