// SwiftSourceLexerTests.swift
// FernletTests
//
// Fernlet's copy of the source walls' lexer (`SwiftSourceLexer.swift`, a twin of the copy in
// ProximityKit's package tests), held to its fixtures in a suite of its own on the s3-grep CI line. The
// fixture cell lived in ProximityKit's namespace wall, where it still holds the package's copy, until
// that wall joined ProximityKit's package tests (plan step A1.1.7); this suite holds the same fixtures
// to Fernlet's copy, which every FernletTests source wall reads code through, so that copy stays
// tested once the package leaves this repository and the two copies are no longer twins.

import Testing

/// Fernlet's copy of the source walls' lexer reads code, comments and literals as Swift does.
@Suite struct SwiftSourceLexerTests {

    /// The lexer reads code, comments and literals as Swift does: Fernlet's source walls (the
    /// key-custody, store-isolation, photo-directory, audit-bridge and continuation task-host walls, the
    /// platform wall's presence door and the feature golden's recipe-copy scan) are only as sharp as it
    /// is. The same fixtures as the namespace wall's lexer cell in ProximityKit's package tests, which
    /// holds the package's copy.
    ///
    /// Each fixture is a form Swift reads, chosen where a looser reading goes wrong: a quote in a comment,
    /// a comment inside a comment, an escaped quote, a literal inside an interpolation, a raw literal
    /// holding quotes and a `\(` that is text, a multi-line literal, whose line breaks the code must keep
    /// so every later line number stays true, and regex literals whose bodies would open a comment or a
    /// literal (an extended one holding `/*`, a multi-line one holding a quote and a short closing
    /// delimiter, a bare one holding an escaped `/` before a `*` and a quote, and bare ones right after
    /// `return`, `in` and `try?` with no blank, the first before an import), beside the `/`s that are
    /// code: operators declared with names that start with one (`func /(`, `func /=(` and
    /// `infix operator /+/`), a `/` whose closing `/` would open a comment, which Swift reads as no regex
    /// literal, so a later literal is read where it stands, the divisions, the compound assignment, the
    /// operator reference, and divisions after a member named `in` and after a name ending in it.
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
        let extended = SwiftSourceLexer.lex("let r = #/a/*/#\nimport CloudKit")
        #expect(extended.code == "let r = \"\"\nimport CloudKit")
        let hashed = SwiftSourceLexer.lex("let r = ##/\n  \" /#\n/##\nlet s = \"q\"")
        #expect(hashed.literals == [SwiftSourceLexer.Literal(line: 4, text: "q")])
        #expect(hashed.code == "let r = \"\n\n\"\nlet s = \"\"")
        let bare = SwiftSourceLexer.lex(#"let r = /a\/*"/"# + "\nimport CloudKit")
        #expect(bare.code == "let r = \"\"\nimport CloudKit")
        let keyword = SwiftSourceLexer.lex(#"func f() -> Regex<Substring> { return/a\/*/ }"# + "\nimport CloudKit")
        #expect(keyword.code == #"func f() -> Regex<Substring> { return"" }"# + "\nimport CloudKit")
        let tight = SwiftSourceLexer.lex(#"let k = s.map { c in/a"/ }, r = try?/b"/.wholeMatch(in: s)"#)
        #expect(tight.code == #"let k = s.map { c in"" }, r = try?"".wholeMatch(in: s)"#)
        #expect(tight.literals.isEmpty)
        let declared = "static func /(l: V, r: V) -> V { V(v: l.v/r.v) }\n"
            + "static func /=(l: inout V, r: V) { l.v = l.v/r.v }\ninfix operator /+/ : MultiplicationPrecedence"
        #expect(SwiftSourceLexer.lex(declared).code == declared)
        let closing = SwiftSourceLexer.lex("let y = /x//\"c\nlet z = (/x/*c*/)\nlet w = \"q\"")
        #expect(closing.code == "let y = /x\nlet z = (/x)\nlet w = \"\"")
        #expect(closing.literals == [SwiftSourceLexer.Literal(line: 3, text: "q")])
        let operators = "let q = a / b / c, w = a/b/c\nx /= 2.0/1.0\nlet v = [1.0].reduce(0, /)\n"
            + "let m = k.in/b/c, n = margin/b/c"
        #expect(SwiftSourceLexer.lex(operators).code == operators)
    }
}
