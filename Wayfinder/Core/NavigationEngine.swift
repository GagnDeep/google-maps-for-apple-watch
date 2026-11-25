import Foundation
import CoreLocation
import Observation
import SwiftData

/// Turn-by-turn engine running on Google's route: snaps you to the polyline, times voice + haptic
/// prompts, detects going off-route and re-routes through Google, and logs the trip to your Timeline.
@MainActor
@Observable
final class NavigationEngine {
    static let shared = NavigationEngine()

    enum Phase: Equatable { case idle, navigating, rerouting, arrived }
    enum Stage: Hashable { case prepare, now }

    var phase: Phase = .idle
    var route: Route?
    var destination: Place?
    var mode: TravelMode = .driving
    var progress: Double = 0
    var nextStepIndex = 0
    var distanceToNext: Double = 0
    var remainingDistance: Double = 0
    var remainingTime: Double = 0
    var eta = Date()
    var speed: Double = 0
    var course: Double = 0
    var snapped: CLLocationCoordinate2D?
    var startedAt: Date?
    var travelledDistance: Double = 0
    var isSimulating = false
    /// Whole-route overview instead of the follow camera.
    var overview = false
    var rerouteCount = 0
    var lastError: String?

    @ObservationIgnored var modelContext: ModelContext?
    @ObservationIgnored private var travelled: [CLLocationCoordinate2D] = []
    @ObservationIgnored private var announced: [Int: Set<Stage>] = [:]
    @ObservationIgnored private var offRouteStrikes = 0
    @ObservationIgnored private var lastSegment = 0
    @ObservationIgnored private var lastFix: CLLocation?
    @ObservationIgnored private var observer: UUID?
    @ObservationIgnored private var lastReroute = Date.distantPast
    @ObservationIgnored private var simulation: Task<Void, Never>?
    @ObservationIgnored private var originName = "Your location"
    @ObservationIgnored private var tripSaved = false

    var isActive: Bool { phase != .idle }
    var nextStep: RouteStep? { route?.steps[safe: nextStepIndex] }
    var thenStep: RouteStep? {
        guard let route, let next = nextStep, let after = route.steps[safe: nextStepIndex + 1] else { return nil }
        return after.startOffset - next.startOffset < (mode.isVehicle ? 250 : 60) ? after : nil
    }
    var currentRoad: String? {
        guard let route, nextStepIndex > 0 else { return nil }
        let text = route.steps[nextStepIndex - 1].instruction
        for marker in [" onto ", " on ", " toward "] {
            if let r = text.range(of: marker) { return String(text[r.upperBound...]) }
        }
        return nil
    }

    // MARK: - Resume after the app is closed mid-route

    private struct ActiveTrip: Codable { var destination: Place; var mode: TravelMode; var date: Date }

    private static func persistActiveTrip(destination: Place, mode: TravelMode) {
        if let data = try? JSONEncoder().encode(ActiveTrip(destination: destination, mode: mode, date: .now)) {
            UserDefaults.standard.set(data, forKey: SettingsKey.activeTrip)
        }
    }

    /// A route that was still running when the app was last closed (within the last 3 hours).
    static func interruptedTrip() -> (destination: Place, mode: TravelMode)? {
        guard let data = UserDefaults.standard.data(forKey: SettingsKey.activeTrip),
              let t = try? JSONDecoder().decode(ActiveTrip.self, from: data),
              Date().timeIntervalSince(t.date) < 3 * 3600 else {
            UserDefaults.standard.removeObject(forKey: SettingsKey.activeTrip)
            return nil
        }
        return (t.destination, t.mode)
    }

    static func discardInterruptedTrip() { UserDefaults.standard.removeObject(forKey: SettingsKey.activeTrip) }

    /// Re-routes from where you are now and picks the trip back up.
    func resume(to destination: Place, mode: TravelMode) async -> Bool {
        guard let origin = await LocationService.shared.currentLocation()?.coordinate,
              let r = try? await GoogleDirections.routes(from: origin, to: destination.coordinate, mode: mode, destinationName: destination.name),
              let best = r.routes.first else { return false }
        start(route: best, to: destination)
        return true
    }

    // MARK: - Lifecycle

    func start(route: Route, to destination: Place, simulate: Bool = false) {
        stop(save: false)
        self.route = route
        self.destination = destination
        self.mode = route.mode
        self.phase = .navigating
        self.startedAt = .now
        self.progress = 0
        self.nextStepIndex = min(1, route.steps.count - 1)
        self.announced = [:]
        self.offRouteStrikes = 0
        self.lastSegment = 0
        self.travelled = []
        self.travelledDistance = 0
        self.rerouteCount = 0
        self.tripSaved = false
        self.isSimulating = simulate
        self.originName = route.originName?.components(separatedBy: ",").first ?? "Your location"
        refreshDerived()

        LocationService.shared.beginNavigation(mode: route.mode)
        Guidance.shared.tap(.start)
        let first = route.steps.first?.instruction ?? ""
        let intro = route.mode == .transit
            ? "Starting transit directions. About \(Fmt.duration(route.duration)) to \(destination.name)."
            : "\(first). \(Fmt.duration(route.duration)) to \(destination.name)."
        Guidance.shared.speak(intro, interrupt: true, priority: .info)
        announced[0] = [.prepare, .now]

        if !simulate { Self.persistActiveTrip(destination: destination, mode: route.mode) }

        if simulate {
            startSimulation()
        } else {
            observer = LocationService.shared.observe { [weak self] loc in self?.update(with: loc) }
            if let loc = LocationService.shared.location { update(with: loc) }
        }
    }

    func stop(save: Bool = true) {
        guard phase != .idle || route != nil else { return }
        UserDefaults.standard.removeObject(forKey: SettingsKey.activeTrip)
        simulation?.cancel(); simulation = nil
        LocationService.shared.removeObserver(observer); observer = nil
        if save { saveTrip(arrived: phase == .arrived) }
        if phase != .idle { LocationService.shared.endNavigation() }
        Guidance.shared.stopSpeaking()
        phase = .idle
        route = nil
        destination = nil
        snapped = nil
        isSimulating = false
        overview = false
    }


    /// Re-speaks the upcoming instruction (tap the banner, like Google's "repeat").
    func repeatInstruction() {
        guard let step = nextStep else { return }
        Guidance.shared.speak("In \(Fmt.spokenDistance(distanceToNext)), \(step.spoken)", interrupt: true, priority: .alert)
    }

    // MARK: - Location updates

    func update(with location: CLLocation) {
        guard phase == .navigating || phase == .rerouting, let route else { return }
        if let prev = lastFix, phase == .navigating {
            let d = location.distance(from: prev)
            if d < 200 { travelledDistance += d }
        }
        lastFix = location
        travelled.append(location.coordinate)
        speed = max(0, location.speed)
        if location.course >= 0, location.speed > 1.2 {
            course = location.course
        } else if let h = LocationService.shared.heading, !mode.isVehicle {
            course = h
        }

        guard phase == .navigating else { return }
        guard route.mode != .transit else {
            remainingDistance = location.distance(from: destination?.location ?? location)
            if remainingDistance < mode.arrivalRadius * 2 { arrive() }
            return
        }

        let (offset, lateral, segment, point) = project(location.coordinate, on: route)
        lastSegment = segment
        let accuracySlack = min(max(location.horizontalAccuracy, 5), 40)
        if lateral > mode.offRouteThreshold + accuracySlack {
            offRouteStrikes += 1
            if offRouteStrikes >= 3 { reroute(from: location); return }
        } else {
            offRouteStrikes = 0
            progress = max(progress - 15, offset) // tolerate jitter, never jump far backwards
            snapped = point
        }
        if mode.isVehicle, lateral < 25, let seg = route.coordinates[safe: segment], let nxt = route.coordinates[safe: segment + 1] {
            if location.speed < 1.2 { course = seg.bearing(to: nxt) }
        }

        refreshDerived()

        // Arrival.
        if let dest = destination, location.distance(from: dest.location) < mode.arrivalRadius
            || remainingDistance < mode.arrivalRadius {
            arrive()
            return
        }
        announce()
    }

    private func refreshDerived() {
        guard let route else { return }
        let total = route.cumulative.last ?? route.distance
        nextStepIndex = route.steps.firstIndex { $0.startOffset > progress + 4 } ?? (route.steps.count - 1)
        if nextStepIndex == 0 { nextStepIndex = min(1, route.steps.count - 1) }
        distanceToNext = max(0, (route.steps[safe: nextStepIndex]?.startOffset ?? total) - progress)
        remainingDistance = max(0, total - progress)
        let fraction = total > 0 ? remainingDistance / total : 0
        remainingTime = route.duration * fraction
        eta = Date().addingTimeInterval(remainingTime)
    }

    private func announce() {
        guard let route, let step = nextStep else { return }
        var done = announced[nextStepIndex] ?? []
        let prev = route.steps[safe: nextStepIndex - 1]
        let legLength = step.startOffset - (prev?.startOffset ?? 0)

        if !done.contains(.prepare), distanceToNext <= mode.prepareDistance, distanceToNext > mode.nowDistance * 1.8,
           legLength > mode.prepareDistance * 0.5 {
            done.insert(.prepare)
            Guidance.shared.tap(.prepare)
            Guidance.shared.speak("In \(Fmt.spokenDistance(distanceToNext)), \(step.spoken)", priority: .info)
        }
        if !done.contains(.now), distanceToNext <= mode.nowDistance {
            done.insert(.now)
            done.insert(.prepare)
            switch step.maneuver.side {
            case .left: Guidance.shared.tap(.left)
            case .right: Guidance.shared.tap(.right)
            case .none: Guidance.shared.tap(step.maneuver == .arrive ? .arrive : .straight)
            }
            var text = step.spoken
            if let then = thenStep { text += ", then \(then.spoken)" }
            Guidance.shared.speak(text, interrupt: true)
        }
        announced[nextStepIndex] = done
    }

    private func arrive() {
        guard phase != .arrived else { return }
        phase = .arrived
        progress = route?.cumulative.last ?? progress
        remainingDistance = 0
        remainingTime = 0
        Guidance.shared.tap(.arrive)
        Guidance.shared.speak("You have arrived at \(destination?.name ?? "your destination").", interrupt: true, priority: .alert)
        simulation?.cancel()
        saveTrip(arrived: true)
    }

    private func reroute(from location: CLLocation) {
        guard phase == .navigating, Date().timeIntervalSince(lastReroute) > 8, let destination else { return }
        lastReroute = Date()
        phase = .rerouting
        offRouteStrikes = 0
        Guidance.shared.tap(.reroute)
        Guidance.shared.speak("Rerouting", interrupt: true, priority: .alert)
        Task {
            do {
                let result = try await GoogleDirections.routes(from: location.coordinate, to: destination.coordinate, mode: mode, destinationName: destination.name)
                guard self.phase == .rerouting, let best = result.routes.first else { throw GoogleDirections.RoutingError.noRoute(mode) }
                self.route = best
                self.progress = 0
                self.lastSegment = 0
                self.announced = [0: [.prepare, .now]]
                self.rerouteCount += 1
                self.phase = .navigating
                self.refreshDerived()
                if let step = self.nextStep {
                    Guidance.shared.speak("In \(Fmt.spokenDistance(self.distanceToNext)), \(step.spoken)", priority: .info)
                }
            } catch {
                self.lastError = error.localizedDescription
                if self.phase == .rerouting { self.phase = .navigating }
            }
        }
    }

    // MARK: - Geometry

    /// Projects a coordinate onto the route near the last known segment.
    /// Returns (distance along route, lateral distance, segment index, snapped point).
    private func project(_ c: CLLocationCoordinate2D, on route: Route) -> (Double, Double, Int, CLLocationCoordinate2D) {
        let pts = route.coordinates
        guard pts.count > 1 else { return (0, 0, 0, c) }
        let lo = max(0, lastSegment - 8), hi = min(pts.count - 2, lastSegment + 400)
        var best = (offset: 0.0, lateral: Double.greatestFiniteMagnitude, seg: lastSegment, point: c)
        let kLat = 111_320.0, kLon = 111_320.0 * cos(c.latitude * .pi / 180)
        for i in lo...hi {
            let a = pts[i], b = pts[i + 1]
            let ax = (a.longitude - c.longitude) * kLon, ay = (a.latitude - c.latitude) * kLat
            let bx = (b.longitude - c.longitude) * kLon, by = (b.latitude - c.latitude) * kLat
            let dx = bx - ax, dy = by - ay
            let len2 = dx * dx + dy * dy
            var t = len2 > 0 ? -(ax * dx + ay * dy) / len2 : 0
            t = min(max(t, 0), 1)
            let px = ax + t * dx, py = ay + t * dy
            let d = (px * px + py * py).squareRoot()
            // Small bias toward continuing forward so parallel/overlapping segments don't snap backwards.
            let biased = d + (i < lastSegment ? 6 : 0)
            if biased < best.lateral {
                let segLen = route.cumulative[i + 1] - route.cumulative[i]
                let point = CLLocationCoordinate2D(latitude: a.latitude + (b.latitude - a.latitude) * t,
                                                   longitude: a.longitude + (b.longitude - a.longitude) * t)
                best = (route.cumulative[i] + segLen * t, biased, i, point)
            }
        }
        return (best.offset, best.lateral, best.seg, best.point)
    }

    // MARK: - Timeline

    private func saveTrip(arrived: Bool) {
        guard !tripSaved, !isSimulating, let context = modelContext, let startedAt, UserDefaults.standard.bool(forKey: SettingsKey.saveTimeline) else { return }
        guard Date().timeIntervalSince(startedAt) > 20 || arrived else { return }
        tripSaved = true
        let path = travelled.count > 1 ? travelled : (route?.coordinates ?? [])
        let trip = Trip(startedAt: startedAt, endedAt: .now, mode: mode, destination: destination,
                        originName: originName, distance: travelledDistance > 0 ? travelledDistance : progress,
                        path: path, arrived: arrived)
        context.insert(trip)
        try? context.save()
    }

    // MARK: - Simulation (route preview "drive")

    private func startSimulation() {
        guard let route else { return }
        let speed: Double = switch route.mode {
        case .driving: 15
        case .twoWheeler: 12
        case .cycling: 6
        case .walking, .transit: 1.6
        }
        simulation = Task { @MainActor [weak self] in
            var travelled = 0.0
            let total = route.cumulative.last ?? 0
            while let self, !Task.isCancelled, self.phase != .arrived, travelled <= total + 5 {
                guard let r = self.route else { break }
                let rt = r.cumulative.last ?? 0
                let d = min(travelled, rt)
                let i = max(0, (r.cumulative.firstIndex { $0 > d } ?? r.coordinates.count) - 1)
                let a = r.coordinates[i], b = r.coordinates[min(i + 1, r.coordinates.count - 1)]
                let seg = max(r.cumulative[min(i + 1, r.cumulative.count - 1)] - r.cumulative[i], 0.001)
                let t = min(max((d - r.cumulative[i]) / seg, 0), 1)
                let c = CLLocationCoordinate2D(latitude: a.latitude + (b.latitude - a.latitude) * t,
                                               longitude: a.longitude + (b.longitude - a.longitude) * t)
                let loc = CLLocation(coordinate: c, altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5,
                                     course: a.bearing(to: b), speed: speed, timestamp: .now)
                self.update(with: loc)
                travelled += speed
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}
