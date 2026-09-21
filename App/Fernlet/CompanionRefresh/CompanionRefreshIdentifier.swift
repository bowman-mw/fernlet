//
//  CompanionRefreshIdentifier.swift
//  Fernlet
//
//  Network migration P10 item 2 (plan §17.2, §16.4): the first file of the companion
//  background-refresh directory, and deliberately the smallest true thing in it — one frozen
//  identifier and nothing else.
//
//  **Why this file exists before the code that uses it.** §16.4's background-refresh import wall
//  has to land in the FIRST commit that adds any refresh code, because a wall that arrives after
//  the handler argues with a fait accompli. A wall needs something to scan, and
//  `BackgroundRefreshBoundaryTests` scans this DIRECTORY rather than a list of file names — so
//  item 3 (the scheduling seam) and item 4 (the handler) are covered by it the moment their files
//  land, without anybody remembering to extend a list. This file is what makes the directory
//  exist, and its identifier is the wall's positive needle: an emptied or gutted directory reds
//  the suite instead of passing vacuously.
//
//  **What this file does NOT do.** It does not register the identifier, submit a request, or
//  reference `BackgroundTasks` at all — that is item 3, which adds
//  `BGTaskSchedulerPermittedIdentifiers` in `Info.plist` and the `fetch` background mode beside
//  it. Nothing here is reachable from a radio, a health store, a CloudKit container or a language
//  model, which is the whole point: the directory starts on the right side of the wall.
//
//  **No persisted surface.** A frozen string constant writes nothing — no `UserDefaults` key, no
//  file, no keychain row — so the wipe wall (plan §17.3) is owed no disposition row by this file.
//

/// The companion background refresh's namespace: today, its one frozen task identifier.
///
/// Refresh work is spread over the P10 items — this identifier (item 2), the scheduling seam and
/// the plist entries (item 3), and the handler itself (item 4) — and all of it lives under
/// `App/Fernlet/CompanionRefresh/`, which is the unit `BackgroundRefreshBoundaryTests` walks. The
/// namespace is an `enum` with no cases so it can never be instantiated, matching
/// `SettingsSearchIndex` and the tree's other constant namespaces.
///
/// ## Concurrency
///
/// `nonisolated`, because the app target builds with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`
/// and a `BGTaskScheduler` registration is not reliably delivered on the main actor. This is the
/// same reason `MeshContinuationTaskHost.identifierPrefix` is spelled `nonisolated static let`:
/// an identifier that needs an `await` to read is an identifier the registration site cannot use.
nonisolated enum CompanionRefresh {

    /// The companion `BGAppRefreshTask` identifier — `MBO.Fernlet.companion-refresh`.
    ///
    /// Frozen: it is a reverse-DNS name iOS matches literally against `Info.plist`'s
    /// `BGTaskSchedulerPermittedIdentifiers`, so renaming it silently stops the system delivering
    /// the task. Unlike the mesh continuation's `MBO.Fernlet.mesh-continuation.` prefix this is a
    /// WHOLE identifier, not a prefix: there is exactly one companion refresh per process, so
    /// there is nothing to append and no wildcard to permit.
    ///
    /// This literal is also the positive needle of the background-refresh import wall — it must
    /// appear exactly once under `App/Fernlet/CompanionRefresh/`, as code rather than as prose, so
    /// a directory that was emptied or reduced to comments fails the wall instead of passing it.
    static let taskIdentifier = "MBO.Fernlet.companion-refresh"
}
