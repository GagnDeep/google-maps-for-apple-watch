import Foundation
import CoreLocation
import SwiftUI

enum Maneuver: String, Codable, Sendable {
    case depart, straight, turnLeft, turnRight, slightLeft, slightRight, sharpLeft, sharpRight
    case uturnLeft, uturnRight, keepLeft, keepRight, rampLeft, rampRight, merge
    case roundaboutLeft, roundaboutRight, ferry, arrive, nameChange

    var symbol: String {
        switch self {
        case .depart: "location.north.line.fill"
        case .straight, .nameChange: "arrow.up"
        case .turnLeft: "arrow.turn.up.left"
        case .turnRight: "arrow.turn.up.right"
        case .slightLeft, .keepLeft: "arrow.up.left"
        case .slightRight, .keepRight: "arrow.up.right"
        case .sharpLeft: "arrow.down.left"
        case .sharpRight: "arrow.down.right"
        case .uturnLeft: "arrow.uturn.down"
        case .uturnRight: "arrow.uturn.down"
        case .rampLeft: "arrow.up.left"
        case .rampRight: "arrow.up.right"
        case .merge: "arrow.merge"
        case .roundaboutLeft: "arrow.counterclockwise.circle"
        case .roundaboutRight: "arrow.clockwise.circle"
        case .ferry: "ferry.fill"
        case .arrive: "flag.checkered"
        }
    }

    enum Side { case left, right, none }
    var side: Side {
        switch self {
        case .turnLeft, .slightLeft, .sharpLeft, .uturnLeft, .keepLeft, .rampLeft, .roundaboutLeft: .left
        case .turnRight, .slightRight, .sharpRight, .uturnRight, .keepRight, .rampRight, .roundaboutRight: .right
        default: .none
        }
    }

    /// Google's maneuver token (from the step markup) + side.
    init?(google token: String, side: String?) {
        let left = side?.uppercased() == "LEFT", right = side?.uppercased() == "RIGHT"
        switch token.uppercased() {
        case "TURN": self = left ? .turnLeft : right ? .turnRight : .straight
        case "TURN_SLIGHT", "SLIGHT_TURN": self = left ? .slightLeft : .slightRight
        case "TURN_SHARP", "SHARP_TURN": self = left ? .sharpLeft : .sharpRight
        case "UTURN", "U_TURN": self = left ? .uturnLeft : .uturnRight
        case "KEEP", "FORK": self = left ? .keepLeft : .keepRight
        case "RAMP", "EXIT", "OFF_RAMP", "ON_RAMP": self = left ? .rampLeft : .rampRight
        case "MERGE": self = .merge
        case "ROUNDABOUT", "ROTARY", "ROUNDABOUT_EXIT": self = left ? .roundaboutLeft : .roundaboutRight
        case "FERRY": self = .ferry
        case "NAME_CHANGE", "CONTINUE", "STRAIGHT": self = .straight
        case "DEPART", "HEAD": self = .depart
        case "DESTINATION", "ARRIVE": self = .arrive
        default: return nil
        }
    }

    /// Fallback: infer from Google's English instruction text, then from geometry.
    static func infer(text: String, turnAngle: Double?) -> Maneuver {
        let t = text.lowercased()
        let left = t.contains("left"), right = t.contains("right")
        if t.hasPrefix("head") { return .depart }
        if t.contains("u-turn") || t.contains("make a u") { return left ? .uturnLeft : .uturnRight }
        if t.contains("roundabout") || t.contains("rotary") { return left ? .roundaboutLeft : .roundaboutRight }
        if t.contains("ferry") { return .ferry }
        if t.contains("merge") { return .merge }
        if t.contains("exit") || t.contains("ramp") { return left ? .rampLeft : .rampRight }
        if t.hasPrefix("keep") || t.contains("fork") { return left ? .keepLeft : .keepRight }
        if t.contains("slight") { return left ? .slightLeft : .slightRight }
        if t.contains("sharp") { return left ? .sharpLeft : .sharpRight }
        if t.hasPrefix("turn") { return left ? .turnLeft : right ? .turnRight : .straight }
        if t.contains("destination") { return .arrive }
        if let a = turnAngle {
            switch a {
            case ..<(-150): return .uturnLeft
            case -150 ..< -110: return .sharpLeft
            case -110 ..< -35: return .turnLeft
            case -35 ..< -12: return .slightLeft
            case 12 ..< 35: return .slightRight
            case 35 ..< 110: return .turnRight
            case 110 ..< 150: return .sharpRight
            case 150...: return .uturnRight
            default: return .straight
            }
        }
        return left ? .turnLeft : right ? .turnRight : .straight
    }
}

struct RouteStep: Identifiable, Hashable, Sendable {
    let id: Int
    var instruction: String
    var distance: Double
    var duration: Double
    var maneuver: Maneuver
    var location: CLLocationCoordinate2D
    /// Distance from the route start to this maneuver, measured along the polyline.
    var startOffset: Double = 0

    static func == (a: RouteStep, b: RouteStep) -> Bool { a.id == b.id && a.instruction == b.instruction }
    func hash(into h: inout Hasher) { h.combine(id); h.combine(instruction) }

    /// Short spoken/visual form: "Turn right onto Clay St" → keeps Google's wording.
    var spoken: String { instruction }
}

struct Route: Identifiable, Hashable, Sendable {
    let id: UUID
    var mode: TravelMode
    var summary: String
    var distance: Double
    var duration: Double
    var typicalDuration: Double?
    var durationRange: String?
    var label: String?
    var coordinates: [CLLocationCoordinate2D]
    var cumulative: [Double]
    var steps: [RouteStep]
    var avoidsHighways = false
    var avoidsTolls = false
    var originName: String?
    var destinationName: String?

    static func == (a: Route, b: Route) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    /// Delay vs. free-flow traffic, used for Google's green / orange / red ETA coloring.
    var trafficRatio: Double {
        guard let t = typicalDuration, t > 0 else { return 1 }
        return duration / t
    }
    var trafficColor: Color {
        guard mode == .driving else { return Brand.etaGreen }
        switch trafficRatio {
        case ..<1.12: return Brand.etaGreen
        case ..<1.35: return Brand.traffic
        default: return .red
        }
    }
    var trafficNote: String? {
        guard mode == .driving, let t = typicalDuration, duration - t > 90 else { return nil }
        return "+\(Fmt.duration(duration - t)) due to traffic"
    }

    init(mode: TravelMode, summary: String, distance: Double, duration: Double,
         coordinates: [CLLocationCoordinate2D], steps: [RouteStep]) {
        self.id = UUID()
        self.mode = mode
        self.summary = summary
        self.distance = distance
        self.duration = duration
        self.coordinates = coordinates
        var acc: [Double] = [0]
        acc.reserveCapacity(coordinates.count)
        for i in 1..<max(coordinates.count, 1) {
            acc.append(acc[i - 1] + coordinates[i - 1].distance(to: coordinates[i]))
        }
        self.cumulative = acc
        self.steps = steps
        if let polyLength = acc.last, polyLength > 0, distance <= 0 { self.distance = polyLength }
        anchorSteps()
    }

    /// Projects every maneuver onto the polyline so navigation can measure distance-to-turn precisely.
    private mutating func anchorSteps() {
        guard coordinates.count > 1 else { return }
        var searchFrom = 0
        for i in steps.indices {
            var best = searchFrom, bestD = Double.greatestFiniteMagnitude
            let end = min(coordinates.count - 1, searchFrom + 1500)
            for j in searchFrom...end {
                let d = coordinates[j].distance(to: steps[i].location)
                if d < bestD { bestD = d; best = j }
            }
            steps[i].startOffset = cumulative[best]
            searchFrom = best
        }
        if let last = steps.indices.last, steps[last].maneuver == .arrive {
            steps[last].startOffset = cumulative.last ?? distance
        }
    }

    /// Signed turn angle (degrees, + right) at a polyline index.
    static func turnAngle(_ coords: [CLLocationCoordinate2D], at index: Int) -> Double? {
        guard index > 0, index < coords.count - 1 else { return nil }
        var a = index - 1, b = index + 1
        while a > 0, coords[a].distance(to: coords[index]) < 12 { a -= 1 }
        while b < coords.count - 1, coords[b].distance(to: coords[index]) < 12 { b += 1 }
        let inB = coords[a].bearing(to: coords[index]), outB = coords[index].bearing(to: coords[b])
        return (outB - inB).normalizedAngle
    }
}
