import Foundation

/// Replaying recorded routes (walks, the hike, the car and bike loops), the companion, quick
/// starts and quick logging.
extension WorldShellModel {
    /// Seconds between replay frames.
    static let tickSeconds = 0.08

    // MARK: Replay

    /// Starts a walk together from where you stand, replaying this spot's recorded walk.
    func startWalk(hike: Bool) {
        guard ride == .onFoot, !isWalking else { return }
        panel = nil
        quickStartOpen = false
        let route = Polyline(hike ? RecordedRoutes.parkLoop : spot.walkRoute)
        startReplay(RouteReplay(kind: hike ? .hike : .walk, route: route))
        say(hike ? "The Oak Park loop! I know this one." : "Let's go!", for: 2.2)
    }

    /// Begins a replay and its frame ticker (bounded: at most an hour of frames).
    func startReplay(_ newReplay: RouteReplay) {
        setReplay(newReplay)
        setCompanion(newReplay.position)
        recentre()
        setTicker(Task { [weak self] in
            for _ in 0..<45_000 {
                do { try await Task.sleep(for: .seconds(Self.tickSeconds)) } catch { return }
                guard let self, self.advanceReplay() else { return }
            }
        })
    }

    /// One frame: moves the companion along, lifts the fog, follows with the camera. Returns
    /// whether the replay goes on.
    private func advanceReplay() -> Bool {
        guard var current = replay else { return false }
        current.travelled += current.speed * Self.tickSeconds
        let position = current.position
        current.freshCells += liftLive(at: position, radius: current.liftRadius)
        setReplay(current)
        setCompanion(position)
        if camera.follows {
            camera.center = position
            camera.revision += 1
        }
        if current.isFinished {
            finishWalk()
            return false
        }
        return true
    }

    /// Ends a walk or hike: keeps its trace, says how far it went and what it uncovered.
    func finishWalk() {
        guard let done = replay, isWalking else { return }
        setTicker(nil)
        setReplay(nil)
        addTrace(done.trace)
        recomputeFog()
        let uncovered = done.freshCells > 0 ? " · \(done.freshCells) new tiles uncovered" : ""
        showToast(done.kind == .hike ? "Oak Park loop · \(done.kilometres) km together\(uncovered)" : "\(done.kilometres) km together\(uncovered)")
        say(done.isFinished ? "That was lovely." : "Good enough. Home we go.", for: 3.5)
    }

    /// Stops whatever is replaying. A bike ride of more than 300 m logs itself, with Undo.
    func stopReplay(logRide: Bool) {
        guard let current = replay else { return }
        if isWalking {
            finishWalk()
            return
        }
        setTicker(nil)
        setReplay(nil)
        addRideTrace(kind: current.kind, points: current.route.prefix(to: min(current.travelled, current.route.length)))
        guard logRide, current.kind == .bike, current.travelled > 300 else { return }
        showToast("Bike ride logged · \(current.kilometres) km · counts as movement", action: .undoRide)
        if !sessionStamps.contains("Wheels and Waves") {
            sessionStamps.insert("Wheels and Waves", at: 0)
            showBanner(.bike, "New stamp: Wheels and Waves", "Your first ride. Grand tours has begun.")
        }
    }

    // MARK: The companion

    /// Tap to pet: a hop and a heart, or the settled pose if you pet again within three seconds.
    func pet(now: Date = .now) {
        let again = now.timeIntervalSince(lastPet) < 3
        lastPet = now
        petCount += 1
        if again {
            settledUntil = now.addingTimeInterval(20)
            say("Mm. That's nice.", for: 3)
        } else {
            say(nil, for: 3)
        }
    }

    // MARK: Quick starts and logging

    /// Runs one quick-start row.
    func runQuickStart(_ option: QuickStartOption) {
        quickStartOpen = false
        switch option.action {
        case .workout(let message):
            showToast(message)
            say("Let's do this. Gently.", for: 3)
        case .hike: startWalk(hike: true)
        case .walk: startWalk(hike: false)
        case .logUsual:
            (protein, carbs, fat) = (protein + 24, carbs + 62, fat + 18)
            showToast("Tonkotsu ramen logged, from your meals here.")
            say("Noodles! Good plan.", for: 3)
        case .menuSearch:
            showToast("Fernlet's food lookup searches \"Hoshi Noodle Bar nutrition\". Only the name leaves the phone.")
        }
    }

    /// Logs a glass of water, with Undo.
    func logWater() {
        water = min(8, water + 1)
        petCount += 1
        showToast("Water logged · \(water) of 8", action: .undoWater)
    }

    /// Logs a meal: the first one this session is a cookie, which earns the Crumb Goblin stamp.
    func logMeal() {
        guard !sessionStamps.contains("Crumb Goblin") else {
            showToast("The meal sheet opens here, as it does from any tab today.")
            return
        }
        sessionStamps.insert("Crumb Goblin", at: 0)
        (protein, carbs, fat) = (protein + 1, carbs + 16, fat + 7)
        panel = nil
        showBanner(.cookie, "New stamp: Crumb Goblin", "Your first cookie. Cookies per day has begun.")
        say("A cookie! Respect.", for: 3)
    }

    /// The toast's Undo.
    func undo(_ action: ToastAction) {
        switch action {
        case .undoWater:
            water = max(0, water - 1)
            showToast("Water back to \(water) of 8")
        case .undoRide:
            showToast("Ride removed. It won't count.")
        }
    }
}
