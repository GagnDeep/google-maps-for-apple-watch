import Foundation
import MapKit
import SwiftUI

struct OpeningDay: Hashable, Codable, Sendable {
    var day: String
    var hours: String
    var note: String?
    var isToday: Bool
}

/// A Google Maps place, decoded from Google's own keyless search responses.
struct Place: Identifiable, Hashable, Codable, Sendable {
    var id: String
    var name: String
    var subtitle: String
    var fullAddress: String?
    var latitude: Double
    var longitude: Double
    var phone: String?
    var url: URL?
    var categories: [String] = []
    var rating: Double?
    var reviewCount: Int?
    var priceLevel: String?
    var openStatus: String?
    var hours: [OpeningDay] = []
    var summary: String?
    var reviews: [String] = []
    var placeID: String?
    var featureID: String?
    var plusCodeLocality: String?
    var isDroppedPin: Bool = false

    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
    var location: CLLocation { .init(latitude: latitude, longitude: longitude) }
    var category: PlaceCategory { PlaceCategory(categories: categories, isPin: isDroppedPin) }
    var primaryCategory: String? { categories.first }

    /// Open / closed state derived from Google's status line ("Open · Closes 6 PM", "Closed · Opens 10 AM").
    var isOpenNow: Bool? {
        guard let s = openStatus?.lowercased() else { return nil }
        if s.hasPrefix("open") { return true }
        if s.hasPrefix("closed") || s.contains("permanently") || s.contains("temporarily") { return false }
        if s.hasPrefix("closes soon") { return true }
        if s.hasPrefix("opens soon") { return false }
        return nil
    }

    init(id: String? = nil, name: String, subtitle: String = "", fullAddress: String? = nil,
         coordinate: CLLocationCoordinate2D, phone: String? = nil, url: URL? = nil,
         categories: [String] = [], isDroppedPin: Bool = false) {
        self.id = id ?? String(format: "%.6f,%.6f", coordinate.latitude, coordinate.longitude)
        self.name = name
        self.subtitle = subtitle
        self.fullAddress = fullAddress
        self.latitude = coordinate.latitude
        self.longitude = coordinate.longitude
        self.phone = phone
        self.url = url
        self.categories = categories
        self.isDroppedPin = isDroppedPin
    }

    func distance(from location: CLLocation?) -> CLLocationDistance? {
        guard let location else { return nil }
        return location.distance(from: self.location)
    }

    var plusCode: String { PlusCode.encode(coordinate) }

    /// Universal Google Maps link — opens the place in Google Maps on any phone or computer.
    var shareURL: URL {
        var c = URLComponents(string: "https://www.google.com/maps/search/")!
        var items = [URLQueryItem(name: "api", value: "1"),
                     URLQueryItem(name: "query", value: isDroppedPin ? "\(latitude),\(longitude)" : "\(name) \(fullAddress ?? subtitle)")]
        if let placeID { items.append(.init(name: "query_place_id", value: placeID)) }
        c.queryItems = items
        return c.url!
    }

    var directionsShareURL: URL {
        URL(string: "https://www.google.com/maps/dir/?api=1&destination=\(latitude),\(longitude)")!
    }

    /// MapKit item, used only for Apple's transit ETA (Google transit needs a signed-in web session).
    func mapItem() -> MKMapItem {
        let item = MKMapItem(location: location, address: fullAddress.flatMap { MKAddress(fullAddress: $0, shortAddress: subtitle) })
        item.name = name
        return item
    }

    static func droppedPin(at coordinate: CLLocationCoordinate2D, address: String? = nil) -> Place {
        var p = Place(name: "Dropped pin", subtitle: address ?? Fmt.coordinate(coordinate), fullAddress: address,
                      coordinate: coordinate, isDroppedPin: true)
        p.plusCodeLocality = address
        return p
    }
}

/// Icon + color for a place, keyed off Google's category names (the same color families Google uses for pins).
struct PlaceCategory: Hashable {
    let symbol: String
    let color: Color

    init(categories: [String], isPin: Bool = false) {
        if isPin { self.init(symbol: "mappin", color: .red); return }
        let c = categories.joined(separator: " ").lowercased()
        func has(_ words: String...) -> Bool { words.contains { c.contains($0) } }
        if has("coffee", "cafe", "café", "tea house") { self.init(symbol: "cup.and.saucer.fill", color: .orange) }
        else if has("bakery", "dessert", "ice cream", "sweet") { self.init(symbol: "birthday.cake.fill", color: .orange) }
        else if has("bar", "pub", "brewery", "winery", "night club", "lounge") { self.init(symbol: "wineglass.fill", color: .orange) }
        else if has("restaurant", "food", "pizza", "burger", "dhaba", "diner", "takeaway", "meal", "sushi", "grill") { self.init(symbol: "fork.knife", color: .orange) }
        else if has("gas station", "petrol", "fuel") { self.init(symbol: "fuelpump.fill", color: .blue) }
        else if has("charging", "ev ") { self.init(symbol: "bolt.car.fill", color: .green) }
        else if has("parking") { self.init(symbol: "parkingsign", color: .blue) }
        else if has("hotel", "motel", "inn", "resort", "lodging", "hostel", "guest house") { self.init(symbol: "bed.double.fill", color: .pink) }
        else if has("hospital", "clinic", "doctor", "medical", "emergency") { self.init(symbol: "cross.case.fill", color: .red) }
        else if has("pharmacy", "chemist", "drugstore") { self.init(symbol: "pills.fill", color: .red) }
        else if has("atm", "bank") { self.init(symbol: "banknote.fill", color: .teal) }
        else if has("grocery", "supermarket", "market") { self.init(symbol: "cart.fill", color: .blue) }
        else if has("store", "shop", "mall", "boutique", "outlet") { self.init(symbol: "bag.fill", color: .blue) }
        else if has("park", "garden", "trail", "nature", "hiking", "campground") { self.init(symbol: "tree.fill", color: .green) }
        else if has("beach", "lake") { self.init(symbol: "beach.umbrella.fill", color: .cyan) }
        else if has("museum", "gallery", "landmark", "monument", "historical", "tourist", "temple", "gurudwara", "church", "mosque", "place of worship") { self.init(symbol: "building.columns.fill", color: .teal) }
        else if has("cinema", "movie", "theater", "theatre") { self.init(symbol: "theatermasks.fill", color: .teal) }
        else if has("station", "bus", "metro", "subway", "train", "transit") { self.init(symbol: "tram.fill", color: .indigo) }
        else if has("airport") { self.init(symbol: "airplane", color: .indigo) }
        else if has("gym", "fitness", "yoga") { self.init(symbol: "dumbbell.fill", color: .teal) }
        else if has("school", "college", "university", "academy", "institute") { self.init(symbol: "graduationcap.fill", color: .brown) }
        else if has("police") { self.init(symbol: "shield.fill", color: .gray) }
        else if has("post office", "courier") { self.init(symbol: "envelope.fill", color: .gray) }
        else if has("salon", "spa", "barber", "beauty") { self.init(symbol: "scissors", color: .pink) }
        else if has("car ", "auto", "mechanic", "tire", "repair") { self.init(symbol: "car.fill", color: .blue) }
        else { self.init(symbol: "mappin", color: .red) }
    }

    private init(symbol: String, color: Color) {
        self.symbol = symbol; self.color = color
    }
}
