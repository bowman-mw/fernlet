import Foundation
import Testing
import FernletDomainModel
@testable import Fernlet

/// The World build's Settings lane: the pixel icons Settings' pages pick for a care task, a quick-log
/// shortcut, a derived signal and a kind of Health data, the busy card's pixel spinner, and the
/// source pins that keep the restyled pages on the approved chrome (the framed search field instead
/// of the system drawer, the plate's title on every standalone page, sheets on paper).
@MainActor
struct WorldSettingsTests {

    // MARK: Pixel icons

    /// Every built-in care task maps to the design's sprite; a custom task's symbol draws the tick.
    @Test func careTasksWearTheDesignsPixelIcons() {
        #expect(CareTaskSprite.sprite(forSystemImage: "mouth") == WorldStampArt.tooth)
        #expect(CareTaskSprite.sprite(forSystemImage: "sun.max") == WorldSprites.sun)
        #expect(CareTaskSprite.sprite(forSystemImage: "moon") == SettingsShortcutSprite.inkMoon)
        #expect(CareTaskSprite.sprite(forSystemImage: "shower") == WorldSprites.drop)
        #expect(CareTaskSprite.sprite(forSystemImage: "drop") == WorldSprites.drop)
        #expect(CareTaskSprite.sprite(forSystemImage: "sparkle") == WorldSprites.star)
        #expect(CareTaskSprite.sprite(forSystemImage: "checkmark.circle") == WorldSprites.check)
    }

    /// The six default quick-log tiles draw the design's six sprites, and no shortcut draws a
    /// white-only sprite (it would vanish on paper).
    @Test func quickLogShortcutsWearVisibleSprites() {
        let defaults = FernletShortcut.defaultQuickLog.map(SettingsShortcutSprite.sprite(for:))
        #expect(defaults == [WorldSprites.onigiri, WorldSprites.drop, WorldSprites.shoe,
                             SettingsShortcutSprite.inkMoon, WorldSprites.diary, WorldSprites.check])
        #expect(SettingsShortcutSprite.inkMoon.isMonoInk, "the moon takes the ink token in dark mode")
        for shortcut in FernletShortcut.allCases {
            let colours = Set(SettingsShortcutSprite.sprite(for: shortcut).palette.values)
            #expect(colours != [0xFFFFFF] && colours != [0xF4ECC8], "\(shortcut) draws a sprite too pale for paper")
        }
    }

    /// Signals and Health kinds never draw a white-only sprite either.
    @Test func signalAndHealthIconsStayVisibleOnPaper() {
        for name in ["moodTrend", "energyTrend", "eatingPattern", "progressionTrend", "intensityReadiness", "other"] {
            #expect(Set(SettingsSignalCard.sprite(for: name).palette.values) != [0xFFFFFF], "\(name)")
        }
        #expect(SettingsSignalCard.sprite(for: "moodTrend") == WorldSprites.face)
        for card in HealthAccessSettingsView.HealthAccessCard.allCases {
            #expect(Set(HealthAccessSettingsView.sprite(for: card).palette.values) != [0xFFFFFF], "\(card)")
        }
    }

    // MARK: The busy card's spinner

    /// The head is fully inked, the three cells behind it fade, the rest keep a faint floor; the ring
    /// wraps round.
    @Test func thePixelSpinnersTailFadesBehindItsHead() {
        #expect(PixelSpinner.ring.count == 8)
        #expect(PixelSpinner.opacity(cell: 3, head: 3) == 1)
        #expect(PixelSpinner.opacity(cell: 2, head: 3) == 0.75)
        #expect(PixelSpinner.opacity(cell: 0, head: 3) == 0.25)
        #expect(PixelSpinner.opacity(cell: 4, head: 3) == 0.15)
        #expect(PixelSpinner.opacity(cell: 7, head: 0) == 0.75, "the tail wraps from the first cell to the last")
    }

    // MARK: Search and the quick-log moves

    /// The two settings that moved or arrived in the World build are findable: Advanced period
    /// tracking (Period & sensitive content) and the recipe-sharing switches (Sharing).
    @Test func newSettingsAreFoundBySearch() {
        let advanced = SettingsSearchIndex.results(for: "advanced period")
        #expect(advanced.contains { $0.title == "Advanced period tracking" && $0.route == .periodSensitive })
        for word in ["ovulation", "cervical mucus", "basal temperature", "spotting"] {
            #expect(SettingsSearchIndex.results(for: word).contains { $0.route == .periodSensitive }, "\(word)")
        }
        #expect(SettingsSearchIndex.results(for: "include notes").contains { $0.title == "Recipes you share" && $0.route == .sharing })
        #expect(SettingsSearchIndex.results(for: "recipe picture").contains { $0.route == .sharing })
    }

    /// "Move up" and "Move down" swap a tile with its neighbour, and do nothing at either end.
    @Test func quickLogTilesStepOnePlaceAndStopAtTheEnds() {
        let tiles = FernletShortcut.defaultQuickLog
        let down = QuickLogOrder.stepping(tiles, at: 0, by: 1)
        #expect(down[0] == tiles[1] && down[1] == tiles[0])
        #expect(Array(down.dropFirst(2)) == Array(tiles.dropFirst(2)))
        #expect(QuickLogOrder.stepping(tiles, at: 0, by: -1) == tiles)
        #expect(QuickLogOrder.stepping(tiles, at: tiles.count - 1, by: 1) == tiles)
        #expect(QuickLogOrder.stepping(tiles, at: 9, by: 1) == tiles)
    }

    /// The grip is grabbed at once (owner, question 16): the held row moves one place each time the
    /// finger passes half a row beyond its slot, and follows the finger no further than half a row.
    @Test func theQuickLogGripMovesARowEachHalfRowPastItsSlot() {
        let start = QuickLogGripDrag(index: 2)
        #expect(start.step(at: 20, rowHeight: 54) == 0)
        #expect(start.step(at: 28, rowHeight: 54) == 1)
        #expect(start.step(at: -28, rowHeight: 54) == -1)
        #expect(start.step(at: 100, rowHeight: 0) == 0, "no step before a row height is known")
        let moved = start.moved(by: 1, rowHeight: 54)
        #expect(moved.index == 3 && moved.anchor == 54)
        #expect(moved.step(at: 60, rowHeight: 54) == 0, "the anchor follows the row to its new slot")
        #expect(moved.step(at: 82, rowHeight: 54) == 1)
        #expect(start.lift(at: 200, rowHeight: 54) == 27 && start.lift(at: -10, rowHeight: 54) == -10)
    }

    // MARK: Source pins

    /// Settings' first page draws the framed search field under the look (no system drawer under an
    /// empty bar), and keeps today's drawer without it.
    @Test func settingsRootUsesTheFramedSearchFieldUnderTheLook() throws {
        let sheet = try RepoRoot.source("App/Fernlet/SettingsSheet.swift")
        #expect(sheet.contains("SettingsSearchField(title: \"Search settings\", text: $settingsSearch)"))
        #expect(sheet.contains(".modifier(SettingsRootChrome(inPanel: onClose != nil"))
        #expect(sheet.contains(".searchable(text: $settingsSearch, placement: .navigationBarDrawer(displayMode: .always)"),
                "the no-look fallback lost its search drawer")
    }

    /// Every standalone Settings page hands its title to the plate instead of a navigation bar.
    @Test func standalonePagesPutTheirTitleOnThePlate() throws {
        let pages = [
            ("App/Fernlet/HealthAccessSettingsView.swift", "Health"),
            ("App/Fernlet/NearbyFriendsSettingsView.swift", "Nearby friends"),
            ("App/Fernlet/SoundsHapticsSettingsView.swift", "Sounds & haptics"),
            ("App/Fernlet/QuickLogShortcutsEditor.swift", "Quick-log shortcuts"),
            ("App/Fernlet/PrivacyDataSettingsView.swift", "Privacy & Data"),
            // From main (#67), adapted in integration main merge 2.
            ("App/Fernlet/AcknowledgmentsView.swift", "Acknowledgments")
        ]
        for (path, title) in pages {
            let source = try RepoRoot.source(path)
            #expect(source.contains(".fernletPushedPage(\"\(title)\")"), "\(path) lost its plate title")
            #expect(!source.contains(".navigationTitle(\"\(title)\")"), "\(path) still sets a navigation title")
        }
    }

    /// Privacy & Data's backups are one framed section under their label (`b2-settings-privacy`), and
    /// Settings' body profile draws the framed stepper and dropdowns under the look (`b2-settings-goal`).
    @Test func privacyBackupsAndBodyProfileUseTheFramedPieces() throws {
        let privacy = try RepoRoot.source("App/Fernlet/PrivacyDataSettingsView.swift")
        #expect(privacy.contains("FernletFramedSection(\"Backups\")"))
        #expect(privacy.contains("FernletFramedSection(\"Local backup\")"))
        let profile = try RepoRoot.source("App/Fernlet/OnboardingView.swift")
        #expect(profile.contains("FernletFramedSection(\"Body profile\")"))
        #expect(profile.contains("FernletDropdown(BodyProfileFieldLabel.sex"))
        let quickLog = try RepoRoot.source("App/Fernlet/QuickLogShortcutsEditor.swift")
        #expect(quickLog.contains(".environment(\\.editMode, .constant(look == nil ? .active : .inactive))"))
        #expect(quickLog.contains("accessibilityAction(named: Text(\"Move up\"))"))
    }

    /// The lock and duress sheets sit on paper with the title inside (`b1-frame-sheet`).
    @Test func lockAndDuressSheetsUseTheSheetChrome() throws {
        let lock = try RepoRoot.source("FernletKit/Sources/FernletLockUI/FernletLockView.swift")
        #expect(lock.components(separatedBy: ".fernletSheet()").count - 1 >= 2, "setup and disclosure")
        let duress = try RepoRoot.source("App/Fernlet/DuressPINSetupView.swift")
        #expect(duress.contains(".fernletSheetToolbar(title: \"Duress code\", onDone: { dismiss() })"))
        #expect(duress.contains(".fernletSheetToolbar(title: \"Duress code\", onCancel: { dismiss() })"))
    }
}
