// ProximityNamespaceBoundaryTests.swift
// FernletTests
//
// The wall that keeps ProximityKit's split from eroding (Docs/Plan-FernletCoach-ProximityKit-2026-10-01.md
// §4 A0.2 to A0.4). ProximityKit reads every protocol label and radio value, the QR scheme, the
// identity's and the two mesh seal keys' keychain rows, the storage names, the log subsystem, the
// radios' presentation strings and the payload vocabulary off the namespace its host hands down
// (`ProximityNamespace`; Fernlet's is `.fernlet`, in FernletConnections), and shows a peer's name
// under the namespace's peer-name policy; it asks its host's trust store and per-connection session
// policy its trust questions, records its own audit type and reports its own inspector values. The
// compiler does not keep it that way: a ProximityKit file that builds a namespace of its own,
// reaches for one of FernletCrypto's purposes again, spells a new Fernlet string, names one of
// Fernlet's domain types again or opens a `package` door compiles clean and passes every other test.
// So this suite reads ProximityKit's source and holds five lines:
//
//   1. no namespace, namespace group or purpose is built in ProximityKit outside `Namespace/`;
//   2. `FernletCryptoPurpose` is named in ProximityKit code only on the feature lines that leave with
//      their features (A0.4) or with the mesh manager's feature parts (A0.5), an exact per-file
//      allowlist (19 lines in 6 files);
//   3. every remaining string literal in ProximityKit code that contains `fernlet` (any case) is on an
//      exact per-file allowlist that names why it is still there and the plan step that removes it
//      (35 literals on 34 lines in 11 files);
//   4. Fernlet's domain vocabulary and records, FernletDomainModel's `PayloadType`,
//      `ProximityCapability`, `ProximityMode`, `ItemNameModeration`, `ProximityTrustedPeerRecord`,
//      `TrainerAuditEvent` and `ConnectionSessionLog`, are named in ProximityKit code only on an exact
//      per-file, per-type allowlist of the lines that leave with their features (A0.4), with the mesh
//      manager's feature parts (A0.5), with the recipe profile (A0.7) or with the session profile
//      (A0.7 / C5): 58 lines in 8 files;
//   5. `package` is declared in ProximityKit code only on an exact per-file list of the doors a named
//      later step reshapes or closes, each row with that step (44 lines in 6 files).
//
// Rules 2 to 5 are ratchets. A new use fails; a use that goes away fails too, until its row is
// lowered or deleted. So rules 2 to 4 only shrink, to nothing, as A0.4, A0.5, A0.7, A0.7 / C5 and A1
// land, and a `package` door's row lives exactly as long as the door.
// Between them they hold what ProximityKit still takes from Fernlet rather than from its host: the
// labels, payload type and format, hearts capability and friend records of the heart dead-drop and
// presence, the sealed-backup escrow's labels, the
// heart-drop keychain service and the support folder (until A0.4); what the mesh manager builds,
// decodes or calls (the clothing shop, the activity manager and the moderation report relay, with
// their payload formats, their labels and the canonical serializer's domains for them) and its own
// feature sends, capability list and session hearts, with the two typed capability gates and the
// host's trusted-peer list (until A0.5); the recipe-share manager, its wire types and status copy,
// and the typed doors only it and Fernlet's features go through, the envelope's typed view of its
// token and the coordinator's typed send (until A0.7); the session mode (until A0.7 / C5); and the
// DEBUG test-hook names (until A1). A0.3's rows are gone, and their exit step with them: no
// presentation string, membership record kind, routed-type token or coach-channel format is on rule
// 3's list. Rule 5 holds the other direction, the doors ProximityKit opens to Fernlet's own modules
// while a later step reshapes what is behind them: the presence radio's seam, its QUIC conformer,
// the peer channel the seam names, the epoch posture and the TXT vocabulary, which Fernlet's
// presence manager drives (until A1); the coordinator's typed send and manual commit, which
// presence's heart delivery and the recipe-share manager call (until A0.7); and the naive JSON
// sidecar FernletSocial's moderation, closeness and friend-state ledgers persist through, which the
// activity manager and the mesh's photo-wall preferences still use here (until A0.5).

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
/// lines that leave with their features or the mesh manager's feature parts, spells `fernlet` only in
/// the literals its allowlist names, names Fernlet's domain vocabulary and records only on the lines
/// that leave with their features, the mesh manager's feature parts or the recipe and session
/// profiles, and declares `package` only on the doors its list names.
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
    /// namespace carries. Every way to build one is a pattern in ``constructionPatterns`` (the host's
    /// one mint, `featureKeyDerivationSalt(_:)`, among them: a feature salt ProximityKit minted for
    /// itself would be a label no host declared), and so is the place the patterns cannot see: an
    /// extension of, or alias for, a namespace type outside the folder, where an unqualified
    /// initializer or `Self(` would build one by a name too short to search for. The scan reads code
    /// only (comments and literal text removed), so prose about these spellings is never a violation.
    /// Its floors fail an empty scan: it must read the module, find the folder, and find there the
    /// constructions the patterns exist to catch (`Namespace/` mints each of the 39 labels with
    /// `ProximityCryptographicPurpose(_:role:)`).
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
    /// - The host's feature-salt mint, `featureKeyDerivationSalt(_:)`, however it is reached.
    /// - An extension of, or a typealias for, a namespace type.
    ///
    /// ``everyConstructionPatternSeesItsFormAndNoNeighbour()`` holds each pattern to a sample it must
    /// match and to the near neighbours in today's code it must not.
    private static let constructionPatterns: [(name: String, pattern: String)] = [
        ("ProximityNamespace(", #"(?<![A-Za-z0-9_.])ProximityNamespace\s*(?:\.\s*init\s*)?\("#),
        ("ProximityCryptographicPurpose(",
         #"(?<![A-Za-z0-9_.])ProximityCryptographicPurpose\s*(?:\.\s*init\s*)?\("#),
        ("a namespace group's initializer",
         #"(?<![A-Za-z0-9_.])(?:ProximityNamespace\s*\.\s*)?(?:Signature|KeyDerivation|AEAD|Hash|Radios|Radio|VerifyQR|Family|Purposes|FeaturePurposes|Installation|Keychain|Storage|PeerNames|Vocabulary|SessionMessages|SessionMessage|Heartbeat|PayloadRules|Capabilities|MembershipRecordKinds|RoutedTypes|MeshMessages)\s*(?:\.\s*init\s*)?\("#),
        ("a keychain row's initializer",
         #"(?<![A-Za-z0-9_.])(?:(?:ProximityNamespace\s*\.\s*)?Keychain\s*\.\s*Row|(?:(?:ProximityNamespace\s*\.\s*)?Keychain\s*\.\s*)?IdentityRows)\s*(?:\.\s*init\s*)?\("#),
        ("LegacyV1.accepted(", #"(?<![A-Za-z0-9_])accepted\s*\(\s*identityEnvelopeV1\s*:"#),
        ("ProximityNamespace.validated(", #"(?<![A-Za-z0-9_])validated\s*\(\s*family\s*:"#),
        ("a namespace initializer's shorthand .init(",
         #"\.\s*init\s*\(\s*(?:family|purposes|signature|identityEnvelopeV2|proximityTransportV1|proximityTransportV2|meshInventoryDigestV1|mesh|serviceType|urlScheme|keychain|identity|service|directoryName|maxLength|session|identityIntroduction|payloadType|known|admission|photo|descriptor)\s*:"#),
        ("the purpose initializer's shape",
         #"(?:\(\s*""|\.\s*init\s*\(\s*[^\s,():]+)\s*,\s*role\s*:"#),
        ("a feature purpose's mint", #"(?<![A-Za-z0-9_])featureKeyDerivationSalt\s*\("#),
        ("an extension of a namespace type",
         #"(?<![A-Za-z0-9_])extension\s+(?:ProximityNamespace|ProximityCryptographicPurpose)(?![A-Za-z0-9_])"#),
        ("a typealias for a namespace type",
         #"(?<![A-Za-z0-9_])typealias\s+\w+\s*=\s*(?:ProximityNamespace|ProximityCryptographicPurpose)(?![A-Za-z0-9_])"#)
    ]

    /// Rule 1's patterns, fixtured both ways, because the matcher is the wall: each sees its own
    /// construction forms (named, `.init`, shorthand, wrapped), and none sees the nearest code in
    /// today's tree that is not a construction — another type's nested `Radio(`, the transport's calls
    /// that pass a `role:`, a shorthand `.init(` of another type, a namespace field read, a hash, the
    /// session-message store, heartbeat payload and schedule and capability list whose names hold a
    /// vocabulary group's, the descriptor payload and a role's token lookup beside the mesh
    /// messages' first label and type, the peer-name coercion, the sanitizer and the name display
    /// beside the peer-name policy's type and first label, and the salt role's switch arm and
    /// argument, a comment naming the feature-salt mint, the pair-secret door's call and the feature
    /// group's read beside the feature group and its mint. Every sample is lexed first, as the
    /// module's files are.
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
            ("a namespace group's initializer", "let mesh = ProximityNamespace.MeshMessages(descriptor: d, admissionGrant: g)"),
            ("a namespace group's initializer", "let names = ProximityNamespace.PeerNames(maxLength: 24, floor: f)"),
            ("a keychain row's initializer", "let row = ProximityNamespace.Keychain.Row(service: s, account: a)"),
            ("a keychain row's initializer", "let rows = IdentityRows(service: s, signingPrivateKey: k)"),
            ("LegacyV1.accepted(", #"legacyV1: .accepted(identityEnvelopeV1: "a", meshAdmissionTokenV1: "b")"#),
            ("ProximityNamespace.validated(", "let n = try ProximityNamespace.validated(family: f, installation: i)"),
            ("a namespace initializer's shorthand .init(", "let r: ProximityNamespace.Radio = .init(serviceType: s, alpn: a)"),
            ("a namespace initializer's shorthand .init(",
             "let rules: ProximityNamespace.PayloadRules = .init(known: k, sealingRequired: s)"),
            ("a namespace initializer's shorthand .init(",
             "let mesh: ProximityNamespace.MeshMessages = .init(descriptor: d, admissionGrant: g)"),
            ("a namespace initializer's shorthand .init(",
             "let names: ProximityNamespace.PeerNames = .init(maxLength: 24, floor: f)"),
            ("the purpose initializer's shape", #"Self("x.v1", role: .aeadAssociatedData)"#),
            ("the purpose initializer's shape", "let p: ProximityCryptographicPurpose = .init(spelling, role: .columnSeal)"),
            ("a namespace group's initializer", #"let f = ProximityNamespace.FeaturePurposes(["pairV1": salt])"#),
            ("a feature purpose's mint", #"let p = ProximityCryptographicPurpose.featureKeyDerivationSalt("x.v1")"#),
            ("a feature purpose's mint", #"let p: ProximityCryptographicPurpose = .featureKeyDerivationSalt("x.v1")"#),
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
            "capabilities: localCapabilities(),",
            "await sendMeshDescriptor(to: slot); let payload = MeshStateChangePayload(descriptor: mesh)",
            "func token(in mesh: ProximityNamespace.MeshMessages) -> String { mesh.descriptor }",
            "let name = ProximityDisplayName.peerDisplayName(raw, in: namespace)",
            "let shown = ProximityDisplayName.sanitized(raw, maxLength: namespace.installation.peerNames.maxLength)",
            "let name = PeerNameDisplay.personName(raw, fingerprint: nil, in: namespace)",
            "case .keyDerivationSalt, .columnSeal, .aeadAssociatedData, .tlsExporterLabel:",
            "let salt = ProximityCryptographicPurpose.Role.keyDerivationSalt",
            "role: .keyDerivationSalt",
            "/// Mint a salt with featureKeyDerivationSalt(_:) and declare it in the feature group.",
            "let secret = try identity.pairSecret(with: peerKey, purpose: purpose)",
            "guard purpose.role == .keyDerivationSalt, purposes.feature.declares(purpose) else {"
        ]
        // R2: bounded by the neighbour and pattern lists.
        for source in neighbours {
            let code = SwiftSourceLexer.lex(source).code
            let matched = patterns.filter { !Self.matchLines(of: $0.value, in: code).isEmpty }.map(\.key)
            #expect(matched.isEmpty, "\(matched) read a construction in: \(source)")
        }
    }

    // MARK: Rule 2: FernletCryptoPurpose only on the feature lines

    /// `FernletCryptoPurpose` is named in ProximityKit code only on the feature lines that leave with
    /// their features: exactly ``featurePurposeLines``, file by file, line count and purposes read.
    ///
    /// Every protocol label ProximityKit reads is the namespace's. What is left are the 12 feature
    /// labels, on 19 code lines in 6 files, each row with the step its lines leave at: the heart
    /// dead-drop's, presence's and the sealed-backup escrow's with their features in plan step A0.4,
    /// and the activities' and the moderation report's, with the canonical
    /// serializer's domains for them, with the mesh manager's feature parts in A0.5, because the mesh
    /// manager decodes those payloads and calls their signers. A new line fails, and so does a
    /// protocol purpose read again on a line that was a feature's; a line that goes away fails until
    /// its count is lowered or its row deleted, so the list only shrinks and reaches nothing at A0.5.
    /// Comments may name the registry; only code lines count.
    @Test func fernletCryptoPurposeIsNamedOnlyOnTheFeatureLinesThatLeave() throws {
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
        "Moderation/ModerationReportRelay.swift": FeaturePurposeLines(
            lines: 2, purposes: ["Signature.moderationReportV2"], reason: .moderationReportLabels),
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
    /// Every Fernlet value ProximityKit's protocol reads is the host namespace's, and so are the
    /// presentation strings the radios and the name display read, the membership record kinds the
    /// inventory digest hashes and the routed types the routed type registry builds its rows from,
    /// while the coach channel's trainer-export body is FernletConnections'. What is left is spelled
    /// in place for a reason each row names, with the plan step that takes it out: the features'
    /// values (A0.4), the values of what the mesh manager builds or decodes (A0.5) and of the
    /// recipe-share manager (A0.7), and DEBUG test-hook names (A1). A new Fernlet string fails here:
    /// it belongs in the host's namespace, or in the feature's own module. A row whose literal is gone
    /// fails until it is deleted, so the list stays the exact set (35 literals on 34 lines in 11
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
        FernletLiteral("Wire/RecipeSharePayloads.swift", "fernlet.proximity.recipe", 2, .recipeFormat)
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

    // MARK: Rule 4: Fernlet's domain types only on the lines that leave

    /// Fernlet's domain vocabulary and records (``domainTypeNames``) are named in ProximityKit code
    /// only on the lines ``domainTypeLines`` lists, file by file and type by type, each row with the
    /// plan step it leaves at.
    ///
    /// ProximityKit's core takes none of them from Fernlet: it reads every payload and capability
    /// token off the namespace its host hands down, asks the host's trust store and per-connection
    /// session policy its trust questions, records its own session audit, reports its own inspector
    /// values and sanitizes a peer's name with its own copy of the sanitizer, under the namespace's
    /// peer-name policy. What is left names a type on the lines of the feature files that leave in
    /// A0.4 (the heart dead-drop and presence); on the activity manager and the mesh manager's feature
    /// parts, which leave in A0.5 with the typed doors only they go through (the two capability gates
    /// and the host's trusted-peer list); on the typed doors only Fernlet's features and the
    /// recipe-share manager go through (the envelope's typed view of its token and the coordinator's
    /// typed send), which leave with the recipe profile (A0.7); and on the session mode's alias, which
    /// generalizes with the connection profiles (A0.7 / C5): 58 code lines in 8 files when this rule
    /// landed. A new line fails, and so does a type named in a file whose rows name only others; a
    /// line that goes away fails until its row is lowered or deleted, so the list only shrinks. A type
    /// no row names (`TrainerAuditEvent`, `ConnectionSessionLog`) fails on its first line. Only code
    /// lines count: comments and literals may name the types, and an implicit member (`.friendHeart`)
    /// names none, so it is held at the typed door it passes through, which is on the list.
    @Test func fernletDomainTypesAreNamedOnlyOnTheLinesThatLeave() throws {
        let needles = try Self.domainTypeNeedles()
        let sources = try Self.proximitySources()
        var found: [String: [String: [Int]]] = [:]
        // R2: bounded by the module's file list.
        for source in sources {
            let mentions = Self.domainTypeMentions(in: source.lexed.code, matching: needles)
            if !mentions.isEmpty { found[source.path] = mentions }
        }
        #expect(sources.count >= 50, "the ProximityKit sweep read only \(sources.count) Swift files")
        var allowed: [String: [String: Int]] = [:]
        // R2: bounded by the allowlist.
        for row in Self.domainTypeLines {
            #expect(Self.domainTypeNames.contains(row.type), "\(row.file) lists \(row.type), no domain type")
            #expect(allowed[row.file]?[row.type] == nil, "\(row.file) lists \(row.type) twice")
            allowed[row.file, default: [:]][row.type] = row.lines
        }
        let files = Set(found.keys).union(allowed.keys).sorted()
        // R2: bounded by the union of two finite key sets.
        for file in files {
            let actual = (found[file] ?? [:]).mapValues(\.count)
            #expect(actual == (allowed[file] ?? [:]), """
                \(file): Fernlet's domain types are named on the code lines \(Self.describe(found[file] ?? [:])), \
                but the allowlist says \(Self.describeDomainRows(of: file)). ProximityKit's core takes \
                Fernlet's vocabulary from its host's namespace and asks its host's protocols for trust and \
                records, so a new line naming one of these types belongs in the host (FernletConnections) \
                or in its feature's own module; a line that left needs its row lowered or deleted here, so \
                the list stays exact.
                """)
        }
    }

    /// Rule 4's matcher, fixtured both ways, because the matcher is the wall: it sees each type in
    /// every form ProximityKit writes one (a parameter, an optional, a collection, a closure type, a
    /// member access, a module-qualified name, a nested type, an alias, an extension, a name on a
    /// line of its own), counts a line once per type however often it names it and once for each
    /// type it names, and sees none of today's nearest code that names no domain type: the
    /// envelope's raw token and its parked flag, the soundness rule's token fields, the mesh's roles,
    /// the namespace's payload rules and capabilities, the coordinator's own role, ranging mode and
    /// mode alias, the host's trust store and trusted-peer list, the session audit, the name
    /// coercion, the generic summary and encryption types, and a comment and a literal that spell
    /// the types. Every sample is lexed first, as the module's files are.
    @Test func theDomainTypeMatcherSeesEveryFormAndNoNeighbour() throws {
        let needles = try Self.domainTypeNeedles()
        let samples: [(source: String, expected: [String: [Int]])] = [
            ("public var payloadType: PayloadType? { PayloadType(rawValue: payloadTypeToken) }", ["PayloadType": [1]]),
            ("public func registerPayloadHandler(for type: PayloadType, handler: @escaping MeshPayloadHandler) {",
             ["PayloadType": [1]]),
            ("await sendFeatureEnvelope(FernletDomainModel.PayloadType.itemReport.rawValue, encodable: p, via: s)",
             ["PayloadType": [1]]),
            ("extension PayloadType: CustomStringConvertible {}", ["PayloadType": [1]]),
            ("capabilities.append(ProximityCapability.hearts.rawValue)", ["ProximityCapability": [1]]),
            ("public typealias Mode = ProximityMode", ["ProximityMode": [1]]),
            ("let cleanTitle = ItemNameModeration.sanitizedName(title)", ["ItemNameModeration": [1]]),
            ("@ObservationIgnored private let activeFriends: () -> [ProximityTrustedPeerRecord]",
             ["ProximityTrustedPeerRecord": [1]]),
            ("public var queueAwayHeart: ((ProximityTrustedPeerRecord) -> Bool)?", ["ProximityTrustedPeerRecord": [1]]),
            ("func recordTrainerAudit(_ event: TrainerAuditEvent) {", ["TrainerAuditEvent": [1]]),
            ("let record = ConnectionSessionLog.EnvelopeRecord(direction: .sent)", ["ConnectionSessionLog": [1]]),
            ("func gate(_ type: PayloadType, _ capability: ProximityCapability) -> ProximityMode",
             ["PayloadType": [1], "ProximityCapability": [1], "ProximityMode": [1]]),
            ("func send(\n    _ type:\n        PayloadType,\n    to friend: ProximityTrustedPeerRecord\n)",
             ["PayloadType": [3], "ProximityTrustedPeerRecord": [4]])
        ]
        // R2: bounded by the sample list.
        for sample in samples {
            let mentions = Self.domainTypeMentions(in: SwiftSourceLexer.lex(sample.source).code, matching: needles)
            #expect(mentions == sample.expected, "the matcher read \(mentions) in: \(sample.source)")
        }
        #expect(Set(samples.flatMap { $0.expected.keys }) == Set(Self.domainTypeNames),
                "a domain type has no sample the matcher must see")
        let neighbours = [
            "let token = envelope.payloadTypeToken",
            "public var isUnknownPayloadType: Bool { payloadType == nil }",
            "var violations = duplicatePairs(vocabulary.session.payloadTypeFields, duplicate)",
            "let role = MeshPayloadRole.role(for: token, in: namespace.family.vocabulary.mesh)",
            "let rules: ProximityNamespace.PayloadRules = vocabulary.payloads",
            "func supports(_ token: String, in host: ProximityNamespace.Capabilities) -> Bool {",
            "public typealias Role = ProximityRole",
            "public typealias RangingMode = ProximityRangingMode",
            "func beginSession(role: ProximityCoordinator.Role, mode: ProximityCoordinator.Mode, localFingerprint: String)",
            "var proximityTrustStore: any ProximityTrustStore { get }",
            "let eligible = Self.eligibleFriends(in: store.trustedProximityPeers)",
            "func recordSessionAudit(_ audit: ProximitySessionAudit)",
            "let name = ProximityDisplayName.peerDisplayName(raw, in: namespace)",
            "payloadEncryption: PayloadEncryption = .none, payloadSummary: PayloadSummary,",
            "/// Fernlet's typed view: the `PayloadType` case it spells, as `ProximityMode` does.",
            #"#expect(name == "ConnectionSessionLog", "a TrainerAuditEvent row")"#
        ]
        // R2: bounded by the neighbour list.
        for source in neighbours {
            let mentions = Self.domainTypeMentions(in: SwiftSourceLexer.lex(source).code, matching: needles)
            #expect(mentions.isEmpty, "\(mentions.keys.sorted()) read a domain type in: \(source)")
        }
    }

    /// FernletDomainModel's types for Fernlet's payload vocabulary, session mode, item-name rules and
    /// persisted proximity records: what ProximityKit's core takes from its host, or does without.
    static let domainTypeNames = [
        "PayloadType", "ProximityCapability", "ProximityMode", "ItemNameModeration",
        "ProximityTrustedPeerRecord", "TrainerAuditEvent", "ConnectionSessionLog"
    ]

    /// Each of ``domainTypeNames`` as a whole identifier: no letter, digit or underscore on either
    /// side, so `payloadTypeToken` and `isUnknownPayloadType` are not it, and a module-qualified or
    /// nested use is.
    private static func domainTypeNeedles() throws -> [(name: String, regex: NSRegularExpression)] {
        try domainTypeNames.map { name in
            (name: name, regex: try NSRegularExpression(pattern: #"(?<![A-Za-z0-9_])"# + name + #"(?![A-Za-z0-9_])"#))
        }
    }

    /// The 1-based lines of lexed `code` that name each needle's type, by name, each list sorted and
    /// without repeats; a type `code` never names has no entry.
    private static func domainTypeMentions(
        in code: String, matching needles: [(name: String, regex: NSRegularExpression)]
    ) -> [String: [Int]] {
        var mentions: [String: [Int]] = [:]
        // R2: bounded by the needle list.
        for needle in needles {
            let lines = Set(matchLines(of: needle.regex, in: code)).sorted()
            if !lines.isEmpty { mentions[needle.name] = lines }
        }
        return mentions
    }

    /// One file's code lines naming one of Fernlet's domain types.
    struct DomainTypeLines: Sendable {
        /// The file, by path under the module root.
        let file: String
        /// The type, one of ``domainTypeNames``.
        let type: String
        /// How many of the file's code lines name it.
        let lines: Int
        /// Why the lines are still here, and the step that removes them.
        let reason: Reason

        init(_ file: String, _ type: String, _ lines: Int, _ reason: Reason) {
            self.file = file
            self.type = type
            self.lines = lines
            self.reason = reason
        }
    }

    /// Every file and type whose code lines still name one of Fernlet's domain types.
    static let domainTypeLines: [DomainTypeLines] = [
        DomainTypeLines("Activities/ProximityActivityManager.swift", "PayloadType", 1, .activitySend),
        DomainTypeLines("Activities/ProximityActivityManager.swift", "ItemNameModeration", 8, .activityNames),
        DomainTypeLines("Engine/ProximityCoordinator.swift", "PayloadType", 1, .coordinatorTypedSend),
        DomainTypeLines("Engine/ProximityCoordinator.swift", "ProximityCapability", 1, .peerCapabilityGate),
        DomainTypeLines("Engine/ProximityCoordinator.swift", "ProximityMode", 1, .sessionMode),
        DomainTypeLines("HeartSharing/HeartDropService.swift", "PayloadType", 1, .heartDropEnvelope),
        DomainTypeLines("HeartSharing/HeartDropService.swift", "ProximityTrustedPeerRecord", 8, .heartDropFriends),
        DomainTypeLines("Mesh/MeshNetworkManager.swift", "PayloadType", 6, .meshFeatureSends),
        DomainTypeLines("Mesh/MeshNetworkManager.swift", "ProximityCapability", 8, .meshCapabilityList),
        DomainTypeLines("Mesh/MeshNetworkManager.swift", "ProximityTrustedPeerRecord", 3, .meshSessionHearts),
        DomainTypeLines("Mesh/MeshSessionTypes.swift", "ProximityCapability", 1, .seatCapabilityGate),
        DomainTypeLines("Presence/PresenceManager.swift", "ProximityCapability", 1, .presenceCapability),
        DomainTypeLines("Presence/PresenceManager.swift", "ProximityTrustedPeerRecord", 14, .presenceFriends),
        DomainTypeLines("ProximityHost.swift", "ProximityTrustedPeerRecord", 1, .hostTrustedPeers),
        DomainTypeLines("Wire/FernletIdentityEnvelope.swift", "PayloadType", 3, .envelopeTypedView)
    ]

    /// `file`'s rule-4 rows with their counts and exit steps, for a failure message.
    private static func describeDomainRows(of file: String) -> String {
        let rows = domainTypeLines.filter { $0.file == file }
            .map { "\($0.type) on \($0.lines) (until \($0.reason.exit.rawValue))" }
        return rows.isEmpty ? "none" : rows.joined(separator: ", ")
    }

    // MARK: Rule 5: package only on the listed lines

    /// `package` is declared in ProximityKit code only on the lines ``packageDeclarationLines``
    /// lists, file by file and count by count, each row with the plan step that closes its doors.
    ///
    /// `package` access reaches every target of FernletKit, and the test target through
    /// `@testable import`, but never the app: it is the access a Fernlet module inside the package
    /// uses a ProximityKit declaration through while a named later step (A0.5, A0.7 or A1) reshapes
    /// or replaces it, so it is debt with an exit, never a settled seam (a settled seam is `public`,
    /// with its contract). Nothing else counts that debt: a widened declaration compiles clean
    /// wherever it is used. So the list is exact both ways, like rules 2 to 4: a new `package` line
    /// fails until a row names why it is there and its exit, and a line that goes away fails until
    /// its row is lowered or deleted, so no door outlives its step unnoticed. ProximityKit declares
    /// `package` on 44 code lines in 6 files: the presence radio's doors (36 lines in 4 files, until
    /// A1), the coordinator's two (until A0.7) and the JSON sidecar's six (until A0.5). Only code
    /// lines count, each once (``packageDeclarationPattern``): comments and literals may say
    /// `package` freely.
    @Test func packageIsDeclaredOnlyOnTheListedLines() throws {
        let matcher = try NSRegularExpression(pattern: Self.packageDeclarationPattern)
        let sources = try Self.proximitySources()
        var found: [String: Int] = [:]
        var linesRead = 0
        // R2: bounded by the module's file list.
        for source in sources {
            linesRead += source.lexed.code.count(where: { $0 == "\n" }) + 1
            let lines = Set(Self.matchLines(of: matcher, in: source.lexed.code))
            if !lines.isEmpty { found[source.path] = lines.count }
        }
        #expect(sources.count >= 50, "the ProximityKit sweep read only \(sources.count) Swift files")
        #expect(linesRead >= 20_000, "the ProximityKit sweep read only \(linesRead) lines")
        let paths = Set(found.keys).union(Self.packageDeclarationLines.keys).sorted()
        // R2: bounded by the union of two finite key sets.
        for path in paths {
            let allowed = Self.packageDeclarationLines[path]
            let actual = found[path] ?? 0
            #expect(actual == (allowed?.lines ?? 0), """
                \(path) declares `package` on \(actual) code lines; the list says \(allowed?.lines ?? 0)\
                \(allowed.map { ", closing at \($0.reason.exit.rawValue)" } ?? ""). A new `package` door \
                needs a row naming why a Fernlet module needs it and the plan step that closes it (a \
                settled seam is `public`, with its contract); a door that closed needs its row lowered \
                or deleted here, so the list stays exact.
                """)
        }
    }

    /// Rule 5's matcher, fixtured both ways, because the matcher is the wall: it sees a `package`
    /// declaration of every kind a door can be (a type, a protocol, a function, a property, an
    /// initializer), behind an attribute and before the modifiers a widened declaration keeps
    /// (`nonisolated`, `static`, the setter access of `private(set)`), and sees none of the nearest
    /// code that declares nothing `package`: a manifest's `let package = Package(`, a comment and a
    /// literal that spell the word, an identifier that begins with it, an enum case named for it, and
    /// a setter-access declaration with no `package` before it. Every sample is lexed first, as the
    /// module's files are.
    @Test func thePackageMatcherSeesEveryDeclarationAndNoNeighbour() throws {
        let matcher = try NSRegularExpression(pattern: Self.packageDeclarationPattern)
        let samples = [
            "package struct JSONSidecarFile<State: Codable> {",
            "package nonisolated static func fileURL(in directory: URL, name: String) -> URL {",
            "package init(fileURL: URL) {",
            "@MainActor package protocol PresenceRadioSession: AnyObject {",
            "package var onPeerDiscovered: ((PeerHandle) -> Void)?",
            "package private(set) var isRunning = false"
        ]
        // R2: bounded by the sample list.
        for sample in samples {
            let lines = Self.matchLines(of: matcher, in: SwiftSourceLexer.lex(sample).code)
            #expect(lines == [1], "the package matcher read \(lines) in: \(sample)")
        }
        let neighbours = [
            "let package = Package(",
            "/// a package door",
            #""package""#,
            "packageName",
            "case package",
            "private(set) var isRunning = false"
        ]
        // R2: bounded by the neighbour list.
        for source in neighbours {
            let lines = Self.matchLines(of: matcher, in: SwiftSourceLexer.lex(source).code)
            #expect(lines.isEmpty, "the package matcher read a declaration on \(lines) in: \(source)")
        }
    }

    /// Rule 5's matcher over lexed code: `package` as a whole word (no identifier character and no
    /// `.` before it), then whitespace, any of the declaration and storage modifiers a widened
    /// declaration may keep before its keyword (the setter-access ones included, so a widened
    /// `package private(set) var` is counted, never missed), then a declaration keyword.
    static let packageDeclarationPattern =
        #"(?<![A-Za-z0-9_.])package(?=\s+(?:(?:nonisolated|nonisolated\(unsafe\)|static|final|override|mutating|convenience|required|lazy|weak|unowned|dynamic|indirect|private\(set\)|fileprivate\(set\)|internal\(set\))\s+)*(?:func|var|let|init|struct|class|enum|actor|protocol|typealias|subscript|extension)\b)"#

    /// One file's `package` declaration lines.
    struct PackageLines: Sendable {
        /// How many of the file's code lines declare `package`.
        let lines: Int
        /// Why the doors are open, and the step that closes them.
        let reason: Reason
    }

    /// Every file whose code declares `package`, by path under the module root, each row with the
    /// step that closes its doors: the presence radio's seam, its QUIC conformer, the peer channel the
    /// seam names, the epoch posture and the TXT vocabulary (A1), the coordinator's typed send and
    /// manual commit (A0.7), and the JSON sidecar FernletSocial's ledgers persist through (A0.5).
    static let packageDeclarationLines: [String: PackageLines] = [
        "Engine/ProximityCoordinator.swift": PackageLines(lines: 2, reason: .coordinatorDoors),
        "Presence/PresenceAdvertisement.swift": PackageLines(lines: 4, reason: .presenceRadioSeam),
        "Presence/PresenceEpochPosture.swift": PackageLines(lines: 5, reason: .presenceRadioSeam),
        "Support/JSONSidecarFile.swift": PackageLines(lines: 6, reason: .sidecarFileShare),
        "Transport/NetworkMeshSession.swift": PackageLines(lines: 12, reason: .presenceRadioSeam),
        "Transport/NetworkPresenceSession.swift": PackageLines(lines: 15, reason: .presenceRadioSeam)
    ]

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
        /// Fernlet's features still here leave for FernletSocial (A0.4): the heart dead-drop and
        /// presence, with the sealed-backup escrow leaving for the App.
        case a04 = "A0.4"
        /// The routed mesh manager is split and its feature parts leave (A0.5), and with them what it
        /// builds, decodes or calls: the clothing shop, the activity manager and the moderation report
        /// relay, with their wire payloads' formats, their labels and the canonical serializer's
        /// domains for them (rules 2 and 3), and the mesh manager's own feature sends, capability list
        /// and session hearts with the two typed capability gates and the host's trusted-peer list,
        /// which only features read (rule 4), and the JSON sidecar's `package` door that FernletSocial's
        /// ledgers persist through (rule 5), which moves to FernletSocial with the activity manager
        /// and the mesh's photo-wall preferences.
        case a05 = "A0.5"
        /// The one-to-one radio becomes a profile-driven pair session (A0.7): the recipe-share
        /// manager, its wire types and the doors only it and its radio still go through leave with
        /// the recipe profile, and so do the coordinator's two `package` doors (rule 5), the typed
        /// send and the manual commit that presence's heart delivery and the recipe-share manager
        /// call, which the pair session's send and commit replace.
        case a07 = "A0.7"
        /// The pair session's coach profile arrives (A0.7 / C5): the connection profiles that
        /// Fernlet's session mode generalizes into. Only the session mode leaves here.
        case a07c5 = "A0.7 / C5"
        /// The package leaves Fernlet's tree (A1): the DEBUG test-hook names are settled then, and so
        /// are the presence radio's `package` doors (rule 5): its seam, its QUIC conformer, the peer
        /// channel the seam names, the epoch posture and the TXT vocabulary, published as mechanism
        /// or wrapped by a presence engine.
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

    // Rule 2: the feature labels that leave with their features (A0.4).

    /// Hearts' labels.
    static let heartLabels = Self(exit: .a04, why: """
        hearts: the sealed drop's HKDF salt and the sidecar's authenticated data; the heart dead-drop \
        moves to FernletSocial, which names the registry's purposes itself
        """)
    /// IdentityService's feature derivations.
    static let identityFeatureDerivations = Self(exit: .a04, why: """
        IdentityService's feature derivations: the heart-drop and presence pair secrets become the \
        generic `pairSecret(with:purpose:)` under the host's declared feature salts and their tags \
        move to FernletSocial with their features, and the sealed-backup escrow's two HKDF info labels \
        leave with the escrow for the App's backup side
        """)

    // Rule 2: the labels of what the mesh manager decodes and calls (A0.5).

    /// The report relay's label.
    static let moderationReportLabels = Self(exit: .a05, why: """
        the moderation report's signature, signed and verified in the report relay that the mesh \
        manager calls (its moderation handler decodes the report and verifies its rows, its send \
        builds the payload under the mesh's own identity); the relay leaves with the mesh manager's \
        feature parts
        """)
    /// Activities' labels.
    static let activityLabels = Self(exit: .a05, why: """
        activities' join-token and roster signatures, in the payloads the mesh manager decodes and \
        the activity manager it builds signs; they leave with the mesh manager's feature parts
        """)
    /// The serializer's feature domains.
    static let serializerFeatureDomains = Self(exit: .a05, why: """
        the canonical serializer's activity and moderation domains, on the internal \
        `CanonicalByteWriter`, whose only callers are the activity payloads and the report relay; \
        they leave with them
        """)

    // Rule 3: feature values (A0.4).

    /// The heart-drop keychain service.
    static let heartDropService = Self(exit: .a04, why: """
        the heart-drop keychain service (`HeartPrekeyStore.keychainService`), beside which the app \
        derives the mesh stores' services; the prekey store moves to FernletSocial with that \
        derivation
        """)
    /// The default support folder.
    static let supportDirectory = Self(exit: .a04, why: """
        ProximitySupportLayout.defaultDirectory's folder, Application Support/Fernlet: the default \
        root of the heart-drop scope (the mesh stores read the namespace's directoryName since \
        A0.2.8, and every ledger takes its file from its caller); it leaves with the heart dead-drop
        """)
    /// The heart payload's format token.
    static let heartFormat = Self(exit: .a04, why: """
        the heart payload's format, checked on receipt; presence moves to FernletSocial
        """)

    // Rule 3: the formats of what the mesh manager builds or decodes (A0.5).

    /// The clothing catalog's format token.
    static let clothingFormat = Self(exit: .a05, why: """
        the clothing catalog payload's format, declared and checked; the mesh manager builds the \
        shop, reads its rate limit and sends its catalog, so the shop and its wire payload leave with \
        the mesh manager's feature parts
        """)
    /// The moderation report's format token.
    static let moderationFormat = Self(exit: .a05, why: """
        the moderation report payload's format, declared and its decode fallback; the mesh manager \
        decodes the report and calls the relay, so both leave with the mesh manager's feature parts
        """)
    /// An activity payload's format token.
    static let activityFormat = Self(exit: .a05, why: """
        an activity payload's format, declared and checked; the mesh manager decodes all five, so \
        activities' wire payloads leave with the mesh manager's feature parts
        """)

    // Rule 3: the recipe profile (A0.7).

    /// The recipe-share payload's format token.
    static let recipeFormat = Self(exit: .a07, why: """
        the recipe-share payload's format, declared and checked; the recipe-share manager is written \
        against the recipe radio's internals that the profile-driven pair session replaces, so it and \
        the recipe wire types leave with the recipe profile
        """)
    /// The recipe-share manager's status copy.
    static let recipeShareCopy = Self(exit: .a07, why: """
        unlocalized English status or diagnostic copy that names the app; the recipe-share manager \
        leaves with the recipe profile
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

    // Rule 4: the feature files (A0.4).

    /// The dead-drop's heart envelope.
    static let heartDropEnvelope = Self(exit: .a04, why: """
        the dead-drop heart envelope's summary title, its payload type's token; hearts move to \
        FernletSocial
        """)
    /// The dead-drop's friends.
    static let heartDropFriends = Self(exit: .a04, why: """
        the dead-drop's friend records (who a heart is queued for, whose tags are scanned, who an \
        incoming heart may be from); hearts move to FernletSocial
        """)
    /// Presence's advertised capability.
    static let presenceCapability = Self(exit: .a04, why: """
        the hearts capability a presence heart connection advertises beside the host's wire2 token; \
        presence moves to FernletSocial
        """)
    /// Presence's friends.
    static let presenceFriends = Self(exit: .a04, why: """
        presence's friend records (epoch tags, heart eligibility, the heart connection, its retries and \
        the away fallback); presence moves to FernletSocial
        """)

    // Rule 4: the activity manager the mesh manager builds (A0.5).

    /// The activity manager's send hook.
    static let activitySend = Self(exit: .a05, why: """
        the activity manager's send hook (`ActivitySend`), typed by the payload type its feature sends; \
        the mesh manager builds the manager and wires the hook, so activities leave with the mesh \
        manager's feature parts
        """)
    /// The activities' names.
    static let activityNames = Self(exit: .a05, why: """
        an activity's title and location (feature content) and the display names it carries (a \
        joining peer's, as the join request and the roster keep it, and this device's own, as it hosts \
        or joins) pass FernletDomainModel's own sanitizer and fixed 24-character cap, with no floor \
        (`ItemNameModeration`), rather than the namespace's peer-name policy; activities leave with the \
        mesh manager's feature parts
        """)

    // Rule 4: the typed doors the recipe profile retires (A0.7).

    /// The coordinator's typed send.
    static let coordinatorTypedSend = Self(exit: .a07, why: """
        the coordinator's typed send (`sendPayload(type:summary:payload:sealed:)`), whose shipping \
        callers are the recipe-share manager's send and presence's heart delivery (the test target's \
        too); it leaves when the profile-driven pair session replaces the recipe radio's send, and the \
        coordinator's own messages are signed under the namespace's tokens
        """)
    /// The envelope's typed view of its token.
    static let envelopeTypedView = Self(exit: .a07, why: """
        Fernlet's typed view of the envelope's raw token (the `payloadType` read, the typed initializer \
        and the typed signing factory): `verify` and the engine's own messages read and sign the raw \
        token, and only Fernlet's features read or sign through the view; its last readers in \
        ProximityKit are the clothing shop (A0.5) and the recipe-share manager with the coordinator's \
        typed send (A0.7), so it leaves with the recipe profile
        """)

    // Rule 4: the mesh manager's feature parts (A0.5).

    /// The mesh manager's feature sends and registration.
    static let meshFeatureSends = Self(exit: .a05, why: """
        the mesh manager's feature sends under their payload tokens (the moderation relay, friend \
        state, the shop's catalog and request, the activity send hook) and the feature handler \
        registry's typed registration; the engine's own frames go by `MeshPayloadRole`, under the \
        namespace's mesh messages
        """)
    /// The mesh manager's capability list.
    static let meshCapabilityList = Self(exit: .a05, why: """
        the feature capabilities the mesh manager advertises, one per line (the wire2 token is the \
        host's); the capability list leaves with the mesh's feature parts
        """)
    /// The mesh manager's session hearts.
    static let meshSessionHearts = Self(exit: .a05, why: """
        the session heart's friend record (the send, its routed outcome and its failure); hearts and \
        the heart ceremony leave with the mesh's feature parts
        """)
    /// The coordinator's typed capability gate.
    static let peerCapabilityGate = Self(exit: .a05, why: """
        the features' typed capability gate on a peer's identity (`PeerIdentity.supports(_:in:)`'s \
        capability overload, which delegates to the token form); its callers are the mesh manager's \
        shop, moderation, friend-state and activity sends
        """)
    /// The seat's typed capability gate.
    static let seatCapabilityGate = Self(exit: .a05, why: """
        the features' typed capability gate on a seat (`PeerSlot.supports(_:in:)`'s capability \
        overload, which delegates to the token form); its callers are the mesh manager's activity and \
        heart parts
        """)
    /// The host's trusted-peer list.
    static let hostTrustedPeers = Self(exit: .a05, why: """
        the host's trusted-peer list (`ProximityHost.trustedProximityPeers`), in the host's persisted \
        type, which only features read: presence's tags, heart key and filed sender name (A0.4) and \
        the mesh's vouch list (A0.5); the core asks its trust questions through `ProximityTrustStore`
        """)

    // Rule 4: the session profile (A0.7 / C5).

    /// The coordinator's session mode.
    static let sessionMode = Self(exit: .a07c5, why: """
        the coordinator's `Mode` alias for Fernlet's session mode (trainer or friend): not a token but \
        a session profile, which selects the commit gate, remembered-trust auto-confirm and the \
        trainer size gate, so it generalizes with the connection profiles
        """)

    // Rule 5: the package doors (A1, A0.7, A0.5).

    /// The presence radio's doors.
    static let presenceRadioSeam = Self(exit: .a1, why: """
        the presence radio's seam, its QUIC conformer, the peer channel the seam's requirements name \
        and presence's heart connections build a coordinator over, its epoch posture and its TXT \
        vocabulary, which Fernlet's presence manager drives, from FernletSocial once presence moves \
        there; package access ends when ProximityKit leaves FernletKit, so by then the seam is \
        published as mechanism or wrapped by a presence engine
        """)
    /// The coordinator's doors.
    static let coordinatorDoors = Self(exit: .a07, why: """
        the coordinator's typed send and manual commit, which presence's heart delivery and the \
        recipe-share manager call; the pair session's API replaces them
        """)
    /// The JSON sidecar's door.
    static let sidecarFileShare = Self(exit: .a05, why: """
        the naive JSON sidecar, shared with FernletSocial's ledgers while the mesh's photo-wall \
        preferences and the activity manager still use it; it moves to FernletSocial with them
        """)
}
