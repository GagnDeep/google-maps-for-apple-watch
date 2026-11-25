import Foundation
import SwiftData
import MapKit
import SwiftUI

enum SavedList: String, CaseIterable, Identifiable, Codable {
    case home, work, favorites, wantToGo, starred, travelPlans

    var id: String { rawValue }
    var title: String {
        switch self {
        case .home: "Home"
        case .work: "Work"
        case .favorites: "Favorites"
        case .wantToGo: "Want to go"
        case .starred: "Starred places"
        case .travelPlans: "Travel plans"
        }
    }
    var symbol: String {
        switch self {
        case .home: "house.fill"
        case .work: "briefcase.fill"
        case .favorites: "heart.fill"
        case .wantToGo: "flag.fill"
        case .starred: "star.fill"
        case .travelPlans: "suitcase.fill"
        }
    }
    var color: Color {
        switch self {
        case .home, .work: .blue
        case .favorites: .pink
        case .wantToGo: .green
        case .starred: .yellow
        case .travelPlans: .teal
        }
    }
    /// Lists that hold a single place.
    var isSingleton: Bool { self == .home || self == .work }
    static var collections: [SavedList] { [.favorites, .wantToGo, .starred, .travelPlans] }
}

@Model
final class SavedPlace {
    var listRaw: String = SavedList.favorites.rawValue
    var placeData: Data = Data()
    var note: String = ""
    var createdAt: Date = Date()

    init(place: Place, list: SavedList, note: String = "") {
        self.listRaw = list.rawValue
        self.placeData = (try? JSONEncoder().encode(place)) ?? Data()
        self.note = note
        self.createdAt = .now
    }

    var list: SavedList { SavedList(rawValue: listRaw) ?? .favorites }
    var place: Place? { try? JSONDecoder().decode(Place.self, from: placeData) }
}

@Model
final class RecentEntry {
    var query: String?
    var placeData: Data?
    var date: Date = Date()

    init(query: String) { self.query = query; self.date = .now }
    init(place: Place) { self.placeData = try? JSONEncoder().encode(place); self.date = .now }

    var place: Place? { placeData.flatMap { try? JSONDecoder().decode(Place.self, from: $0) } }
}

@Model
final class ParkingSpot {
    var latitude: Double = 0
    var longitude: Double = 0
    var address: String?
    var note: String = ""
    var date: Date = Date()
    var meterExpiry: Date?

    init(coordinate: CLLocationCoordinate2D, address: String?) {
        latitude = coordinate.latitude
        longitude = coordinate.longitude
        self.address = address
        date = .now
    }

    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
    var asPlace: Place {
        Place(id: "parking", name: "Parked car", subtitle: address ?? Fmt.coordinate(coordinate),
              fullAddress: address, coordinate: coordinate, categories: ["Parking"])
    }
}

/// Timeline entry — one completed (or ended) trip.
@Model
final class Trip {
    var startedAt: Date = Date()
    var endedAt: Date = Date()
    var modeRaw: String = TravelMode.driving.rawValue
    var destinationData: Data?
    var originName: String = "Your location"
    var distanceTraveled: Double = 0
    var pathData: Data = Data()
    var arrived: Bool = false

    init(startedAt: Date, endedAt: Date, mode: TravelMode, destination: Place?, originName: String,
         distance: Double, path: [CLLocationCoordinate2D], arrived: Bool) {
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.modeRaw = mode.rawValue
        self.destinationData = destination.flatMap { try? JSONEncoder().encode($0) }
        self.originName = originName
        self.distanceTraveled = distance
        self.pathData = Trip.encode(path)
        self.arrived = arrived
    }

    var mode: TravelMode { TravelMode(rawValue: modeRaw) ?? .driving }
    var destination: Place? { destinationData.flatMap { try? JSONDecoder().decode(Place.self, from: $0) } }
    var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }
    var path: [CLLocationCoordinate2D] {
        let pairs = (try? JSONDecoder().decode([[Double]].self, from: pathData)) ?? []
        return pairs.compactMap { $0.count == 2 ? CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) : nil }
    }

    static func encode(_ path: [CLLocationCoordinate2D]) -> Data {
        // Thin the path so the store stays small (keep at most ~600 points).
        let stride = max(1, path.count / 600)
        let thinned = Swift.stride(from: 0, to: path.count, by: stride).map { path[$0] } + (path.last.map { [$0] } ?? [])
        return (try? JSONEncoder().encode(thinned.map { [$0.latitude, $0.longitude] })) ?? Data()
    }
}
