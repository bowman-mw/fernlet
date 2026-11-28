// PlaceVisitSummaryTests.swift
// FernletTests
//
// Home's place summary (owner's P1-A, 2026-11-27): the fold under the hub key writes it, Home reads it
// through its one reader with Private closed, and it holds only a name or kind token, a last-visit day
// and a 60-day count per place. Deletes and wipes take it with Where you've been.

import CryptoKit
import Foundation
import Testing
import WorldMapStore
@testable import Fernlet

@MainActor
struct PlaceVisitSummaryTests {
    private static let park = GeoPoint(45.5213, -122.6253)
    private static let start = Date(timeIntervalSince1970: 2_000_000_000)

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }

    private static func day(_ offset: Int) -> Date { start.addingTimeInterval(Double(offset) * 86_400) }

    /// A store with one learned place and a fold at `day(0)`.
    private func learned(_ place: PlaceRecord, key: SymmetricKey) throws -> (WorldMapVault, PlaceLogStore) {
        let vault = WorldMapVault.ephemeral()
        let store = PlaceLogStore(vault: vault)
        try store.saveDeviceState(PlaceDeviceState.empty.learning(place, at: Self.day(0)))
        _ = try store.fold(hubKey: key, now: Self.day(0), calendar: Self.calendar)
        return (vault, store)
    }

    /// Records a visit to `place` on `offset` and folds it then.
    private func visit(_ place: UUID, on offset: Int, store: PlaceLogStore, key: SymmetricKey) throws {
        try store.saveDeviceState(try store.deviceState().recordingVisit(to: place, at: Self.day(offset)))
        _ = try store.fold(hubKey: key, now: Self.day(offset), calendar: Self.calendar)
    }

    @Test func theFoldCountsVisitsAndHomeReadsThemWithoutTheHubKey() throws {
        let key = SymmetricKey(size: .bits256)
        let place = PlaceRecord(placeID: "I-park", point: Self.park)
        let (vault, store) = try learned(place, key: key)
        try visit(place.id, on: 20, store: store, key: key)
        try visit(place.id, on: 50, store: store, key: key)
        _ = try store.fold(hubKey: key, now: Self.day(51), calendar: Self.calendar)
        let entry = try #require(PlaceVisitSummaryReader(vault: vault).read().entries.first)
        #expect(entry.id == place.id)
        #expect(entry.visits60 == 3, "a fold with nothing new counts nothing twice")
        #expect(entry.lastVisitDay == Self.calendar.startOfDay(for: Self.day(50)))
        #expect(entry.label == nil && entry.kind == nil)
        #expect(vault.clearAll())
    }

    @Test func aVisitAfterMoreThanSixtyQuietDaysStartsTheCountAgain() throws {
        let key = SymmetricKey(size: .bits256)
        let place = PlaceRecord(placeID: "I-park", point: Self.park)
        let (vault, store) = try learned(place, key: key)
        try visit(place.id, on: 10, store: store, key: key)
        try visit(place.id, on: 80, store: store, key: key)
        #expect(PlaceVisitSummaryReader(vault: vault).read().entries.first?.visits60 == 1)
        try visit(place.id, on: 100, store: store, key: key)
        #expect(PlaceVisitSummaryReader(vault: vault).read().entries.first?.visits60 == 2)
        #expect(vault.clearAll())
    }

    /// Never Apple's name, point or reference: the opened file holds the id, the day, the count and the
    /// kind or name, and nothing else.
    @Test func theSummaryHoldsNoPointAndNoReference() throws {
        let key = SymmetricKey(size: .bits256)
        let place = PlaceRecord(placeID: "I-park-reference", point: Self.park)
        let (vault, store) = try learned(place, key: key)
        let opened = String(decoding: try #require(try vault.read(WorldMapVault.File.placeSummary)), as: UTF8.self)
        for banned in ["I-park-reference", "point", "placeID", "45.52", "122.62", "latitude", "stops"] {
            #expect(!opened.contains(banned), "the summary holds \(banned)")
        }
        _ = store
        #expect(vault.clearAll())
    }

    @Test func namesAndKindsComeFromThePersonAndFernletsOwnRecords() throws {
        let key = SymmetricKey(size: .bits256)
        let place = PlaceRecord(placeID: "I-cafe", point: Self.park)
        let (vault, store) = try learned(place, key: key)
        _ = try store.rename(place.id, to: "Hoshi's", hubKey: key, now: Self.day(1))
        #expect(PlaceVisitSummaryReader(vault: vault).read().entries.first?.label == "Hoshi's", "a rename reaches Home at once")
        store.notePlaceKind(.gym, for: place.id)
        #expect(PlaceVisitSummaryReader(vault: vault).read().entries.first?.kind == .gym)
        store.notePlaceKind(.park, for: UUID())
        #expect(PlaceVisitSummaryReader(vault: vault).read().entries.count == 1, "a kind for no entry adds nothing")

        let eating = EatingPlace(id: UUID(), placeID: "I-cafe", point: Self.park)
        let log = PlaceLog(places: [PlaceRecord(id: place.id, placeID: "I-cafe", point: Self.park, visits: 1)], stops: [])
        let marked = PlaceVisitSummary(entries: [PlaceVisitSummary.Entry(id: place.id, lastVisitDay: Self.day(0), visits60: 1)])
            .folding(newVisits: [], log: log, eating: [eating], now: Self.day(1), calendar: Self.calendar)
        #expect(marked.entries.first?.kind == .foodAndDrink, "a place the person eats out at is food and drink")
        #expect(vault.clearAll())
    }

    @Test func deletesAndResetsTakeTheSummary() throws {
        let key = SymmetricKey(size: .bits256)
        let place = PlaceRecord(placeID: "I-park", point: Self.park)
        let (vault, store) = try learned(place, key: key)
        _ = try store.deleteDay(Self.calendar.startOfDay(for: Self.day(0)), hubKey: key, now: Self.day(0), calendar: Self.calendar)
        #expect(PlaceVisitSummaryReader(vault: vault).read().entries.isEmpty, "a deleted day forgets its places")

        let other = PlaceRecord(placeID: "I-beach", point: Self.park)
        let (vault2, store2) = try learned(other, key: key)
        #expect(!PlaceVisitSummaryReader(vault: vault2).read().entries.isEmpty)
        #expect(store2.deleteAll())
        #expect(try vault2.read(WorldMapVault.File.placeSummary) == nil, "Delete all of it removes it")

        let (vault3, store3) = try learned(other, key: key)
        _ = try store3.fold(hubKey: SymmetricKey(size: .bits256), now: Self.day(1), calendar: Self.calendar)
        #expect(try vault3.read(WorldMapVault.File.placeSummary) == nil, "an app-lock reset removes it")

        let (vault4, store4) = try learned(other, key: key)
        #expect(store4.deleteEverything())
        #expect(try vault4.read(WorldMapVault.File.placeSummary) == nil)
        let (vault5, _) = try learned(other, key: key)
        #expect(vault5.clearAll())
        #expect(PlaceVisitSummaryReader(vault: vault5).read() == .empty, "every wipe takes it with the vault")
        _ = store
        for each in [vault, vault2, vault3, vault4] { #expect(each.clearAll()) }
    }

    @Test func forgettingAndPruningAreBounded() {
        let old = PlaceVisitSummary.Entry(id: UUID(), kind: .park, lastVisitDay: Self.day(0), visits60: 4)
        let fresh = PlaceVisitSummary.Entry(id: UUID(), kind: .beach, lastVisitDay: Self.day(300), visits60: 2)
        let log = PlaceLog(places: [PlaceRecord(id: old.id, point: Self.park, visits: 4),
                                    PlaceRecord(id: fresh.id, point: Self.park, visits: 2)], stops: [])
        let summary = PlaceVisitSummary(entries: [old, fresh])
        let later = summary.folding(newVisits: [], log: log, eating: [], now: Self.day(400), calendar: Self.calendar)
        #expect(later.entries.map(\.id) == [fresh.id], "a place quiet for over a year is dropped")
        #expect(summary.forgetting([old.id]).entries.map(\.id) == [fresh.id])
        let gone = summary.folding(newVisits: [], log: .empty, eating: [], now: Self.day(301), calendar: Self.calendar)
        #expect(gone.entries.isEmpty, "a place no longer kept leaves the summary")
        #expect(PlaceVisitSummary.Entry(id: UUID(), lastVisitDay: Self.day(0), visits60: 5_000).visits60 == PlaceVisitSummary.maxCount)
    }

    /// Home reads the summary only through the store's one reader, and none in a decoy.
    @Test func homeMapsTheSummaryToTheCardsKindWords() {
        #expect(FernletStore.ambientPlaceKind(.foodAndDrink) == .restaurant)
        #expect(FernletStore.ambientPlaceKind(.gym) == .gym)
        #expect(FernletStore.ambientPlaceKind(.park) == .park)
        #expect(FernletStore.ambientPlaceKind(.beach) == .beach)
        #expect(FernletStore.ambientPlaceKind(.campground) == .campground)
    }

    @Test func homeReadsNothingInADecoy() throws {
        let source = try RepoRoot.source("App/Fernlet/FernletStore+AmbientPlaces.swift")
        #expect(source.contains("guard !duressSessionActive else { return [] }"))
    }
}
