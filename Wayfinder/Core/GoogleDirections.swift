import Foundation
import CoreLocation
import MapKit

struct RouteOptions: Hashable, Sendable {
    var avoidHighways = false
    var avoidTolls = false
    var avoidFerries = false

    static var saved: RouteOptions {
        let d = UserDefaults.standard
        return RouteOptions(avoidHighways: d.bool(forKey: SettingsKey.avoidHighways),
                            avoidTolls: d.bool(forKey: SettingsKey.avoidTolls),
                            avoidFerries: d.bool(forKey: SettingsKey.avoidFerries))
    }
}

struct DirectionsResult: Sendable {
    var routes: [Route]
    /// Google's per-mode ETA strip (drive / walk / bike…) returned alongside every request.
    var modeETAs: [TravelMode: TimeInterval]
    var originAddress: String?
    var destinationAddress: String?
}

/// Google Maps directions via the public web endpoint: traffic-aware ETAs, alternatives, turn-by-turn steps
/// and full-resolution route geometry. Transit falls back to Apple's transit ETA (Google gates transit behind a web session).
enum GoogleDirections {
    private static func googleMode(_ m: TravelMode) -> Int {
        switch m {
        case .driving: 0
        case .cycling: 1
        case .walking: 2
        case .transit: 3
        case .twoWheeler: 9
        }
    }

    private static func mode(fromGoogle i: Int) -> TravelMode? {
        switch i {
        case 0: .driving
        case 1: .cycling
        case 2: .walking
        case 3: .transit
        case 9: .twoWheeler
        default: nil
        }
    }

    static func pb(from o: CLLocationCoordinate2D, to d: CLLocationCoordinate2D, mode: TravelMode, options: RouteOptions) -> String {
        let center = CLLocationCoordinate2D(latitude: (o.latitude + d.latitude) / 2, longitude: (o.longitude + d.longitude) / 2)
        let span = max(2000, o.distance(to: d) * 1.6)
        var avoid = ""
        if options.avoidHighways { avoid += "!1b1" }
        if options.avoidTolls { avoid += "!2b1" }
        if options.avoidFerries { avoid += "!3b1" }
        let avoidCount = avoid.components(separatedBy: "!").count - 1
        func wp(_ c: CLLocationCoordinate2D) -> String { "!1m4!3m2!3d\(c.latitude)!4d\(c.longitude)!6e2" }
        let flags = "!32i1!49b1!63m0!66b1!85b1!114b1!149b1!206b1!209b1!212b1!215b1!216b1!222b1!223b1!234b1!235b1!239b1!246b1!253b1!260b1!262b1!266b1!270b1!271b1!273b1!276b1!281b1!294b1!300b1!301b1!302i300!303i100!327m0"
        return wp(o) + wp(d)
            + "!3m12" + GoogleClient.viewport(center, span: span) + "!2m3!1f0!2f0!3f0!3m2!1i400!2i400!4f13.1"
            + "!6m\(65 + avoidCount)!1m5!18b1!30b1!31m1!1b1!34e1"
            + "!2m\(4 + avoidCount)\(avoid)!5m1!6e2!20e3!39b1"
            + "!6m33" + flags
            + "!10b1!12b1!13b1!14b1!16b1!17m1!3e1"
            + "!20m6!1e\(googleMode(mode))!2e3!5e2!6b1!8b1!14b1"
            + "!46m1!1b0!96b1!97m1!2b1!99b1!27b1!47m2!8b1!10e2"
    }

    static func routes(from origin: CLLocationCoordinate2D, to destination: CLLocationCoordinate2D,
                       mode: TravelMode, options: RouteOptions = .saved, destinationName: String? = nil) async throws -> DirectionsResult {
        if mode == .transit { return try await appleTransit(from: origin, to: destination) }
        let url = GoogleClient.url("https://www.google.com/maps/preview/directions", [
            "authuser": "0", "hl": GoogleClient.language, "gl": GoogleClient.region,
            "pb": pb(from: origin, to: destination, mode: mode, options: options),
        ])
        let root = try await GoogleClient.fetch(url)
        let top = root[0]

        var etas: [TravelMode: TimeInterval] = [:]
        for e in top[20].array {
            if let m = e[0, 0].int.flatMap(mode(fromGoogle:)), e[1].int == 0, let secs = e[2, 0].double { etas[m] = secs }
        }

        let originAddress = top[0, 0, 0, 1, 2].string
        let destinationAddress = top[0, 1, 0, 1, 2].string

        var routes: [Route] = []
        for (ri, r) in top[1].array.enumerated() {
            let head = r[0]
            guard let meters = head[2, 0].double, let seconds = head[3, 0].double else { continue }
            let coords = decodeGeometry(top[7, ri])
            guard coords.count > 1 else { continue }

            var steps: [RouteStep] = []
            for group in r[1, 0, 1].array {
                for wrapper in group[1].array {
                    let s = wrapper[0]
                    let text = instructionText(s)
                    guard let loc = s[7, 1, 0].latLng ?? s[7, 2].latLng else { continue }
                    let markup = s[1].string ?? ""
                    var maneuver: Maneuver? = nil
                    if let token = attribute("maneuver", in: markup) {
                        maneuver = Maneuver(google: token, side: attribute("side", in: markup))
                    }
                    if maneuver == nil, let fragmentSide = s[14].array.first(where: { $0[0].int == 14 })?[1, 0].string {
                        maneuver = Maneuver.infer(text: text + " " + fragmentSide, turnAngle: nil)
                    }
                    let nearest = coords.indices.min { coords[$0].distance(to: loc) < coords[$1].distance(to: loc) } ?? 0
                    let m = maneuver ?? Maneuver.infer(text: text, turnAngle: Route.turnAngle(coords, at: nearest))
                    steps.append(RouteStep(id: steps.count,
                                           instruction: text.isEmpty ? fallbackText(m) : text,
                                           distance: s[2, 0].double ?? 0,
                                           duration: s[3, 0].double ?? 0,
                                           maneuver: steps.isEmpty && m == .straight ? .depart : m,
                                           location: loc))
                }
            }
            steps.append(RouteStep(id: steps.count,
                                   instruction: "Arrive at \(destinationName ?? "your destination")",
                                   distance: 0, duration: 0, maneuver: .arrive, location: coords.last!))

            var route = Route(mode: mode, summary: head[1].string ?? "", distance: meters, duration: seconds,
                              coordinates: coords, steps: steps)
            route.typicalDuration = head[10, 0, 0].double
            route.durationRange = head[10, 4, 2].string
            route.label = r[15, 19, 0, 1, 0].string
            route.avoidsHighways = options.avoidHighways
            route.avoidsTolls = options.avoidTolls
            route.originName = originAddress
            route.destinationName = destinationAddress
            routes.append(route)
        }
        if routes.isEmpty && etas.isEmpty { throw RoutingError.noRoute(mode) }
        return DirectionsResult(routes: routes, modeETAs: etas, originAddress: originAddress, destinationAddress: destinationAddress)
    }

    /// Street address for a coordinate, via the waypoint geocoder in Google's directions response.
    static func reverseAddress(_ c: CLLocationCoordinate2D) async -> String? {
        let nudged = CLLocationCoordinate2D(latitude: c.latitude + 0.0004, longitude: c.longitude)
        let url = GoogleClient.url("https://www.google.com/maps/preview/directions", [
            "authuser": "0", "hl": GoogleClient.language, "gl": GoogleClient.region,
            "pb": pb(from: c, to: nudged, mode: .walking, options: .init()),
        ])
        guard let root = try? await GoogleClient.fetch(url) else { return nil }
        return root[0, 0, 0, 0, 1, 2].string
    }

    enum RoutingError: LocalizedError {
        case noRoute(TravelMode)
        var errorDescription: String? {
            switch self {
            case .noRoute(let m): "No \(m.label.lowercased()) route found."
            }
        }
    }

    // MARK: - Decoding helpers

    /// Google ships geometry as delta-encoded E7 integer arrays: [lat deltas], [lng deltas].
    static func decodeGeometry(_ g: J) -> [CLLocationCoordinate2D] {
        let lats = g[0].array.compactMap(\.double), lngs = g[1].array.compactMap(\.double)
        let n = min(lats.count, lngs.count)
        guard n > 0 else { return [] }
        var out: [CLLocationCoordinate2D] = []
        out.reserveCapacity(n)
        var la = 0.0, lo = 0.0
        for i in 0..<n {
            la += lats[i]; lo += lngs[i]
            out.append(.init(latitude: la / 1e7, longitude: lo / 1e7))
        }
        return out
    }

    private static func instructionText(_ s: J) -> String {
        for idx in [14, 15] {
            let frags = s[idx].array
            let parts = frags.compactMap { $0[1, 0].string }
            if !parts.isEmpty, frags.allSatisfy({ $0[0].int != nil }) {
                return parts.joined().trimmingCharacters(in: .whitespaces)
            }
        }
        if let markup = s[1].string, !markup.isEmpty { return stripTags(markup) }
        return ""
    }

    private static func attribute(_ name: String, in markup: String) -> String? {
        guard let r = markup.range(of: "\(name)='") else { return nil }
        let rest = markup[r.upperBound...]
        guard let end = rest.firstIndex(of: "'") else { return nil }
        return String(rest[..<end])
    }

    private static func stripTags(_ s: String) -> String {
        s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespaces)
    }

    private static func fallbackText(_ m: Maneuver) -> String {
        switch m {
        case .depart: "Head out"
        case .turnLeft: "Turn left"
        case .turnRight: "Turn right"
        case .slightLeft: "Slight left"
        case .slightRight: "Slight right"
        case .sharpLeft: "Sharp left"
        case .sharpRight: "Sharp right"
        case .uturnLeft, .uturnRight: "Make a U-turn"
        case .keepLeft: "Keep left"
        case .keepRight: "Keep right"
        case .rampLeft, .rampRight: "Take the exit"
        case .merge: "Merge"
        case .roundaboutLeft, .roundaboutRight: "Enter the roundabout"
        case .ferry: "Take the ferry"
        case .arrive: "Arrive at destination"
        case .straight, .nameChange: "Continue straight"
        }
    }

    // MARK: - Transit (Apple ETA)

    private static func appleTransit(from o: CLLocationCoordinate2D, to d: CLLocationCoordinate2D) async throws -> DirectionsResult {
        let req = MKDirections.Request()
        req.source = MKMapItem(location: CLLocation(latitude: o.latitude, longitude: o.longitude), address: nil)
        req.destination = MKMapItem(location: CLLocation(latitude: d.latitude, longitude: d.longitude), address: nil)
        req.transportType = .transit
        req.departureDate = .now
        let eta = try await MKDirections(request: req).calculateETA()
        var route = Route(mode: .transit, summary: "Public transit", distance: eta.distance,
                          duration: eta.expectedTravelTime, coordinates: [o, d],
                          steps: [RouteStep(id: 0, instruction: "Take public transit", distance: eta.distance,
                                            duration: eta.expectedTravelTime, maneuver: .depart, location: o),
                                  RouteStep(id: 1, instruction: "Arrive at destination", distance: 0, duration: 0,
                                            maneuver: .arrive, location: d)])
        route.label = "Leaves \(Fmt.clock(eta.expectedDepartureDate)) · arrives \(Fmt.clock(eta.expectedArrivalDate))"
        return DirectionsResult(routes: [route], modeETAs: [.transit: eta.expectedTravelTime])
    }
}
