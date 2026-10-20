//
//  LiveHeartRateSession.swift
//  Fernlet
//
//  The live heart rate behind guided cardio's zone cue (comparison report idea 9, roadmap step 4b,
//  2026-10-20): the seam the zone director drives (`LiveHeartRateSource`), over the gateway's
//  `HealthKitLiveHeartRateSource` — an iPhone workout session with a live builder, new in iOS 26,
//  collecting heart rate only. The HealthKit code itself lives in `HealthKitService.swift`, the one
//  shipping file allowed to touch the Health store (`HealthKitWriteGateTests`); this file only names
//  what the director needs from it, so tests drive the director with a fake.
//
//  WHICH DEVICES DELIVER LIVE HEART RATE TO AN iPHONE-ONLY SESSION (researched 2026-10-20; every row
//  owes a device check before it is promised anywhere):
//  - A Bluetooth LE heart-rate strap or band using the standard Heart Rate GATT profile, paired in the
//    iPhone's Bluetooth settings: yes. WWDC25 "Track workouts with HealthKit on iOS and iPadOS" (322):
//    an iPhone has no heart-rate sensor, but it can pair with "any device that you wear during a workout
//    that supports the heart rate GATT profile, like a wearable heart rate monitor or the Powerbeats
//    Pro 2", and HealthKit then handles getting heart rate from the device.
//  - Powerbeats Pro 2: yes — the session's own example.
//  - AirPods Pro 3: yes, per Apple's support article "Track your heart rate during workouts with AirPods
//    Pro 3" (third-party workout apps on iPhone, once the person lets the app read heart rate and read
//    and record workouts; one earbud is enough). Not a standard GATT sensor — the system bridges it — so
//    the device check matters most here.
//  - Apple Watch: NOT in real time, as far as the documentation goes. Nothing says an iPhone-only session
//    receives the watch's heart rate; Apple's guidance is to start the workout on the watch and mirror it
//    to the iPhone, which needs a watch app (idea 19, on hold). A watch only takes frequent readings
//    during a workout running on the watch, so the most it can give an iPhone session is the occasional
//    background reading, synced late — which the 20-second freshness rule turns into the talk test.
//  - iPhone alone: no heart rate (no sensor). The cue is the talk test.
//
//  NEVER A SECOND WORKOUT IN HEALTH: the builder's workout is DISCARDED when the session ends. Fernlet's
//  existing write — the guided run's log through `WorkoutHealthKitSync` and the gateway's gated
//  `saveWorkout`, with its provenance metadata, tombstones, edit re-sync and Fernlet's own sharing
//  switches — stays the one writer. Making the builder the writer instead would bypass every one of those
//  for this one kind of run. HealthKit keeps the heart-rate samples the sensor delivered, as it would for
//  any workout app; the data source collects heart rate alone, so the session adds no energy or distance.
//
//  PERMISSION: the session starts only after the person turned on "Heart rate during cardio" and while
//  Fernlet's workout sharing with Apple Health is on (checked by the director and again by the gateway);
//  turning the switch on is what asks Health, once, to let Fernlet read heart rate. iOS shows its own
//  one-time notice the first time a workout session starts (workout data stays readable while the phone
//  is locked) — after that same switch, never silently.
//

import Foundation
import FernletDomainModel
import HealthKitGateway

/// The live heart-rate source the zone director drives: one workout session at a time, heart rate only.
///
/// The gateway's `HealthKitLiveHeartRateSource` is the production conformer; tests inject a fake.
/// Main-actor, like the director.
@MainActor
protocol LiveHeartRateSource: AnyObject {
    /// Whether this device has a Health store at all.
    var isAvailable: Bool { get }

    /// Asks Apple Health to let Fernlet read heart rate — the system sheet, shown only when the person
    /// has not answered before. Returns whether the request completed (HealthKit never says whether read
    /// access was granted; a refusal simply delivers no readings).
    func requestReadAccess() async -> Bool

    /// Starts a workout session of `activity` collecting heart rate only, delivering each new reading
    /// (whole beats per minute) to `onReading` and calling `onEnded` if the session stops by itself.
    /// Returns whether the session began.
    func start(
        activity: WorkoutActivityType,
        onReading: @escaping @MainActor (Int) -> Void,
        onEnded: @escaping @MainActor () -> Void
    ) async -> Bool

    /// Ends the session and discards its workout. Safe to call with nothing running.
    func stop()

    /// Ends and discards a session HealthKit kept alive across a crash, if there is one. Safe to call
    /// with nothing to recover.
    func retireRecoveredSession() async
}

/// The gateway's HealthKit session is the production source.
extension HealthKitLiveHeartRateSource: LiveHeartRateSource {}
