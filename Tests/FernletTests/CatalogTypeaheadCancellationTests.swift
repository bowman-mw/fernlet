// CatalogTypeaheadCancellationTests.swift
// FernletTests
//
// Ingredient-search round F9 (Docs/Ingredient-Search-Deep-Research-2026-09-29.md §2.2, §8 F9): the
// recipe editor's typeahead ran each settled keystroke's catalog search in a detached task that a newer
// keystroke never cancelled — "choc", "chocolate", "chocolate c" each hydrated ~9,000 rows and scored
// them for ~0.7 s, and every result but the last was thrown away. `CatalogTypeahead.matches` now
// forwards its cancellation to the detached search, and a TYPED search stops at its next stage
// boundary once its task is cancelled. A machine-generated search never stops early.

import Foundation
import Testing
import FernletDomainModel
import FoodCatalog
@testable import Fernlet

struct CatalogTypeaheadCancellationTests {
    static func catalog() -> FoodCatalog {
        let chips = FoodItem(name: "Chocolate chips", servingSize: 100, servingUnit: "g",
                             macros: Macros(protein: 5, carbs: 60, fat: 30), micronutrients: Micronutrients(),
                             category: "Fixtures", source: .usda, tags: [])
        return FoodCatalog(source: InMemoryBundledFoodSource([chips]))
    }

    /// Runs `search` inside a task that has already been cancelled — the state a superseded keystroke
    /// leaves its search in.
    static func inCancelledTask(_ search: @escaping @Sendable () -> [FoodItem]) async -> [FoodItem] {
        await Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return search()
        }.value
    }

    @Test func aSupersededTypedSearchStopsAndAnswersNothing() async {
        let catalog = Self.catalog()
        #expect(catalog.results(for: "chocolate", context: .userTyped).count == 1, "precondition: the row is found")
        let superseded = await Self.inCancelledTask { catalog.results(for: "chocolate", context: .userTyped) }
        #expect(superseded.isEmpty, "a cancelled typed search must not finish its scoring")
    }

    @Test func aMachineSearchInACancelledTaskStillAnswersInFull() async {
        let catalog = Self.catalog()
        let machine = await Self.inCancelledTask { catalog.results(for: "chocolate", context: .machineGenerated) }
        #expect(machine.count == 1, "a resolver or importer caller must never get a silently truncated answer")
        let pool = await Task.detached { () -> Int in
            withUnsafeCurrentTask { $0?.cancel() }
            return catalog.candidates(for: "chocolate").count
        }.value
        #expect(pool == 1)
    }

    /// A query too short to search never reaches retrieval: "ch" used to hydrate the whole 10,000-row
    /// cap to answer nothing (F5's latency measurement). The answer is unchanged — empty — and the
    /// source is not asked; a searchable query still is.
    @Test func aTooShortQueryNeverReachesRetrieval() {
        let source = CountingFoodSource(Self.catalog().results(for: "chocolate", context: .machineGenerated))
        let catalog = FoodCatalog(source: source)
        #expect(catalog.results(for: "ch", context: .userTyped).isEmpty)
        #expect(catalog.results(for: "c", context: .machineGenerated, ranking: .ingredientIdentity).isEmpty)
        #expect(source.fetches == 0, "a two-letter keystroke must not fetch candidates")
        #expect(catalog.results(for: "cho", context: .userTyped).count == 1)
        #expect(source.fetches > 0)
    }

    /// The editor's own call: superseded before or during its settle, it applies nothing.
    @Test func aSupersededTypeaheadReturnsNil() async {
        let catalog = Self.catalog()
        let keystroke = Task {
            await CatalogTypeahead.matches(for: "chocolate", catalog: catalog, ranking: .ingredientIdentity)
        }
        keystroke.cancel()
        #expect(await keystroke.value == nil)
        let settled = await CatalogTypeahead.matches(for: "chocolate", catalog: catalog, ranking: .ingredientIdentity)
        #expect(settled?.count == 1, "an unsuperseded keystroke still answers")
    }
}

/// An in-memory catalog source that counts its candidate fetches.
private final class CountingFoodSource: BundledFoodSource, @unchecked Sendable {
    private let items: [FoodItem]
    private let lock = NSLock()
    private var fetchCount = 0

    init(_ items: [FoodItem]) { self.items = items }

    var fetches: Int {
        lock.lock(); defer { lock.unlock() }
        return fetchCount
    }

    func candidates(forQuery query: String, stripsStopwords: Bool) -> [FoodItem] {
        lock.lock(); fetchCount += 1; lock.unlock()
        return items
    }

    func item(id: UUID) -> FoodItem? { items.first { $0.id == id } }
    func items(ids: [UUID]) -> [FoodItem] { items.filter { ids.contains($0.id) } }
    func exactMatch(normalizedName: String) -> FoodItem? { nil }
    func item(barcode: String) -> FoodItem? { nil }
    var count: Int { items.count }
}
