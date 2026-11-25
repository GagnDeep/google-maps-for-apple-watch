import Foundation
import CoreLocation

struct Suggestion: Identifiable, Hashable, Sendable {
    var id: String { (placeID ?? "") + title + subtitle }
    var title: String
    var subtitle: String
    var coordinate: CLLocationCoordinate2D?
    var placeID: String?
    var isQuery: Bool { coordinate == nil }

    static func == (a: Suggestion, b: Suggestion) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

/// Google Maps search, autocomplete and "what's here" — all keyless.
enum GoogleSearch {
    /// Text search ("coffee", "petrol pump", "Golden Temple") biased to a viewport.
    static func search(_ query: String, near center: CLLocationCoordinate2D, spanMeters: Double = 8000) async throws -> [Place] {
        let pb = "!4m8" + GoogleClient.viewport(center, span: spanMeters) + "!3m2!1i400!2i400!4f13.1!7i20!10b1"
        let url = GoogleClient.url("https://www.google.com/search", [
            "tbm": "map", "authuser": "0", "hl": GoogleClient.language, "gl": GoogleClient.region,
            "q": query, "pb": pb,
        ])
        let root = try await GoogleClient.fetch(url)
        var places: [Place] = []
        for item in root[0, 1].array {
            if let p = parsePlace(item[14]) { places.append(p) }
        }
        return places
    }

    /// Autocomplete suggestions as the user types (Google's Maps suggest service).
    static func suggest(_ query: String, near center: CLLocationCoordinate2D) async throws -> [Suggestion] {
        let pb = "!2i7!4m12" + GoogleClient.viewport(center, span: 6000) + "!2m3!1f0!2f0!3f0!3m2!1i400!2i400!4f13.1!7i20!10b1"
        let url = GoogleClient.url("https://www.google.com/s", [
            "tbm": "map", "gs_ri": "maps", "suggest": "p", "authuser": "0",
            "hl": GoogleClient.language, "gl": GoogleClient.region, "q": query, "pb": pb,
        ])
        let root = try await GoogleClient.fetch(url)
        var out: [Suggestion] = []
        for item in root[0, 1].array {
            let s = item[22]
            guard let full = s[0, 0].string, !full.isEmpty else { continue }
            let parts = full.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            let pid = s.firstString { $0.hasPrefix("ChIJ") || $0.hasPrefix("EhI") || $0.hasPrefix("GhIJ") }
            out.append(Suggestion(title: parts.first ?? full,
                                  subtitle: parts.count > 1 ? parts[1] : "",
                                  coordinate: s.firstLatLng(),
                                  placeID: pid?.hasPrefix("ChIJ") == true ? pid : nil))
        }
        return out
    }

    /// Resolves a suggestion into a full place record (ratings, hours, reviews…).
    static func resolve(_ suggestion: Suggestion, near center: CLLocationCoordinate2D) async throws -> Place? {
        let query = suggestion.subtitle.isEmpty ? suggestion.title : "\(suggestion.title), \(suggestion.subtitle)"
        let results = try await search(query, near: suggestion.coordinate ?? center, spanMeters: 1500)
        if let pid = suggestion.placeID, let exact = results.first(where: { $0.placeID == pid }) { return exact }
        if let c = suggestion.coordinate {
            return results.min { $0.coordinate.distance(to: c) < $1.coordinate.distance(to: c) }
        }
        return results.first
    }

    /// Refreshes a saved place with Google's latest details (open now, rating, hours).
    static func refresh(_ place: Place) async -> Place? {
        guard !place.isDroppedPin else { return nil }
        let q = place.fullAddress.map { "\(place.name), \($0)" } ?? place.name
        guard let results = try? await search(q, near: place.coordinate, spanMeters: 1200) else { return nil }
        if let pid = place.placeID, let hit = results.first(where: { $0.placeID == pid }) { return hit }
        return results.first { $0.coordinate.distance(to: place.coordinate) < 150 && $0.name == place.name }
    }

    /// Google's "What's here?" for a dropped pin: plus code + locality, and the nearest address when available.
    static func whatsHere(_ c: CLLocationCoordinate2D) async -> Place {
        let q = String(format: "%.6f,%.6f", c.latitude, c.longitude)
        var pin = Place.droppedPin(at: c)
        if let results = try? await search(q, near: c, spanMeters: 600), let hit = results.first {
            pin.plusCodeLocality = hit.plusCodeLocality
            if let a = hit.fullAddress, !a.isEmpty { pin.fullAddress = a }
            if let loc = hit.plusCodeLocality { pin.subtitle = loc }
        }
        // Use Google's directions geocoder for a street address (it reverse-geocodes waypoints).
        if pin.fullAddress == nil, let addr = await GoogleDirections.reverseAddress(c) {
            pin.fullAddress = addr
            pin.subtitle = addr
        }
        return pin
    }

    // MARK: - Parsing Google's place record

    static func parsePlace(_ p: J) -> Place? {
        guard let name = p[11].string, let lat = p[9, 2].double, let lng = p[9, 3].double else { return nil }
        let coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lng)
        let address = p[39].string ?? p[2].array.compactMap(\.string).joined(separator: ", ")
        var place = Place(id: p[78].string ?? p[10].string, name: name,
                          subtitle: address, fullAddress: address.isEmpty ? nil : address,
                          coordinate: coordinate,
                          phone: p[178, 0, 0].string,
                          url: p[7, 0].string.flatMap(URL.init(string:)),
                          categories: p[13].array.compactMap(\.string))
        place.rating = p[4, 7].double
        place.reviewCount = p[4, 8].int
        place.priceLevel = p[4, 2].string ?? p[4, 10].string
        place.placeID = p[78].string
        place.featureID = p[10].string
        place.openStatus = p[203, 1, 4, 0].string
        place.summary = p[32, 1, 1].string ?? p[32, 0, 1].string ?? p[88, 0].string
        place.plusCodeLocality = p[183, 2, 2, 0].string
        place.hours = p[203, 0].array.compactMap { day in
            guard let name = day[0].string else { return nil }
            let ranges = day[3].array.compactMap { $0[0].string }
            return OpeningDay(day: name,
                              hours: ranges.isEmpty ? "Closed" : ranges.joined(separator: ", ").replacingOccurrences(of: "\u{202F}", with: " "),
                              note: day[6, 0].string,
                              isToday: false)
        }
        if !place.hours.isEmpty { place.hours[0].isToday = true } // Google lists today first.
        place.reviews = p[31, 1].array.compactMap { r in
            r[1].string?.trimmingCharacters(in: CharacterSet(charactersIn: "\"“” "))
        }
        if address.isEmpty, let loc = place.plusCodeLocality { place.subtitle = loc }
        if name.contains("°") && name.contains("\"") { // coordinate-only hit (what's here)
            place.isDroppedPin = true
            place.name = "Dropped pin"
        }
        return place
    }
}
