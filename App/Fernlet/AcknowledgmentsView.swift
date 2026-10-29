//
//  AcknowledgmentsView.swift
//  Fernlet
//
//  Settings → Privacy & data → Acknowledgments (the owner's pick, 2026-10-25): the notices the
//  licenses of Fernlet's software, fonts and data ask it to carry. CryptoSwift's license requires an
//  acknowledgment in the product and asks every binary distribution to keep its notice, so the screen
//  draws the required sentence and the whole license; the four font families get their copyright
//  lines and their OFL texts; the food data gets where it comes from.
//
//  The notices are read from the files the app bundle carries — `Acknowledgments/CryptoSwift-
//  LICENSE.txt`, copied unaltered from the fork tag Fernlet pins, and `Fonts/LICENSES/*-OFL.txt` —
//  never retyped here. So they stay word for word in English, as their authors wrote them, and their
//  URLs stay out of Swift source, where `NoTrackingBoundaryTests` would read them as destinations.
//  No notice is a link. The weather section (added 2026-10-25, the owner's pick of WeatherKit
//  attribution placements) credits Apple Weather as WeatherKit's terms ask and carries the screen's one
//  link, Apple's legal page of weather data sources, which Safari opens (`AppleWeatherAttribution`;
//  `AppleWeatherAttributionTests` pins it). The OFL texts are hard-wrapped at about 70 columns, which broke
//  twice on a phone (seen on the simulator, 2026-10-25), so their line breaks are rejoined for the
//  screen; their words are not touched. `AcknowledgmentsTests` pins the files, the sentence, NOTICE and
//  the website's copy (Site/technical/index.html).
//
//  World build (integration main merge 2, 2026-10-26): a page in the Settings panel, like Privacy
//  Policy and Safety & reporting beside it. The plate carries the title and Back
//  (`fernletPushedPage`), the dotted page shows through (`fernletPageBackground`), and each section is
//  one `FernletFramedSection` under the frame rule, its label the section's heading. The words and the
//  one link are main's, unchanged.
//

import SwiftUI
import os
import FernletUI

/// The license notices Fernlet carries, read from the files the app bundle ships.
///
/// Pure and `nonisolated`, so tests drive it with any bundle. Nothing here retypes license text: the
/// screen draws only what these functions read from a bundled file.
nonisolated enum AcknowledgmentNotices {
    /// One bundled font family: the name the screen draws and its OFL file (`<licenseResource>.txt`).
    struct FontFamily: Sendable, Equatable {
        let name: String
        let licenseResource: String
    }

    /// CryptoSwift's LICENSE (`CryptoSwift-LICENSE.txt`), copied unaltered from the fork tag
    /// FernletKit pins, `1.10.0-fernlet.2`, whose LICENSE is upstream 1.10.0's.
    static let cryptoSwiftLicenseResource = "CryptoSwift-LICENSE"

    /// The families in `App/Fernlet/Fonts`, in the order the screen lists them. The screen's copy
    /// says "four"; `AcknowledgmentsTests` holds this table to the OFL files the bundle carries.
    static let fontFamilies: [FontFamily] = [
        FontFamily(name: "Fraunces", licenseResource: "Fraunces-OFL"),
        FontFamily(name: "DM Serif Display", licenseResource: "DMSerifDisplay-OFL"),
        FontFamily(name: "Instrument Serif", licenseResource: "InstrumentSerif-OFL"),
        FontFamily(name: "DM Sans", licenseResource: "DMSans-OFL"),
    ]

    /// The opening words of the sentence CryptoSwift's license tells every redistribution to keep.
    private static let acknowledgmentOpening = "This product includes software developed by"

    private static let log = Logger(subsystem: "com.fernlet", category: "acknowledgments")

    /// The text of `<resource>.txt` in `bundle`, or nil (logged) when the file is missing or
    /// unreadable; the screen then says so instead of drawing a notice.
    static func bundledText(_ resource: String, in bundle: Bundle) -> String? {
        guard !resource.isEmpty, let url = bundle.url(forResource: resource, withExtension: "txt") else {
            log.error("\(resource, privacy: .public).txt is not in the bundle")
            return nil
        }
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            log.error("\(resource, privacy: .public).txt is unreadable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// The sentence a license's "must retain the following acknowledgment: '…'" clause quotes, without
    /// its closing quote mark; nil when the license has no such sentence.
    static func requiredAcknowledgment(in license: String) -> String? {
        guard let start = license.range(of: acknowledgmentOpening) else { return nil }
        let line = license[start.lowerBound...].prefix { !$0.isNewline }
        let sentence = line.trimmingCharacters(in: .whitespaces)
        return sentence.hasSuffix("'") ? String(sentence.dropLast()) : sentence
    }

    /// A font license's copyright notice: its opening paragraph, up to the first blank line.
    static func copyrightNotice(in license: String) -> String {
        let paragraph = license.components(separatedBy: "\n\n").first ?? license
        return paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One block of a hard-wrapped license as the screen lays it out.
    enum LicenseBlock: Equatable, Sendable {
        /// A paragraph, its hard wraps rejoined; a heading or a copyright line keeps its own line.
        case paragraph(String)
        /// A line of dashes, drawn as a divider.
        case rule
    }

    /// A line shorter than this ends where its author ended it (a heading, a paragraph's last line);
    /// a longer one is a hard wrap. The OFL files wrap at about 70 columns; their headings run to 23.
    private static let hardWrapMinimum = 40

    /// A hard-wrapped license laid out for a phone, so it wraps once, to the screen, instead of
    /// breaking twice. Only line breaks change: within each blank-line paragraph a hard-wrapped line
    /// rejoins the next with a space, a short line and a line opening "Copyright" keep their break,
    /// and a line of dashes becomes a ``LicenseBlock/rule``. Every word stays, in order
    /// (`AcknowledgmentsTests` folds both and compares).
    static func readableBlocks(of license: String) -> [LicenseBlock] {
        var blocks: [LicenseBlock] = []
        var paragraph = ""
        var previousLength = 0
        // R2: bounded by the license's line count.
        for raw in license.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let isRule = !line.isEmpty && line.allSatisfy { $0 == "-" }
            if line.isEmpty || isRule {
                if !paragraph.isEmpty { blocks.append(.paragraph(paragraph)) }
                if isRule { blocks.append(.rule) }
                paragraph = ""
            } else if paragraph.isEmpty {
                paragraph = line
            } else {
                let rejoins = previousLength >= hardWrapMinimum && !line.hasPrefix("Copyright")
                paragraph += (rejoins ? " " : "\n") + line
            }
            previousLength = line.count
        }
        if !paragraph.isEmpty { blocks.append(.paragraph(paragraph)) }
        return blocks
    }
}

/// One font family's row on the screen: its name and its bundled license, nil when unreadable.
private struct FontNotice: Identifiable {
    let family: AcknowledgmentNotices.FontFamily
    let license: String?
    var id: String { family.name }
}

/// Settings → Privacy & data → Acknowledgments: the notices Fernlet's software, fonts and data
/// licenses ask it to carry.
///
/// Pushed from ``SettingsSheet`` via `SettingsRoute.acknowledgments`. The explanations localize; the
/// notices are drawn `verbatim` from the files the bundle carries (``AcknowledgmentNotices``), word
/// for word in English (the font licenses' hard wraps rejoined), selectable, and never a link. The one
/// link is the weather section's Apple legal page, which Safari opens; the app fetches nothing. In the
/// World build each section is a framed card (``FernletFramedSection``) whose label is its heading.
struct AcknowledgmentsView: View {
    private let cryptoSwiftLicense = AcknowledgmentNotices.bundledText(
        AcknowledgmentNotices.cryptoSwiftLicenseResource, in: .main)
    private let fontNotices = AcknowledgmentNotices.fontFamilies.map {
        FontNotice(family: $0, license: AcknowledgmentNotices.bundledText($0.licenseResource, in: .main))
    }

    var body: some View {
        ScrollView {
            // The frame rule: one frame per section, 16 pt between them.
            VStack(alignment: .leading, spacing: 16) {
                FernletFramedSection(header: nil) {
                    paragraph(Text("Fernlet is built with software, fonts and data made by other people. Their licenses ask Fernlet to carry these notices, so they appear here word for word, in English, as their authors wrote them."))
                }
                cryptoSwiftSection
                fontsSection
                foodDataSection
                mapDataSection
                weatherSection
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 30)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fernletPageBackground()
        // A page in the Settings panel: the plate carries the title and Back.
        .fernletPushedPage("Acknowledgments")
    }

    // MARK: - Sections

    /// The required acknowledgment, then CryptoSwift's whole license: one framed section, each its own row.
    private var cryptoSwiftSection: some View {
        FernletFramedSection(header: Text(verbatim: "CryptoSwift")) {
            paragraph(Text("The passcode lock uses CryptoSwift's scrypt to turn your passcode into a key. Fernlet builds it from a copy that changes one line of its package file (the oldest iOS it builds for) and none of its code. Its license asks every copy of Fernlet to say:"))
            if let license = cryptoSwiftLicense, let sentence = AcknowledgmentNotices.requiredAcknowledgment(in: license) {
                Text(verbatim: sentence)
                    .font(.fernlet(.body))
                    .italic()
                    .foregroundStyle(Color.bark)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                notice(license)
            } else {
                unreadableNotice
            }
        }
    }

    /// Each family's copyright lines, with its whole license folded under a disclosure: one framed
    /// section, a row per family.
    private var fontsSection: some View {
        FernletFramedSection(header: Text("Fonts")) {
            paragraph(Text("Fernlet's lettering uses four font families under the SIL Open Font License 1.1. Each license travels inside the app beside its font."))
            ForEach(fontNotices) { font in
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: font.family.name)
                        .font(.fernlet(.label))
                        .foregroundStyle(Color.bark)
                    if let license = font.license {
                        notice(AcknowledgmentNotices.copyrightNotice(in: license))
                        DisclosureGroup {
                            licenseText(license).padding(.top, 6)
                        } label: {
                            Text("License text")
                                .font(.fernlet(.label))
                                .foregroundStyle(Color.bark)
                        }
                        .tint(Color.bark)
                    } else {
                        unreadableNotice
                    }
                }
            }
        }
    }

    /// Where the food data comes from. Open Food Facts is also credited wherever its data appears.
    private var foodDataSection: some View {
        FernletFramedSection(header: Text("Food data")) {
            paragraph(Text("Products found with a barcode lookup come from Open Food Facts, under the Open Database License (ODbL). The foods built into Fernlet come from USDA FoodData Central, which is in the public domain."))
        }
    }

    /// Where the World map's atlas comes from (round 7, `Docs/World-Atlas-Pack.md`): Natural Earth, public
    /// domain, credited though it asks for none; and Beck et al.'s Köppen-Geiger maps under CC BY 4.0, whose
    /// licence asks for the credit, the licence's name and a note that Fernlet changed the data. The
    /// citation stays in English, as its authors wrote it; the licence's address is in NOTICE, not here.
    private var mapDataSection: some View {
        FernletFramedSection(header: Text("Map data")) {
            paragraph(Text("The World map's land, seas, countries, states and provinces, and cities come from Natural Earth, which is in the public domain and asks for no credit. Both map sources travel inside the app: Fernlet never downloads map data."))
            paragraph(Text("The climate zones that pick the map's terrain and plants come from this work, under the Creative Commons Attribution 4.0 International license (CC BY 4.0). Fernlet changed the data: it reduced the map to cells a tenth of a degree wide and turned its climate classes into terrain."))
            Text(verbatim: Self.koppenCitation)
                .font(.fernlet(.body))
                .italic()
                .foregroundStyle(Color.bark)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    /// Beck et al.'s citation, as the dataset asks to be cited (a notice, never translated).
    static let koppenCitation = "Beck, H. E., Zimmermann, N. E., McVicar, T. R., Vergopolan, N., Berg, A., & Wood, E. F. (2018). Present and future Köppen-Geiger climate classification maps at 1-km resolution. Scientific Data, 5, 180214."

    /// Where the weather comes from: the Apple Weather mark, the notice that Fernlet modifies Apple's
    /// data, and Apple's legal page, as WeatherKit's terms ask (``AppleWeatherAttribution``). "Ten" is
    /// `WeatherRequestBudget.dailyLimit`; `AppleWeatherAttributionTests` holds the two together.
    /// One framed section: the mark over the paragraph in one row, the link in its own.
    private var weatherSection: some View {
        FernletFramedSection(header: Text("Weather")) {
            VStack(alignment: .leading, spacing: 6) {
                AppleWeatherAttribution.markText(.body)
                    .foregroundStyle(Color.bark)
                paragraph(Text("When weather-aware recovery prompts are on, Fernlet asks Apple Weather for the current conditions near you, at most ten times a day. Fernlet modifies the data Apple provides: it becomes the sky behind your companion, the gentler-day note and the short-walk idea, never a forecast."))
            }
            AppleWeatherSourcesLink()
        }
    }

    // MARK: - Pieces

    /// A localized explanation.
    private func paragraph(_ text: Text) -> some View {
        text
            .font(.fernlet(.body))
            .foregroundStyle(Color.bark)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// A license notice, word for word from its bundled file.
    private func notice(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.fernlet(.labelSmall))
            .foregroundStyle(Color.bark)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    /// A hard-wrapped font license, its paragraphs rejoined to wrap to the screen
    /// (``AcknowledgmentNotices/readableBlocks(of:)``) and its dashed lines drawn as dividers.
    private func licenseText(_ license: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(AcknowledgmentNotices.readableBlocks(of: license).enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let text):
                    notice(text)
                case .rule:
                    Divider()
                }
            }
        }
    }

    /// Drawn in place of a notice whose file the bundle lacks; `AcknowledgmentsTests` keeps it unseen.
    private var unreadableNotice: some View {
        paragraph(Text("Fernlet couldn't read this notice from the app. It is also in the NOTICE file of Fernlet's source code."))
    }
}

#Preview {
    NavigationStack { AcknowledgmentsView() }
}
