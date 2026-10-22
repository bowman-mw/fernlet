import Foundation

/// The shell's actions: the fixture controls, the companion, the panels, quick starts and logging.
extension WorldShellModel {
    // MARK: Fixture controls

    /// Moves you to a fixture spot: ends any walk, puts the companion there and recentres.
    func move(to newSpot: FixtureSpot) {
        stopReplay(logRide: false)
        setRide(.onFoot)
        setSpot(newSpot)
        setCompanion(newSpot.location)
        quickStartOpen = false
        recomputeFog()
        recentre()
        let lines: [FixtureSpot: String] = [.trail: "Oh, our trail!", .noodle: "Noodles again? I approve.",
                                            .gym: "I remember this place.", .fresh: "Somewhere new! Look at it all."]
        say(level.visits(to: newSpot) > 0 || newSpot == .fresh ? (lines[newSpot] ?? careState.thought) : careState.thought)
    }

    /// Switches between on foot, a bike and a car. Leaving a bike logs the ride, with Undo.
    func changeRide(to newRide: CompanionRide) {
        guard newRide != ride else { return }
        let wasBike = ride == .bike
        stopReplay(logRide: wasBike)
        quickStartOpen = false
        panel = nil
        setRide(newRide)
        switch newRide {
        case .car:
            startReplay(RouteReplay(kind: .car, route: Polyline(RecordedRoutes.carLoop).loopStarting(near: companionPosition)))
            showBanner(.car, "Riding along", "Car or bus, it's all the same here. Quick starts pause, and the fog lifts a thin line along the road.")
        case .bike:
            startReplay(RouteReplay(kind: .bike, route: Polyline(RecordedRoutes.bikeLoop).loopStarting(near: companionPosition)))
            showBanner(.bike, "On your bike", "Fernlet pedals along. When you stop, the ride logs itself.")
        case .onFoot:
            setCompanion(spot.location)
            recomputeFog()
            recentre()
        }
    }

    /// Turns the decoy session on or off. Decoy hides all map history; its own walks vanish after.
    func setDecoySession(_ on: Bool) {
        stopReplay(logRide: false)
        setRide(.onFoot)
        setCompanion(spot.location)
        dropDecoyTraces()
        setDecoy(on)
        panel = nil
        quickStartOpen = false
        privateUnlocked = false
        recomputeFog()
        recentre()
    }

    /// Changes how long you've had Fernlet, which changes what history exists.
    func setLevel(_ newLevel: TimeWithFernlet) {
        level = newLevel
        recomputeFog()
    }

    /// Puts every fixture back to its launch value.
    func resetFixtures() {
        setDecoySession(false)
        careState = .okay
        setLevel(.month)
        phaseOverride = nil
        water = 4
        (protein, carbs, fat) = (38, 120, 22)
        outfit = .none
        sessionStamps = []
        move(to: .home)
    }

    // MARK: The camera

    /// Points the camera back at the companion and follows it again.
    func recentre() {
        camera.center = companionPosition
        camera.follows = true
        camera.revision += 1
    }

    /// Records the base map's visible area.
    func report(_ newViewport: MapViewport) {
        guard newViewport != viewport else { return }
        viewport = newViewport
    }

    // MARK: Panels

    /// Opens a panel, or closes it if it's already open. Nothing opens mid-walk.
    func toggle(_ kind: PanelKind) {
        guard !isWalking else { return }
        quickStartOpen = false
        privateUnlocked = false
        panel = panel == kind ? nil : kind
    }

    // MARK: Notices

    /// Shows the speech bubble for a few seconds (nil: the companion's own thought).
    func say(_ text: String?, for seconds: Double = 4.5) {
        let line = ShellSpeech(text: text ?? careState.thought)
        speech = line
        schedule("speech", after: seconds) { [weak self] in if self?.speech == line { self?.speech = nil } }
    }

    /// Shows a toast above the item bar.
    func showToast(_ message: String, action: ToastAction? = nil) {
        let note = ShellToast(message: message, action: action)
        toast = note
        schedule("toast", after: action == nil ? 2.8 : 4.5) { [weak self] in if self?.toast == note { self?.toast = nil } }
    }

    /// Shows a pixel banner under the status bar.
    func showBanner(_ badge: ShellBanner.Badge, _ title: String, _ subtitle: String) {
        let note = ShellBanner(badge: badge, title: title, subtitle: subtitle)
        banner = note
        schedule("banner", after: 3.8) { [weak self] in if self?.banner == note { self?.banner = nil } }
    }
}
