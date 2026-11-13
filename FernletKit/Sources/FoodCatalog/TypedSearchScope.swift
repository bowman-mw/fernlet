// TypedSearchScope.swift
// Roadmap G1, F8 (Docs/Handoff review 2026-11-09): a superseded typed search stops its retrieval.
import Foundation

/// Marks the typed search running in the current task, so work beneath ``FoodCatalog``'s public
/// entry point — the SQLite fetch loop, the per-source index build — can stop once a newer keystroke
/// has cancelled it (roadmap G1, F8: a superseded search used to finish its whole 10,000-row
/// retrieval). A machine-generated search never sets it, so a resolver or importer that happens to run
/// in a cancelled task still gets its whole answer, never a silently truncated one.
nonisolated enum TypedSearchScope {
    /// Whether the current task is running a typed search. Task-local: bound with `withValue` for the
    /// duration of one search, never assigned.
    @TaskLocal static var isTyped = false

    /// Whether the current task is a typed search that has been cancelled.
    static var isSuperseded: Bool { isTyped && Task.isCancelled }
}
