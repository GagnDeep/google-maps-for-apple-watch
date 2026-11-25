import MapKit
import SwiftUI

enum TravelMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case driving, twoWheeler, transit, walking, cycling

    var id: String { rawValue }
    var label: String {
        switch self {
        case .driving: "Drive"
        case .twoWheeler: "Two-wheeler"
        case .walking: "Walk"
        case .transit: "Transit"
        case .cycling: "Cycle"
        }
    }
    var symbol: String {
        switch self {
        case .driving: "car.fill"
        case .twoWheeler: "scooter"
        case .walking: "figure.walk"
        case .transit: "tram.fill"
        case .cycling: "bicycle"
        }
    }
    var isVehicle: Bool { self == .driving || self == .twoWheeler }

    /// Distance from a maneuver at which we give the early "prepare" prompt.
    var prepareDistance: CLLocationDistance {
        switch self {
        case .driving: 800
        case .twoWheeler: 500
        case .cycling: 250
        case .walking, .transit: 120
        }
    }
    /// Distance at which we give the "turn now" prompt + haptic.
    var nowDistance: CLLocationDistance {
        switch self {
        case .driving: 70
        case .twoWheeler: 50
        case .cycling: 30
        case .walking, .transit: 15
        }
    }
    var offRouteThreshold: CLLocationDistance {
        switch self {
        case .driving, .twoWheeler: 60
        case .cycling: 45
        case .walking, .transit: 35
        }
    }
    var arrivalRadius: CLLocationDistance {
        switch self {
        case .driving, .twoWheeler: 45
        case .cycling: 30
        case .walking, .transit: 20
        }
    }
    /// Map zoom used while navigating.
    var navZoom: Double {
        switch self {
        case .driving: 16.6
        case .twoWheeler: 17.0
        case .cycling: 17.3
        case .walking, .transit: 18.0
        }
    }
    var activityType: CLActivityType {
        switch self {
        case .driving, .twoWheeler: .automotiveNavigation
        case .cycling, .walking: .fitness
        case .transit: .otherNavigation
        }
    }
}
