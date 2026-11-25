import CoreLocation
import Observation

@MainActor
@Observable
final class LocationService: NSObject, CLLocationManagerDelegate {
    static let shared = LocationService()

    var location: CLLocation?
    var heading: Double?
    var authorization: CLAuthorizationStatus = .notDetermined
    var lastError: String?

    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var backgroundSession: CLBackgroundActivitySession?
    @ObservationIgnored private var listeners: [UUID: (CLLocation) -> Void] = [:]
    @ObservationIgnored private var headingUsers = 0

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 5
        manager.headingFilter = 3
        authorization = manager.authorizationStatus
    }

    var isAuthorized: Bool { authorization == .authorizedWhenInUse || authorization == .authorizedAlways }
    var coordinate: CLLocationCoordinate2D? { location?.coordinate }

    func start() {
        if authorization == .notDetermined { manager.requestWhenInUseAuthorization() }
        manager.startUpdatingLocation()
    }

    func startHeading() {
        headingUsers += 1
        if CLLocationManager.headingAvailable() { manager.startUpdatingHeading() }
    }

    func stopHeading() {
        headingUsers = max(0, headingUsers - 1)
        if headingUsers == 0 { manager.stopUpdatingHeading() }
    }

    /// High-accuracy, background-capable updates for turn-by-turn guidance.
    func beginNavigation(mode: TravelMode) {
        manager.activityType = mode.activityType
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = kCLDistanceFilterNone
        if authorization == .authorizedWhenInUse || authorization == .authorizedAlways {
            manager.allowsBackgroundLocationUpdates = true
            backgroundSession = CLBackgroundActivitySession()
        }
        manager.startUpdatingLocation()
        startHeading()
    }

    func endNavigation() {
        backgroundSession?.invalidate()
        backgroundSession = nil
        manager.allowsBackgroundLocationUpdates = false
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 5
        manager.activityType = .other
        stopHeading()
    }

    @discardableResult
    func observe(_ handler: @escaping (CLLocation) -> Void) -> UUID {
        let id = UUID()
        listeners[id] = handler
        return id
    }

    func removeObserver(_ id: UUID?) {
        if let id { listeners[id] = nil }
    }

    /// Waits briefly for a fix (used by intents / quick actions).
    func currentLocation(timeout: Double = 6) async -> CLLocation? {
        if let location, abs(location.timestamp.timeIntervalSinceNow) < 60 { return location }
        start()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let location { return location }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return location
    }

    // MARK: - Delegate

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorization = status
            if status == .authorizedWhenInUse || status == .authorizedAlways { self.manager.startUpdatingLocation() }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        Task { @MainActor in
            guard last.horizontalAccuracy >= 0, last.horizontalAccuracy < 500 else { return }
            self.location = last
            self.lastError = nil
            for l in self.listeners.values { l(last) }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        let h = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        Task { @MainActor in
            guard newHeading.headingAccuracy >= 0 else { return }
            self.heading = h
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.lastError = error.localizedDescription }
    }
}
