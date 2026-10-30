// MultiDeviceSyncWarning.swift
// CloudKitSync
//
// Pure classifier for the "your devices will diverge without iCloud" warning (Phase 1 of the
// multi-device-without-iCloud roadmap). With sync off there is no merge path between a user's own
// devices, so the day history (and per-row stores) drift apart silently. This type turns three already-
// available signals into a single warning state the UI renders; keeping it free of FileManager / view
// state makes the three-way decision trivially unit-testable.

import Foundation

/// Pure classifier for the "your devices will diverge without iCloud" warning.
///
/// With sync off there is no merge path between a user's own devices, so day history and the
/// per-row stores drift apart silently. `classify` turns three already-available signals —
/// account presence, the sync preference, and ``CloudKitDataService``'s existing-data
/// detection — into one of four warning cases, or `nil` when sync is on with an account signed in
/// and no warning is warranted. Deliberately free of FileManager and view state so the three-way decision is
/// trivially unit-testable; the settings banner and disable-sync sheet render `message` as-is.
public nonisolated enum MultiDeviceSyncWarning: Equatable, Sendable {
    /// An iCloud account is present and another device signed into it already wrote Fernlet data, but
    /// sync is off — the strongest, most specific warning (changes here won't merge with that device).
    case anotherDeviceHasData
    /// An iCloud account is present but sync is off and no other-device data was detected — changes here
    /// won't propagate to (or later merge with) the user's other devices.
    case syncOffWithAccount
    /// No iCloud account on this device — local-only by necessity; nothing can sync or merge.
    case noICloudAccount
    /// Sync is chosen but no iCloud account is signed in: the switch reads "on" while the store loads
    /// without CloudKit (`Persistence` attaches it only with an account), so nothing syncs until the
    /// user signs in. Without this case the page showed no warning at all — "selected" passed for
    /// "working" (simulator log review 2026-10-29).
    case syncOnWithoutAccount

    /// Classify the multi-device state. Returns `nil` when no warning is warranted (sync is on and an
    /// account is signed in, so the devices stay merged through CloudKit).
    ///
    /// - Parameters:
    ///   - iCloudAccountPresent: an iCloud account is signed in on this device
    ///     (`FileManager.default.ubiquityIdentityToken != nil`).
    ///   - syncEnabled: `StoragePreferences.iCloudSyncEnabled`.
    ///   - otherDeviceHasData: another device already wrote data
    ///     (`ExistingDataSummary.hasData` from `detectExistingData()`).
    public static func classify(
        iCloudAccountPresent: Bool,
        syncEnabled: Bool,
        otherDeviceHasData: Bool
    ) -> MultiDeviceSyncWarning? {
        guard iCloudAccountPresent else { return syncEnabled ? .syncOnWithoutAccount : .noICloudAccount }
        guard !syncEnabled else { return nil }
        return otherDeviceHasData ? .anotherDeviceHasData : .syncOffWithAccount
    }

    /// User-facing copy for the settings banner / disable-sync sheet. Onboarding card copy is composed at
    /// the call site because its framing differs (a forward-looking choice, not a current-state warning).
    public var message: String {
        switch self {
        case .anotherDeviceHasData:
            // Phrased "this iCloud account" rather than "another device": the detected data may be this
            // device's own earlier upload (e.g. after "stop syncing, keep iCloud data"), and we don't track
            // a writer identity to tell them apart.
            return "This iCloud account already has Fernlet data. With sync off, changes here won't merge "
                + "with it, so this device and any others will drift apart."
        case .syncOffWithAccount:
            return "With iCloud sync off, changes on this device won't sync to your other Fernlet "
                + "devices, and they won't merge later."
        case .noICloudAccount:
            return "Without iCloud, this device's logs stay here only — they won't sync to or merge "
                + "with another device."
        case .syncOnWithoutAccount:
            // Package source: `bundle: .module`, or the lookup goes to `Bundle.main` and renders English forever.
            return String(localized: "multiDevice.syncOnWithoutAccount",
                          defaultValue: "iCloud sync is on, but this iPhone isn't signed in to iCloud, so nothing is syncing yet. Your logs are safe on this iPhone and start syncing once you sign in to iCloud in the Settings app.",
                          bundle: .module,
                          comment: "Privacy & Data, multiple-devices note: the user chose iCloud sync but no iCloud account is signed in on this device.")
        }
    }
}
