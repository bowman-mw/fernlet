//
//  AcknowledgmentsTests.swift
//  FernletTests
//
//  Settings → Privacy & data → Acknowledgments (the owner's pick, 2026-10-25). CryptoSwift's license
//  requires an acknowledgment in the product, asks every binary distribution to keep its notice, and
//  quotes one sentence every redistribution must retain; until this screen, nothing a user could see
//  carried any of it (NOTICE did, in the repository only). The website's technical page carries the
//  sentence too, and the Pages workflow checks that half without Xcode.
//

import Foundation
import CryptoKit
import Testing
import FernletDomainModel
@testable import Fernlet

/// Pins what the acknowledgments screen draws: the bundled CryptoSwift license is the pinned fork
/// tag's file unaltered, the required sentence reads out of it and matches NOTICE and the website,
/// every bundled font license is listed with its copyright, and Settings links and finds the screen.
@MainActor
@Suite
struct AcknowledgmentsTests {

    /// The sentence CryptoSwift's license tells every redistribution to retain, exactly.
    private static let requiredSentence =
        #"This product includes software developed by the "Marcin Krzyzanowski" (http://krzyzanowskim.com/)."#

    /// The fork tag the bundled license was copied from; its LICENSE is upstream 1.10.0's.
    private static let copiedFromTag = "1.10.0-fernlet.2"

    /// SHA-256 of LICENSE at bowman-mw/CryptoSwift tag 1.10.0-fernlet.2, measured 2026-10-25 (1,045
    /// bytes, byte-identical to krzyzanowskim/CryptoSwift's at 1.10.0).
    private static let forkLicenseSHA256 = "e4ea9188602dd4217309aec044481b0a7d2f9d539b1d1673b9a1809709c804e0"

    private static func bundledCryptoSwiftLicense() throws -> String {
        try #require(AcknowledgmentNotices.bundledText(AcknowledgmentNotices.cryptoSwiftLicenseResource, in: .main),
                     "CryptoSwift-LICENSE.txt is not in the app bundle; the synchronized Fernlet folder should copy it")
    }

    // MARK: - CryptoSwift

    /// "This notice may not be removed or altered from any source or binary distribution": the app
    /// bundle carries the fork tag's LICENSE byte for byte, the same file the repository holds.
    @Test func theBundledCryptoSwiftLicenseIsTheForkTagsFileUnaltered() throws {
        let bundled = try Self.bundledCryptoSwiftLicense()
        let digest = SHA256.hash(data: Data(bundled.utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(digest == Self.forkLicenseSHA256,
                "the bundled CryptoSwift license is not the \(Self.copiedFromTag) file; re-copy it unaltered from the tag")
        let repositoryCopy = try RepoRoot.source("App/Fernlet/Acknowledgments/CryptoSwift-LICENSE.txt")
        #expect(bundled == repositoryCopy, "the bundle and App/Fernlet/Acknowledgments disagree; rebuild")
    }

    /// The license was copied from the tag FernletKit pins. Moving to another CryptoSwift release
    /// re-copies LICENSE from the new tag and re-measures ``forkLicenseSHA256`` in the same commit.
    @Test func theBundledLicenseCameFromThePinnedTag() throws {
        let manifest = try RepoRoot.source("FernletKit/Package.swift")
        let pin = #".package(url: "https://github.com/bowman-mw/CryptoSwift", exact: "\#(Self.copiedFromTag)")"#
        #expect(manifest.contains(pin), """
            FernletKit no longer pins CryptoSwift at \(Self.copiedFromTag): copy LICENSE from the new tag into \
            App/Fernlet/Acknowledgments/CryptoSwift-LICENSE.txt, unaltered, and update this suite's tag and hash
            """)
    }

    /// The screen's sentence is read out of the bundled license, and NOTICE and fernlet.com/technical
    /// carry it word for word (whitespace folded, since NOTICE wraps it; the Pages workflow folds the same).
    @Test func theRequiredSentenceComesFromTheLicenseAndNoticeAndTheSiteCarryIt() throws {
        let license = try Self.bundledCryptoSwiftLicense()
        #expect(AcknowledgmentNotices.requiredAcknowledgment(in: license) == Self.requiredSentence)
        // R2: bounded by the two documents.
        for path in ["NOTICE", "Site/technical/index.html"] {
            let folded = try RepoRoot.source(path).split(whereSeparator: \.isWhitespace).joined(separator: " ")
            #expect(folded.contains(Self.requiredSentence), "\(path) lacks CryptoSwift's required acknowledgment")
        }
    }

    /// The reader takes the quoted sentence alone, without its closing quote or the next line, finds
    /// nothing in a license without one, and a font license's copyright paragraph stops at the first
    /// blank line.
    @Test func theNoticeReadersTakeOnlyTheirPart() {
        let clause = "- Redistributions must retain: 'This product includes software developed by X (Y).'\nNext line."
        #expect(AcknowledgmentNotices.requiredAcknowledgment(in: clause)
                == "This product includes software developed by X (Y).")
        #expect(AcknowledgmentNotices.requiredAcknowledgment(in: "Permission is granted to anyone.") == nil)
        #expect(AcknowledgmentNotices.copyrightNotice(in: "Copyright 2020 A (a)\nCopyright 2021 B\n\nThis Font Software is licensed")
                == "Copyright 2020 A (a)\nCopyright 2021 B")
    }

    /// A file the bundle lacks reads as nil, so the screen says it couldn't read the notice rather
    /// than drawing nothing.
    @Test func aMissingNoticeReadsAsNil() {
        #expect(AcknowledgmentNotices.bundledText("No-Such-License", in: .main) == nil)
        #expect(AcknowledgmentNotices.bundledText("", in: .main) == nil)
    }

    // MARK: - Fonts

    /// The screen lists exactly the OFL files the app bundle carries, each with a copyright paragraph
    /// of its own, and there are four of them, as the screen's copy says.
    @Test func everyBundledFontLicenseIsListedWithItsCopyright() throws {
        let bundledOFL = Set((Bundle.main.urls(forResourcesWithExtension: "txt", subdirectory: nil) ?? [])
            .map { $0.deletingPathExtension().lastPathComponent }
            .filter { $0.hasSuffix("-OFL") })
        let listed = AcknowledgmentNotices.fontFamilies.map(\.licenseResource)
        #expect(Set(listed) == bundledOFL, "the bundle's OFL files \(bundledOFL.sorted()) and the screen's \(listed) disagree")
        #expect(listed.count == 4, "the screen's copy says four font families; it lists \(listed.count) — reword it")
        // R2: bounded by the family table.
        for family in AcknowledgmentNotices.fontFamilies {
            let license = try #require(AcknowledgmentNotices.bundledText(family.licenseResource, in: .main))
            let notice = AcknowledgmentNotices.copyrightNotice(in: license)
            #expect(notice.hasPrefix("Copyright"), "\(family.licenseResource)'s notice does not open with its copyright")
            #expect(!notice.contains("SIL Open Font License"), "\(family.licenseResource)'s copyright paragraph ran into the license")
        }
    }

    /// Laying an OFL text out for the phone changes line breaks only: every word of the file, its
    /// dashed lines aside, comes back in order; the two dashed lines become rules; a heading keeps its
    /// own line; and a second copyright line is not run into the first.
    @Test func laidOutLicensesKeepEveryWordInOrder() throws {
        // R2: bounded by the family table.
        for family in AcknowledgmentNotices.fontFamilies {
            let license = try #require(AcknowledgmentNotices.bundledText(family.licenseResource, in: .main))
            let blocks = AcknowledgmentNotices.readableBlocks(of: license)
            let drawn = blocks.compactMap { block -> String? in
                if case .paragraph(let text) = block { return text }
                return nil
            }
            let undashed = license.components(separatedBy: .newlines)
                .filter { line in !(line.contains("-") && line.allSatisfy { $0 == "-" }) }
            #expect(drawn.joined(separator: " ").split(whereSeparator: \.isWhitespace)
                    == undashed.joined(separator: " ").split(whereSeparator: \.isWhitespace),
                    "\(family.licenseResource): laying it out lost, added or moved a word")
            #expect(blocks.filter { $0 == .rule }.count == 2, "\(family.licenseResource): the two dashed lines are not rules")
            #expect(drawn.contains { $0.hasPrefix("PREAMBLE\nThe goals of the Open Font License (OFL) are to stimulate worldwide development") },
                    "\(family.licenseResource): the PREAMBLE heading lost its line or the paragraph was not rejoined")
        }
        let twoHolders = "Copyright 2014 The DM Serif Project Authors (https://github.com/googlefonts/dm-fonts)\nCopyright 2014-2018 Adobe"
        #expect(AcknowledgmentNotices.readableBlocks(of: twoHolders + "\n\nNext.") == [.paragraph(twoHolders), .paragraph("Next.")])
    }

    // MARK: - Settings

    /// Settings → Privacy & data links the screen right under Privacy Policy, the route builds it, and
    /// search finds it by what people type, in English and in Spanish.
    @Test func settingsLinksAndFindsTheScreen() throws {
        let sheet = try RepoRoot.source("App/Fernlet/SettingsSheet.swift")
        let policy = try #require(sheet.range(of: #"hubLink("Privacy Policy", .privacyPolicy)"#))
        let row = try #require(sheet.range(of: #"hubLink("Acknowledgments", .acknowledgments)"#))
        #expect(policy.upperBound < row.lowerBound, "the Acknowledgments row left its place under Privacy Policy")
        #expect(sheet.contains("case .acknowledgments:\n            AcknowledgmentsView()"))
        let queries: [(query: String, languages: InputLanguages)] = [
            ("licenses", InputLanguages([.english])), ("open source", InputLanguages([.english])),
            ("cryptoswift", InputLanguages([.english])), ("licencias", InputLanguages([.spanish])),
            ("reconocimientos", InputLanguages([.spanish]))
        ]
        // R2: bounded by the query table.
        for (query, languages) in queries {
            #expect(SettingsSearchIndex.results(for: query, languages: languages).contains { $0.route == .acknowledgments },
                    "searching \"\(query)\" does not find Acknowledgments")
        }
    }
}
