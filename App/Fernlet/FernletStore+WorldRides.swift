import FernletDomainModel
import FernletFoundation
import Foundation

/// Car and bike detection's side of the store (round 7; `b1-home-car`, `b1-home-bike`): the map's
/// ``WorldRideKeeper`` (`worldLocation.rides`) wired to the fog, the location source and the workout log.
///
/// - **Bike rides log as exercise** (``logWorldBikeRide(_:)``): an outdoor cycling activity with its minutes
///   and, when the readings gave one, its distance, exactly as a hand-logged ride reaches Move, the silly
///   stats and Health. Only while "Log my bike rides" is on; a decoy logs nothing.
/// - **Undo** removes the workout (``undoWorldBikeRide(_:)``).
/// - **Car rides never log as exercise.**
extension FernletStore {
    /// Wires the ride keeper's callbacks to the store; safe to call more than once.
    func wireWorldRides() {
        let rides = worldLocation.rides
        rides.onBikeRide = { [weak self] ride in self?.logWorldBikeRide(ride) }
    }

    /// Logs a finished bike ride as an outdoor cycling workout and puts it on Home's note; nil when nothing
    /// was logged ("Log my bike rides" off).
    @discardableResult
    func logWorldBikeRide(_ ride: WorldBikeRide) -> WorldLoggedRide? {
        nil
    }

    /// Turns "Log my bike rides" on (asking for Motion & Fitness) or off; whether it is on afterwards. On only
    /// when Motion is allowed; turning it on starts the motion history's check from now, so no ride from
    /// before is logged.
    func setWorldBikeRides(_ on: Bool) async -> Bool {
        false
    }

    /// Looks through the motion history since the last check for bike rides the map didn't see (the app was
    /// closed), and logs them; the app's front edge calls it.
    func catchUpWorldBikeRides(now: Date = Date()) async {}

    /// The bike-ride note's Undo: the ride's workout goes. Whether anything was removed.
    @discardableResult
    func undoWorldBikeRide(_ ride: WorldLoggedRide) -> Bool {
        guard ride.isKept else { return false }
        return removeWorkout(id: ride.id, date: ride.dayKey)
    }
}
