// GuidedWorkoutRunStateStore.swift
// FernletWidgets  —  compiled into BOTH the Fernlet app target AND the FernletWidgets extension.
//
// The guided-workout specialization of AppGroupRunStateStore (see that file for the
// coordinated-access, ISO-8601, nil-tolerant-read contract). Two writers exist — the app (in-app
// "Done set"/"Skip rest") and the App Intent (Lock Screen buttons) — but never concurrently: the
// app writes only while foregrounded, the intent only while the app isn't driving the UI.

import Foundation

/// Coordinated app-group reader/writer for the single in-progress ``GuidedWorkoutRunState`` JSON
/// file (`GuidedWorkoutRunState.json`).
///
/// The persistence seam between the two guided-workout drivers: `FernletStore` (in-app transitions
/// and the foreground reconcile, which also logs a Lock-Screen-only finish) and
/// ``GuidedWorkoutIntentRunner`` (the Lock Screen buttons). All behavior — `NSFileCoordinator`
/// guarding, ISO-8601/sorted-keys codecs, atomic protected writes, nil-tolerant silent-failure
/// reads, and the `updatedAt` re-stamp on write — lives in the shared ``AppGroupRunStateStore``.
typealias GuidedWorkoutRunStateStore = AppGroupRunStateStore<GuidedWorkoutRunState>
