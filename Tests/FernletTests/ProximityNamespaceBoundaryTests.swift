// ProximityNamespaceBoundaryTests.swift
// FernletTests
//
// ProximityKit plan step A0.2.12 (Docs/Plan-FernletCoach-ProximityKit-2026-10-01.md §4 A0.2), the
// last commit of A0.2: the wall that keeps its result from eroding. A0.2 left ProximityKit reading
// every protocol label and radio value, the QR scheme, the identity's and the two mesh seal keys'
// keychain rows, the storage names and the log subsystem off the namespace its host hands down
// (`ProximityNamespace`; Fernlet's is `.fernlet`, in FernletConnections). The compiler does not
// keep it that way: a ProximityKit file that builds a namespace of its own, reaches for one of
// FernletCrypto's purposes again, or spells a new Fernlet string compiles clean and passes every
// other test. So this suite reads ProximityKit's source and holds three lines:
//
//   1. no namespace, namespace group or purpose is built in ProximityKit outside `Namespace/`;
//   2. `FernletCryptoPurpose` is named in ProximityKit code only on the feature lines that leave with
//      their features in plan step A0.4, an exact per-file allowlist;
//   3. every remaining string literal in ProximityKit code that contains `fernlet` (any case) is on an
//      exact per-file allowlist that names why it is still there and the plan step that removes it.
//
// Rules 2 and 3 are ratchets. A new use fails; a use that goes away fails too, until its row is
// deleted. So both lists only shrink, to nothing, as A0.3 to A0.5 and A1 land. Between them they
// hold what is still outside the namespace wherever ProximityKit reads a feature label or spells
// `fernlet`: the feature labels, the heart-drop and moderation keychain services and the support
// folder (until A0.4), and the payload vocabulary that spells it, the coach channel's trainer-export
// format (until A0.3). No presentation string, membership record kind or routed-type token is on
// either: the radios and the name display read the presentation strings off the namespace, the
// inventory digest its record kinds and the routed type registry its routed types, and the
// coordinator has no display default and no per-mode service type.

import Foundation
import Testing

// MARK: - The lexer

/// A small Swift lexer for the source walls. It tells code from comments and string literals the way
/// the compiler does, so a wall can read code without the prose about it, and literals without the
/// code around them.
///
/// It knows line comments, nested block comments, and every string-literal form ProximityKit and the
/// test tree write: single-line and multi-line, raw (`#"…"#`, any number of `#`), escapes, and
/// interpolations, which may hold literals of their own. It does not know regex literals: neither tree
/// writes one that holds a quote. It reads UTF-8 bytes, because every delimiter it looks for is ASCII
/// and no byte of a multi-byte UTF-8 sequence is.
enum SwiftSourceLexer {

    /// One outermost string literal.
    struct Literal: Equatable, Sendable {
        /// The 1-based line its opening delimiter is on.
        let line: Int
        /// Its text between the delimiters, exactly as written, escapes and interpolations included.
        let text: String
    }

    /// A file, lexed.
    struct Lexed: Sendable {
        /// The source with every comment removed and every literal emptied, line breaks kept so line
        /// numbers still match the file. A literal reads `""`, with its interpolations' code, each in
        /// its parentheses, between the two quotes.
        let code: String
        /// Every outermost literal, in source order. A literal inside an interpolation is part of the
        /// text of the literal that holds it.
        let literals: [Literal]
    }

    /// Lexes Swift source.
    ///
    /// - Parameter source: A Swift file's text.
    /// - Returns: Its code and its literals.
    static func lex(_ source: String) -> Lexed {
        var lexer = SwiftByteLexer(bytes: Array(source.utf8))
        lexer.run()
        return Lexed(code: String(decoding: lexer.code, as: UTF8.self), literals: lexer.literals)
    }
}

/// `SwiftSourceLexer`'s state, one byte at a time.
private struct SwiftByteLexer {

    /// A string literal still open; the innermost is last.
    struct Open {
        /// The `#` count of its delimiters (0 for an ordinary literal).
        let hashes: Int
        /// Whether its delimiters are `"""`.
        let multiline: Bool
        /// The index of its first byte of text.
        let textStart: Int
        /// The line its opening delimiter is on.
        let line: Int
        /// The parenthesis depth of the interpolation open inside it, or nil while reading its text.
        var interpolation: Int?
    }

    let bytes: [UInt8]
    var index = 0
    var line = 1
    var code: [UInt8] = []
    var literals: [SwiftSourceLexer.Literal] = []
    var open: [Open] = []

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    /// Lexes every byte.
    mutating func run() {
        // R2: every step consumes at least one byte of a finite array.
        while index < bytes.count {
            if let innermost = open.last, innermost.interpolation == nil {
                stepInLiteral(innermost)
            } else {
                stepInCode()
            }
        }
    }

    /// One step through code: top-level code, or an interpolation's.
    private mutating func stepInCode() {
        let byte = bytes[index]
        if byte == .slash, at(index + 1) == .slash { return skipLineComment() }
        if byte == .slash, at(index + 1) == .star { return skipBlockComment() }
        if byte == .hash || byte == .quote, let hashes = literalOpening() { return openLiteral(hashes: hashes) }
        if byte == .newline { line += 1 }
        if byte == .leftParenthesis || byte == .rightParenthesis { trackInterpolation(byte) }
        code.append(byte)
        index += 1
    }

    /// One step through the text of the innermost open literal.
    private mutating func stepInLiteral(_ innermost: Open) {
        let byte = bytes[index]
        if byte == .backslash, hashesFollow(index + 1, count: innermost.hashes) {
            return escape(at: index + 1 + innermost.hashes)
        }
        if byte == .quote, let length = closingLength(of: innermost) { return close(innermost, length: length) }
        if byte == .newline {
            line += 1
            code.append(.newline)
        }
        index += 1
    }

    /// The byte at `position`, or nil past the end.
    private func at(_ position: Int) -> UInt8? {
        position < bytes.count ? bytes[position] : nil
    }

    /// Whether `count` `#` bytes start at `position`.
    private func hashesFollow(_ position: Int, count: Int) -> Bool {
        guard position + count <= bytes.count else { return false }
        return bytes[position..<position + count].allSatisfy { $0 == .hash }
    }

    /// The `#` count of a literal opening at `index`, or nil when no literal opens there.
    private func literalOpening() -> Int? {
        var position = index
        // R2: bounded by the remaining bytes.
        while at(position) == .hash { position += 1 }
        return at(position) == .quote ? position - index : nil
    }

    /// Opens a literal whose delimiter starts at `index` with `hashes` `#` bytes.
    private mutating func openLiteral(hashes: Int) {
        let quote = index + hashes
        let multiline = at(quote + 1) == .quote && at(quote + 2) == .quote
        let textStart = quote + (multiline ? 3 : 1)
        open.append(Open(hashes: hashes, multiline: multiline, textStart: textStart, line: line))
        code.append(.quote)
        index = textStart
    }

    /// The length of the closing delimiter of `literal` at `index`, or nil when it does not close here.
    private func closingLength(of literal: Open) -> Int? {
        let quotes = literal.multiline ? 3 : 1
        guard (0..<quotes).allSatisfy({ at(index + $0) == .quote }) else { return nil }
        return hashesFollow(index + quotes, count: literal.hashes) ? quotes + literal.hashes : nil
    }

    /// Closes the innermost literal, recording it when it is outermost.
    private mutating func close(_ literal: Open, length: Int) {
        open.removeLast()
        if open.isEmpty {
            let text = String(decoding: bytes[literal.textStart..<index], as: UTF8.self)
            literals.append(SwiftSourceLexer.Literal(line: literal.line, text: text))
        }
        code.append(.quote)
        index += length
    }

    /// Reads the escape whose escaped byte is at `position`: an interpolation opens on `(`.
    private mutating func escape(at position: Int) {
        if at(position) == .leftParenthesis {
            open[open.count - 1].interpolation = 1
            code.append(.leftParenthesis)
        } else if at(position) == .newline {
            line += 1
            code.append(.newline)
        }
        index = position + 1
    }

    /// Follows an interpolation's parentheses; the one that balances its `\(` returns to the text.
    private mutating func trackInterpolation(_ byte: UInt8) {
        guard let depth = open.last?.interpolation else { return }
        let next = byte == .leftParenthesis ? depth + 1 : depth - 1
        open[open.count - 1].interpolation = next == 0 ? nil : next
    }

    /// Skips a line comment, leaving its line break to the code.
    private mutating func skipLineComment() {
        // R2: bounded by the remaining bytes.
        while index < bytes.count, bytes[index] != .newline { index += 1 }
    }

    /// Skips a block comment and every block comment nested in it, keeping its line breaks.
    private mutating func skipBlockComment() {
        var depth = 0
        // R2: bounded by the remaining bytes; each pass consumes at least one.
        while index < bytes.count {
            if bytes[index] == .slash, at(index + 1) == .star {
                depth += 1
                index += 2
            } else if bytes[index] == .star, at(index + 1) == .slash {
                depth -= 1
                index += 2
                if depth == 0 { return }
            } else {
                if bytes[index] == .newline {
                    line += 1
                    code.append(.newline)
                }
                index += 1
            }
        }
    }
}

private extension UInt8 {
    static let newline: UInt8 = 0x0A
    static let quote: UInt8 = 0x22
    static let hash: UInt8 = 0x23
    static let leftParenthesis: UInt8 = 0x28
    static let rightParenthesis: UInt8 = 0x29
    static let star: UInt8 = 0x2A
    static let slash: UInt8 = 0x2F
    static let backslash: UInt8 = 0x5C
}

// MARK: - The wall

/// ProximityKit builds no namespace of its own, names FernletCrypto's purposes only on the feature
/// lines that leave in A0.4, and spells `fernlet` only in the literals its allowlist names.
@Suite struct ProximityNamespaceBoundaryTests {

    /// The module, from the repository root.
    private static let moduleRoot = "FernletKit/Sources/ProximityKit"

    /// The one folder that may build a namespace, its groups and its purposes.
    private static let namespaceFolder = "Namespace/"

    // MARK: Rule 1: no namespace is built outside Namespace/

    /// No namespace, namespace group or purpose is built in ProximityKit code outside `Namespace/`.
    ///
    /// ProximityKit reads the namespace its host hands down and never makes one: a namespace built
    /// anywhere else would be a default nobody supplied, and a purpose minted anywhere else a label no
    /// namespace carries. Every way to build one is a pattern in ``constructionPatterns``, and so is
    /// the place the patterns cannot see: an extension of, or alias for, a namespace type outside the
    /// folder, where an unqualified initializer or `Self(` would build one by a name too short to
    /// search for. The scan reads code only (comments and literal text removed), so prose about these
    /// spellings is never a violation. Its floors fail an empty scan: it must read the module, find
    /// the folder, and find there the constructions the patterns exist to catch (`Namespace/` mints
    /// each of the 39 labels with `ProximityCryptographicPurpose(_:role:)`).
    @Test func noNamespaceGroupOrPurposeIsBuiltOutsideTheNamespaceFolder() throws {
        let patterns = try Self.constructionPatterns.map {
            (name: $0.name, regex: try NSRegularExpression(pattern: $0.pattern))
        }
        let sources = try Self.proximitySources()
        var violations: [String] = []
        var insideMatches: [String: Int] = [:]
        // R2: bounded by the module's file list and the pattern list.
        for source in sources {
            let inside = source.path.hasPrefix(Self.namespaceFolder)
            for pattern in patterns {
                let lines = Self.matchLines(of: pattern.regex, in: source.lexed.code)
                if inside {
                    insideMatches[pattern.name, default: 0] += lines.count
                } else {
                    violations += lines.map { "\(source.path):\($0): \(pattern.name)" }
                }
            }
        }
        #expect(sources.count >= 50, "the ProximityKit sweep read only \(sources.count) Swift files")
        #expect(sources.filter { $0.path.hasPrefix(Self.namespaceFolder) }.count >= 5,
                "the sweep did not find the five files of \(Self.moduleRoot)/\(Self.namespaceFolder)")
        #expect(insideMatches["ProximityCryptographicPurpose(", default: 0] >= 39 &&
                insideMatches["ProximityNamespace(", default: 0] >= 1, """
            the patterns no longer see Namespace/ mint its 39 labels and build its namespace \
            (\(insideMatches)): a blind pattern would pass every file outside it vacuously
            """)
        #expect(violations.isEmpty, """
            ProximityKit builds a namespace, a namespace group or a purpose outside \
            \(Self.namespaceFolder): \(violations). ProximityKit reads the namespace its host supplies \
            (a manager's stored copy, an identity's purposes, a scope's namespace, a verifier's own \
            copy) and never makes one; a new label belongs in Namespace/'s groups, with its value in \
            the host's namespace (Fernlet's: FernletConnections' `.fernlet`).
            """)
    }

    /// Rule 1's patterns, by name. A name matches ``matchLines(of:in:)``'s use of `pattern` against
    /// lexed code, where literals are empty and comments gone.
    ///
    /// - The type's own name called, with `.init` too: a group name counts unqualified or under
    ///   `ProximityNamespace.`, so another type's nested `Radio(` is not a match.
    /// - The group factories `accepted(identityEnvelopeV1:meshAdmissionTokenV1:)` (also as `.accepted(`)
    ///   and `validated(family:installation:)`.
    /// - An initializer's shorthand `.init(…)`, known by its first argument label.
    /// - The purpose initializer's shape however it is called: a literal then `role:`, or a shorthand
    ///   `.init(` with an unlabeled argument then `role:`. (Not any unlabeled argument then `role:`:
    ///   the transport's `refusalDetail(rejection, role: role, …)` is that shape too.)
    /// - An extension of, or a typealias for, a namespace type.
    ///
    /// ``everyConstructionPatternSeesItsFormAndNoNeighbour()`` holds each pattern to a sample it must
    /// match and to the near neighbours in today's code it must not.
    private static let constructionPatterns: [(name: String, pattern: String)] = [
        ("ProximityNamespace(", #"(?<![A-Za-z0-9_.])ProximityNamespace\s*(?:\.\s*init\s*)?\("#),
        ("ProximityCryptographicPurpose(",
         #"(?<![A-Za-z0-9_.])ProximityCryptographicPurpose\s*(?:\.\s*init\s*)?\("#),
        ("a namespace group's initializer",
         #"(?<![A-Za-z0-9_.])(?:ProximityNamespace\s*\.\s*)?(?:Signature|KeyDerivation|AEAD|Hash|Radios|Radio|VerifyQR|Family|Purposes|Installation|Keychain|Storage|Vocabulary|SessionMessages|SessionMessage|Heartbeat|PayloadRules|Capabilities|MembershipRecordKinds|RoutedTypes)\s*(?:\.\s*init\s*)?\("#),
        ("a keychain row's initializer",
         #"(?<![A-Za-z0-9_.])(?:(?:ProximityNamespace\s*\.\s*)?Keychain\s*\.\s*Row|(?:(?:ProximityNamespace\s*\.\s*)?Keychain\s*\.\s*)?IdentityRows)\s*(?:\.\s*init\s*)?\("#),
        ("LegacyV1.accepted(", #"(?<![A-Za-z0-9_])accepted\s*\(\s*identityEnvelopeV1\s*:"#),
        ("ProximityNamespace.validated(", #"(?<![A-Za-z0-9_])validated\s*\(\s*family\s*:"#),
        ("a namespace initializer's shorthand .init(",
         #"\.\s*init\s*\(\s*(?:family|purposes|signature|identityEnvelopeV2|proximityTransportV1|proximityTransportV2|meshInventoryDigestV1|mesh|serviceType|urlScheme|keychain|identity|service|directoryName|session|identityIntroduction|payloadType|known|admission|photo)\s*:"#),
        ("the purpose initializer's shape",
         #"(?:\(\s*""|\.\s*init\s*\(\s*[^\s,():]+)\s*,\s*role\s*:"#),
        ("an extension of a namespace type",
         #"(?<![A-Za-z0-9_])extension\s+(?:ProximityNamespace|ProximityCryptographicPurpose)(?![A-Za-z0-9_])"#),
        ("a typealias for a namespace type",
         #"(?<![A-Za-z0-9_])typealias\s+\w+\s*=\s*(?:ProximityNamespace|ProximityCryptographicPurpose)(?![A-Za-z0-9_])"#)
    ]

    /// Rule 1's patterns, fixtured both ways, because the matcher is the wall: each sees its own
    /// construction forms (named, `.init`, shorthand, wrapped), and none sees the nearest code in
    /// today's tree that is not a construction — another type's nested `Radio(`, the transport's calls
    /// that pass a `role:`, a shorthand `.init(` of another type, a namespace field read, a hash, and
    /// the session-message store, heartbeat payload and schedule and capability list whose names hold
    /// a vocabulary group's. Every sample is lexed first, as the module's files are.
    @Test func everyConstructionPatternSeesItsFormAndNoNeighbour() throws {
        let patterns = try Dictionary(uniqueKeysWithValues: Self.constructionPatterns.map {
            ($0.name, try NSRegularExpression(pattern: $0.pattern))
        })
        let samples: [(pattern: String, source: String)] = [
            ("ProximityNamespace(", "let n = ProximityNamespace(family: family, installation: installation)"),
            ("ProximityNamespace(", "let n = ProximityNamespace\n    .init(family: family, installation: installation)"),
            ("ProximityCryptographicPurpose(", #"let p = ProximityCryptographicPurpose("x.v1", role: .columnSeal)"#),
            ("a namespace group's initializer", "let r = ProximityNamespace.Radio(serviceType: s, alpn: a)"),
            ("a namespace group's initializer", #"Hash.init(meshInventoryDigestV1: "a", meshRoutedContentV1: "b")"#),
            ("a namespace group's initializer", "let beat = ProximityNamespace.Heartbeat(payloadType: t, pingTitle: p, replyTitle: r)"),
            ("a namespace group's initializer", "let kinds = MembershipRecordKinds.init(admission: a, departure: d)"),
            ("a keychain row's initializer", "let row = ProximityNamespace.Keychain.Row(service: s, account: a)"),
            ("a keychain row's initializer", "let rows = IdentityRows(service: s, signingPrivateKey: k)"),
            ("LegacyV1.accepted(", #"legacyV1: .accepted(identityEnvelopeV1: "a", meshAdmissionTokenV1: "b")"#),
            ("ProximityNamespace.validated(", "let n = try ProximityNamespace.validated(family: f, installation: i)"),
            ("a namespace initializer's shorthand .init(", "let r: ProximityNamespace.Radio = .init(serviceType: s, alpn: a)"),
            ("a namespace initializer's shorthand .init(",
             "let rules: ProximityNamespace.PayloadRules = .init(known: k, sealingRequired: s)"),
            ("the purpose initializer's shape", #"Self("x.v1", role: .aeadAssociatedData)"#),
            ("the purpose initializer's shape", "let p: ProximityCryptographicPurpose = .init(spelling, role: .columnSeal)"),
            ("an extension of a namespace type", "nonisolated extension ProximityNamespace.Storage {"),
            ("a typealias for a namespace type", "typealias Labels = ProximityNamespace.Purposes")
        ]
        // R2: bounded by the sample list.
        for sample in samples {
            let regex = try #require(patterns[sample.pattern], "no pattern is named \(sample.pattern)")
            #expect(!Self.matchLines(of: regex, in: SwiftSourceLexer.lex(sample.source).code).isEmpty,
                    "\(sample.pattern) misses: \(sample.source)")
        }
        let neighbours = [
            "let gate = RecipeShareDiscoveryGate.Radio(isRunning: true, isPaused: false)",
            "MeshTransportConsoleLog.echo(Self.refusalDetail(rejection, role: role, authority: authority))",
            "return try await settle(exchange, role: role, signed: signed, over: stream)",
            "tunnels[key] = Tunnel(peer: channel.peer, channel: channel, role: .initiator)",
            "entries.append(.init(activityID: id, versionHeld: version))",
            "let label = identity.purposes.signature.meshRoutedChunkV1",
            "let digest = SHA256.hash(data: bytes)",
            "case .signature(let framing), .hashDomain(let framing):",
            "public let sessionMessages = SessionMessageStore()",
            "private var heartbeats = MeshHeartbeatSchedule()",
            "let payload = SessionHeartbeatPayload(kind: .ack, heartbeatID: UUID(), sentAt: now, responseTo: heartbeatID)",
            "capabilities: localCapabilities(),"
        ]
        // R2: bounded by the neighbour and pattern lists.
        for source in neighbours {
            let code = SwiftSourceLexer.lex(source).code
            let matched = patterns.filter { !Self.matchLines(of: $0.value, in: code).isEmpty }.map(\.key)
            #expect(matched.isEmpty, "\(matched) read a construction in: \(source)")
        }
    }

    // MARK: Rule 2: FernletCryptoPurpose only on the feature lines

    /// `FernletCryptoPurpose` is named in ProximityKit code only on the feature lines A0.4 removes:
    /// exactly ``featurePurposeLines``, file by file, line count and purposes read.
    ///
    /// A0.2 moved every protocol label onto the namespace. What is left are the 13 feature labels that
    /// leave ProximityKit with their features in plan step A0.4 (hearts, presence, activities,
    /// moderation and the sealed-backup escrow), on 20 code lines in 7 files when this wall landed. A
    /// new line fails, and so does a protocol purpose read again on a line that was a feature's; a line
    /// that goes away fails until its count is lowered or its row deleted, so the list only shrinks
    /// and reaches nothing at A0.4. Comments may name the registry; only code lines count.
    @Test func fernletCryptoPurposeIsNamedOnlyOnTheFeatureLinesThatLeaveInA04() throws {
        let mention = try NSRegularExpression(pattern: #"(?<![A-Za-z0-9_])FernletCryptoPurpose(?![A-Za-z0-9_])"#)
        let member = try NSRegularExpression(
            pattern: #"FernletCryptoPurpose\s*\.\s*([A-Za-z]+)\s*\.\s*([A-Za-z0-9]+)"#
        )
        let sources = try Self.proximitySources()
        var found: [String: (lines: Int, purposes: Set<String>)] = [:]
        var linesRead = 0
        // R2: bounded by the module's file list.
        for source in sources {
            linesRead += source.lexed.code.count(where: { $0 == "\n" }) + 1
            let lines = Self.matchLines(of: mention, in: source.lexed.code)
            guard !lines.isEmpty else { continue }
            found[source.path] = (Set(lines).count, Self.captures(of: member, in: source.lexed.code))
        }
        #expect(sources.count >= 50, "the ProximityKit sweep read only \(sources.count) Swift files")
        #expect(linesRead >= 20_000, "the ProximityKit sweep read only \(linesRead) lines")
        let paths = Set(found.keys).union(Self.featurePurposeLines.keys).sorted()
        // R2: bounded by the union of two finite key sets.
        for path in paths {
            let allowed = Self.featurePurposeLines[path]
            let actual = found[path] ?? (0, [])
            #expect(actual.lines == (allowed?.lines ?? 0) && actual.purposes == (allowed?.purposes ?? []), """
                \(path) names FernletCryptoPurpose on \(actual.lines) code lines reading \
                \(actual.purposes.sorted()); the allowlist says \(allowed?.lines ?? 0) reading \
                \((allowed?.purposes ?? []).sorted())\(allowed.map { ", leaving at \($0.reason.exit.rawValue)" } ?? ""). \
                A new line reads a label ProximityKit must take from its host's namespace \
                (`purposes.<group>.<label>`); a line that left needs its row lowered or deleted here, so \
                the ratchet stays exact.
                """)
        }
    }

    /// One file's remaining `FernletCryptoPurpose` code lines.
    struct FeaturePurposeLines: Sendable {
        /// How many code lines name the registry.
        let lines: Int
        /// The purposes they read, as `Group.label`.
        let purposes: Set<String>
        /// Why the lines are still here.
        let reason: Reason
    }

    /// Every file whose code still names `FernletCryptoPurpose`, by path under the module root.
    static let featurePurposeLines: [String: FeaturePurposeLines] = [
        "HeartSharing/HeartDropSealer.swift": FeaturePurposeLines(
            lines: 1, purposes: ["KeyDerivation.heartDropOuterSealV1"], reason: .heartLabels),
        "HeartSharing/HeartDropSidecarKey.swift": FeaturePurposeLines(
            lines: 2, purposes: ["AEAD.heartDropSidecarV2"], reason: .heartLabels),
        "Identity/IdentityService.swift": FeaturePurposeLines(
            lines: 6,
            purposes: [
                "KeyDerivation.sealedBackupV2", "KeyDerivation.sealedBackupLegacyV1",
                "KeyDerivation.heartDropPairV1", "HMAC.heartDropDayTagV1",
                "KeyDerivation.presencePairV1", "HMAC.presenceEpochTagV1"
            ],
            reason: .identityFeatureDerivations),
        "Moderation/ModerationBanStore.swift": FeaturePurposeLines(
            lines: 1, purposes: ["Hash.moderationBanReporterTagV1"], reason: .moderationLabels),
        "Moderation/ModerationReportRelay.swift": FeaturePurposeLines(
            lines: 2, purposes: ["Signature.moderationReportV2"], reason: .moderationLabels),
        "Wire/ActivityPayloads.swift": FeaturePurposeLines(
            lines: 4,
            purposes: ["Signature.activityJoinTokenV2", "Signature.activityRosterSnapshotV2"],
            reason: .activityLabels),
        "Wire/CanonicalSignatureSerializer.swift": FeaturePurposeLines(
            lines: 4,
            purposes: [
                "Signature.activityDescriptorV2", "Signature.activityJoinTokenV2",
                "Signature.activityRosterSnapshotV2", "Signature.moderationReportV2"
            ],
            reason: .serializerFeatureDomains)
    ]

    // MARK: Rule 3: every fernlet literal is allowlisted

    /// Every string literal in ProximityKit code that contains `fernlet` (any case) is in
    /// ``fernletLiterals``, file by file and count by count, and every row there is still in the code.
    ///
    /// A0.2 moved every Fernlet value ProximityKit's protocol reads into the host's namespace, and the
    /// radios and the name display read the presentation strings off it too, the inventory digest the
    /// membership record kinds and the routed type registry the routed types. What is left is spelled
    /// in place for a reason each row names, with the plan step that takes it out: payload vocabulary
    /// (A0.3), feature values (A0.4), and DEBUG test-hook names (A1). A new Fernlet string fails here:
    /// it belongs in the host's namespace, or in the feature's own module. A row whose literal is gone
    /// fails until it is deleted, so the list stays the exact set (38 literals on 37 lines in 13
    /// files). The scan reads literals only: comments may say Fernlet freely.
    @Test func everyFernletLiteralIsAllowlistedWithItsReasonAndExitStep() throws {
        let sources = try Self.proximitySources()
        var found: [String: [String: [Int]]] = [:]
        var literalsLexed = 0
        // R2: bounded by the module's file list and each file's literal count.
        for source in sources {
            literalsLexed += source.lexed.literals.count
            for literal in source.lexed.literals where literal.text.lowercased().contains("fernlet") {
                found[source.path, default: [:]][literal.text, default: []].append(literal.line)
            }
        }
        #expect(sources.count >= 50, "the ProximityKit sweep read only \(sources.count) Swift files")
        #expect(literalsLexed >= 500, "the lexer found only \(literalsLexed) literals in ProximityKit")
        var allowed: [String: [String: Int]] = [:]
        // R2: bounded by the allowlist.
        for row in Self.fernletLiterals {
            #expect(allowed[row.file]?[row.text] == nil, "\(row.file) lists \"\(row.text)\" twice")
            allowed[row.file, default: [:]][row.text] = row.count
        }
        let files = Set(found.keys).union(allowed.keys).sorted()
        // R2: bounded by the union of two finite key sets.
        for file in files {
            let actual = (found[file] ?? [:]).mapValues(\.count)
            let expected = allowed[file] ?? [:]
            #expect(actual == expected, """
                \(file): the fernlet literals in code are \(Self.describe(found[file] ?? [:])), but the \
                allowlist says \(Self.describeRows(of: file)). A new Fernlet string belongs in the \
                host's namespace (ProximityNamespace, Fernlet's in FernletConnections) or in its \
                feature's own module, not spelled in ProximityKit; a literal that left needs its row \
                lowered or deleted here, so the list stays exact.
                """)
        }
    }

    /// One allowlisted literal.
    struct FernletLiteral: Sendable {
        /// The file, by path under the module root.
        let file: String
        /// The literal's text between its delimiters, exactly as written.
        let text: String
        /// How many times the file's code spells it.
        let count: Int
        /// Why it is still here, and the step that removes it.
        let reason: Reason

        init(_ file: String, _ text: String, _ count: Int, _ reason: Reason) {
            self.file = file
            self.text = text
            self.count = count
            self.reason = reason
        }
    }

    /// Every `fernlet` literal still in ProximityKit code, by file.
    static let fernletLiterals: [FernletLiteral] = [
        FernletLiteral("ClothingSharing/MeshClothingShop.swift", "fernlet.proximity.clothing.catalog", 1,
                       .clothingFormat),
        FernletLiteral("HeartSharing/HeartPrekeyStore.swift", "com.fernlet.heartdrop", 1, .heartDropService),
        FernletLiteral("Mesh/MeshNetworkManager.swift", "FERNLET_UI_TEST_MESH_OPEN", 1, .uiTestHook),
        FernletLiteral("Mesh/MeshNetworkManager.swift", "FERNLET_UI_TEST_MESH_ADMISSION", 2, .uiTestHook),
        FernletLiteral("Mesh/MeshNetworkManager.swift", "FERNLET_UI_TEST_MESH_CLOSED", 1, .uiTestHook),
        FernletLiteral("Moderation/ModerationBanStore.swift", "com.fernlet.moderation", 1, .moderationService),
        FernletLiteral("Moderation/ModerationReportRelay.swift", "fernlet.proximity.moderation.report", 2,
                       .moderationFormat),
        FernletLiteral("Presence/PresenceManager.swift", "fernlet.proximity.heart", 1, .heartFormat),
        FernletLiteral("ProximityHost.swift", "Fernlet", 1, .supportDirectory),
        FernletLiteral("RecipeSharing/ProximityRecipeShareManager.swift",
                       #"Connected to \(name) — recipe sharing links two Fernlets at a time."#, 1,
                       .recipeShareCopy),
        FernletLiteral("RecipeSharing/ProximityRecipeShareManager.swift",
                       "That nearby Fernlet is no longer available.", 1, .recipeShareCopy),
        FernletLiteral("RecipeSharing/ProximityRecipeShareManager.swift",
                       "Still connecting to another Fernlet — recipe sharing links two Fernlets at a time.", 1,
                       .recipeShareCopy),
        FernletLiteral("RecipeSharing/ProximityRecipeShareManager.swift",
                       #"Still sharing with \(name) — recipe sharing links two Fernlets at a time."#, 1,
                       .recipeShareCopy),
        FernletLiteral("RecipeSharing/ProximityRecipeShareManager.swift", "fernlet.proximity.recipe", 1,
                       .recipeFormat),
        FernletLiteral("RecipeSharing/ProximityRecipeShareManager.swift",
                       #"Turned away \(displayName(for: channel.peer)) — recipe sharing links two Fernlets at a time."#,
                       1, .recipeShareCopy),
        FernletLiteral("RecipeSharing/ProximityRecipeShareManager.swift",
                       "Recipe sharing reopened to nearby Fernlets.", 1, .recipeShareCopy),
        FernletLiteral("RecipeSharing/ProximityRecipeShareManager.swift",
                       #"No answer from \(recipient.displayName) — that Fernlet may be busy sharing with someone else."#,
                       1, .recipeShareCopy),
        FernletLiteral("Transport/MeshTransportDebugHooks.swift", "FERNLET_MESH_CONSOLE_LOG", 1, .meshDebugHook),
        FernletLiteral("Transport/MeshTransportDebugHooks.swift", "FERNLET_MESH_CHAOS", 1, .meshDebugHook),
        FernletLiteral("Transport/MeshTransportDebugHooks.swift", "FERNLET_MESH_CHAOS_BARRED", 1, .meshDebugHook),
        FernletLiteral("Wire/ActivityPayloads.swift", "fernlet.proximity.activity.offer", 2, .activityFormat),
        FernletLiteral("Wire/ActivityPayloads.swift", "fernlet.proximity.activity.join.request", 2,
                       .activityFormat),
        FernletLiteral("Wire/ActivityPayloads.swift", "fernlet.proximity.activity.join.grant", 2, .activityFormat),
        FernletLiteral("Wire/ActivityPayloads.swift", "fernlet.proximity.activity.roster", 2, .activityFormat),
        FernletLiteral("Wire/ActivityPayloads.swift", "fernlet.proximity.activity.sync", 2, .activityFormat),
        FernletLiteral("Wire/ClothingSharePayloads.swift", "fernlet.proximity.clothing.catalog", 2,
                       .clothingFormat),
        FernletLiteral("Wire/RecipeSharePayloads.swift", "fernlet.proximity.recipe", 2, .recipeFormat),
        FernletLiteral("Wire/TrainerPayloads.swift", "fernlet.trainer.export", 2, .trainerExportFormat)
    ]

    /// `found`'s literals with the lines each is on, sorted, for a failure message.
    private static func describe(_ found: [String: [Int]]) -> String {
        let listed = found.sorted { $0.key < $1.key }.map { "\"\($0.key)\" at \($0.value)" }
        return listed.isEmpty ? "none" : listed.joined(separator: ", ")
    }

    /// `file`'s allowlist rows with their counts and exit steps, for a failure message.
    private static func describeRows(of file: String) -> String {
        let rows = fernletLiterals.filter { $0.file == file }
            .map { "\"\($0.text)\" ×\($0.count) (until \($0.reason.exit.rawValue))" }
        return rows.isEmpty ? "none" : rows.joined(separator: ", ")
    }

    // MARK: The lexer, fixtured

    /// The lexer reads code, comments and literals as Swift does: the walls above and the isolation
    /// walls' shorthand scan are only as sharp as it is.
    ///
    /// Each fixture is a form the module or the test tree writes, chosen where a looser reading goes
    /// wrong: a quote in a comment, a comment inside a comment, an escaped quote, a literal inside an
    /// interpolation, a raw literal holding quotes and a `\(` that is text, and a multi-line literal,
    /// whose line breaks the code must keep so every later line number stays true.
    @Test func theLexerTellsCodeCommentsAndLiteralsApartAsSwiftDoes() {
        let commented = SwiftSourceLexer.lex(#"let a = "x" // "not a literal""#)
        #expect(commented.literals == [SwiftSourceLexer.Literal(line: 1, text: "x")])
        #expect(commented.code == #"let a = "" "#)
        let nested = SwiftSourceLexer.lex("/* outer /* \"inner\" */ still */ let b = 1\nlet c = \"y\"")
        #expect(nested.literals == [SwiftSourceLexer.Literal(line: 2, text: "y")])
        #expect(nested.code == " let b = 1\nlet c = \"\"")
        let escaped = SwiftSourceLexer.lex(#"let d = "say \"fernlet\"" + "z""#)
        #expect(escaped.literals.map(\.text) == [#"say \"fernlet\""#, "z"])
        let interpolated = SwiftSourceLexer.lex(#"let e = "a \(f("fernlet")) b""#)
        #expect(interpolated.literals.map(\.text) == [#"a \(f("fernlet")) b"#])
        #expect(interpolated.code == #"let e = "(f(""))""#)
        let raw = SwiftSourceLexer.lex(##"let f = #"raw "quoted" \(text)"# + "w""##)
        #expect(raw.literals.map(\.text) == [#"raw "quoted" \(text)"#, "w"])
        let multiline = SwiftSourceLexer.lex("let g = \"\"\"\n    one \"two\"\n    \"\"\"\nlet h = \"v\"")
        #expect(multiline.literals.map(\.line) == [1, 4])
        #expect(multiline.literals.first?.text == "\n    one \"two\"\n    ")
        #expect(multiline.code == "let g = \"\n\n\"\nlet h = \"\"")
    }

    // MARK: The sweep

    /// ProximityKit's Swift files, each by its path under the module root and lexed, sorted by path.
    private static func proximitySources() throws -> [(path: String, lexed: SwiftSourceLexer.Lexed)] {
        let root = RepoRoot.url(moduleRoot)
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        let files = (walker?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
        var sources: [(path: String, lexed: SwiftSourceLexer.Lexed)] = []
        // R2: bounded by the module's file list.
        for file in files.sorted(by: { $0.path < $1.path }) {
            let source = try String(contentsOf: file, encoding: .utf8)
            sources.append((path: relativePath(of: file), lexed: SwiftSourceLexer.lex(source)))
        }
        return sources
    }

    /// `file`'s path under the module root, read off the path's own `FernletKit/Sources/ProximityKit/`
    /// component so a symlinked checkout (`/tmp` and `/private/tmp`) resolves alike; the full path if
    /// the file is somehow outside it, which then matches no allowlist row and fails loudly.
    private static func relativePath(of file: URL) -> String {
        let path = file.path
        guard let range = path.range(of: "/" + moduleRoot + "/", options: .backwards) else { return path }
        return String(path[range.upperBound...])
    }

    /// The 1-based lines of `code` on which `regex` matches.
    private static func matchLines(of regex: NSRegularExpression, in code: String) -> [Int] {
        let text = code as NSString
        return regex.matches(in: code, range: NSRange(location: 0, length: text.length)).map {
            text.substring(to: $0.range.location).count(where: { $0 == "\n" }) + 1
        }
    }

    /// Every match of `regex`'s two capture groups in `code`, joined as `first.second`.
    private static func captures(of regex: NSRegularExpression, in code: String) -> Set<String> {
        let text = code as NSString
        let matches = regex.matches(in: code, range: NSRange(location: 0, length: text.length))
        return Set(matches.map { text.substring(with: $0.range(at: 1)) + "." + text.substring(with: $0.range(at: 2)) })
    }

    // MARK: Reasons

    /// The plan step that takes a value out of ProximityKit.
    enum ExitStep: String, Sendable {
        /// Vocabulary and rules injected by the host (plan §4 A0.3).
        case a03 = "A0.3"
        /// Fernlet's features leave for FernletSocial (A0.4).
        case a04 = "A0.4"
        /// The routed mesh manager is split (A0.5). No row needs it today: the photo stores' keychain
        /// service and names live in PrivateMediaStore, and ProximityKit's photo names spell no `fernlet`.
        case a05 = "A0.5"
        /// The package leaves Fernlet's tree (A1).
        case a1 = "A1"
    }

    /// Why a value is still in ProximityKit, and the step that takes it out.
    struct Reason: Sendable {
        /// The step that removes it.
        let exit: ExitStep
        /// Why it is still here until then.
        let why: String
    }
}

// MARK: - The reasons

extension ProximityNamespaceBoundaryTests.Reason {

    // Rule 2: the feature labels.

    /// Hearts' labels.
    static let heartLabels = Self(exit: .a04, why: """
        hearts: the sealed drop's HKDF salt and the sidecar's authenticated data; HeartSharing/ \
        (all but ProtectedSidecar) moves to FernletSocial, which names its own purposes
        """)
    /// IdentityService's feature derivations.
    static let identityFeatureDerivations = Self(exit: .a04, why: """
        IdentityService's feature derivations: the sealed-backup escrow key moves to Fernlet's backup \
        side, and the heart-drop and presence secrets and tags become pairSecret(purpose:) and \
        epochTag(purpose:), called with Fernlet's purposes
        """)
    /// Moderation's labels.
    static let moderationLabels = Self(exit: .a04, why: """
        moderation: the report signature and the ban evidence's reporter tag; Moderation/ moves to \
        FernletSocial
        """)
    /// Activities' labels.
    static let activityLabels = Self(exit: .a04, why: """
        activities: the join-token and roster signatures; activities and their wire payloads move to \
        FernletSocial
        """)
    /// The serializer's feature domains.
    static let serializerFeatureDomains = Self(exit: .a04, why: """
        the canonical serializer's activity and moderation domains, which leave with those features
        """)

    // Rule 3: payload vocabulary (A0.3).

    /// The trainer export body's format token.
    static let trainerExportFormat = Self(exit: .a03, why: """
        the coach channel's trainer-export body format, declared and checked: payload vocabulary of \
        the coach profile, which plan §3.2 puts in FernletConnections with the rest of A0.3's vocabulary
        """)

    // Rule 3: feature values (A0.4).

    /// The heart-drop keychain service.
    static let heartDropService = Self(exit: .a04, why: """
        the heart-drop keychain service (HeartPrekeyStore.keychainService), beside which the mesh \
        scopes derive their own; hearts move to FernletSocial
        """)
    /// The moderation keychain service.
    static let moderationService = Self(exit: .a04, why: """
        the moderation ban store's keychain service; moderation moves to FernletSocial
        """)
    /// The default support folder.
    static let supportDirectory = Self(exit: .a04, why: """
        ProximitySupportLayout.defaultDirectory's folder, Application Support/Fernlet: the default \
        root of the heart-drop scope and the feature ledgers (the mesh stores read the namespace's \
        directoryName since A0.2.8); it leaves with those features
        """)
    /// The heart payload's format token.
    static let heartFormat = Self(exit: .a04, why: """
        the heart payload's format, checked on receipt; presence moves to FernletSocial
        """)
    /// The clothing catalog's format token.
    static let clothingFormat = Self(exit: .a04, why: """
        the clothing catalog payload's format, declared and checked; the clothing shop and its wire \
        payload move to FernletSocial
        """)
    /// The moderation report's format token.
    static let moderationFormat = Self(exit: .a04, why: """
        the moderation report payload's format, declared and its decode fallback; moderation moves to \
        FernletSocial
        """)
    /// An activity payload's format token.
    static let activityFormat = Self(exit: .a04, why: """
        an activity payload's format, declared and checked; activities' wire payloads move to \
        FernletSocial
        """)
    /// The recipe-share payload's format token.
    static let recipeFormat = Self(exit: .a04, why: """
        the recipe-share payload's format, declared and checked; the recipe-share manager and the \
        recipe wire types move to FernletSocial
        """)
    /// The recipe-share manager's status copy.
    static let recipeShareCopy = Self(exit: .a04, why: """
        unlocalized English status or diagnostic copy that names the app; the recipe-share manager \
        moves to FernletSocial
        """)

    // Rule 3: everything else (A1).

    /// A UI-test launch-environment key.
    static let uiTestHook = Self(exit: .a1, why: """
        a DEBUG-only UI-test launch-environment key (TestHookBoundaryTests' FERNLET_UI_TEST_ family): \
        the engine keeps its test seams through A0.5, so the name is settled when the package leaves \
        Fernlet's tree
        """)
    /// A mesh diagnostic launch-environment key.
    static let meshDebugHook = Self(exit: .a1, why: """
        a DEBUG-only mesh diagnostic launch-environment key (TestHookBoundaryTests' FERNLET_MESH \
        family): it stays with the transport, so the name is settled when the package leaves Fernlet's \
        tree
        """)
}
