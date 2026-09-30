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

    /// The editor's own call: superseded before or during its settle, it applies nothing.
    @Test func aSupersededTypeaheadReturnsNil() async {
        let catalog = Self.catalog()
        let keystroke = Task { await CatalogTypeahead.matches(for: "chocolate", catalog: catalog) }
        keystroke.cancel()
        #expect(await keystroke.value == nil)
        let settled = await CatalogTypeahead.matches(for: "chocolate", catalog: catalog)
        #expect(settled?.count == 1, "an unsuperseded keystroke still answers")
    }
}
