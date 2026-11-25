import SwiftUI
import SwiftData
import Observation
import CoreLocation

enum SearchPurpose: Hashable { case browse, setHome, setWork, addToList(SavedList) }

enum Screen: Hashable {
    case search(SearchPurpose)
    case results(String)
    case place(Place)
    case directions(Place, TravelMode?)
    case steps(Route)
    case menu, saved, timeline, parking, measure, layers, settings, go, explore
    case savedList(SavedList)
    case trip(PersistentIdentifier)
    case compass(Place?)
}

enum DeepLink: Equatable {
    case search, home, work, parking, saveParking, nearby(String), navigate(Place), timeline, go
}

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    var path: [Screen] = []
    /// Places currently shown on the Explore map (search / category results).
    var results: [Place] = []
    var resultsTitle: String?
    /// Which result the map card is showing.
    var selectedResult = 0
    var droppedPin: Place?
    var pending: DeepLink?
    let map: MapController = {
        if let a = UserDefaults.standard.array(forKey: SettingsKey.lastMapCenter) as? [Double], a.count == 3 {
            return MapController(center: .init(latitude: a[0], longitude: a[1]), zoom: a[2])
        }
        return MapController()
    }()

    func saveMapPosition() {
        let v = map.viewport
        UserDefaults.standard.set([v.center.latitude, v.center.longitude, v.zoom], forKey: SettingsKey.lastMapCenter)
    }
    var didCenterOnUser = false

    func open(_ s: Screen) { path.append(s) }

    func show(results places: [Place], title: String) {
        results = places
        resultsTitle = title
        selectedResult = 0
        path.removeAll()
        let coords = places.map(\.coordinate) + (LocationService.shared.coordinate.map { [$0] } ?? [])
        map.follow = .none
        map.fit(Array(coords.prefix(12)), padding: 30, maxZoom: 16, animated: false)
        // Make room for the result card at the bottom.
        let framed = map.viewport.panned(by: CGSize(width: 0, height: map.size.height * 0.08))
        map.set(Viewport(center: map.viewport.center, zoom: map.viewport.zoom - 0.35, heading: 0))
        map.fly(to: Viewport(center: framed.center, zoom: map.viewport.zoom, heading: 0))
    }

    /// Steps the map card to another result and flies the map there.
    func selectResult(_ index: Int) {
        guard !results.isEmpty else { return }
        selectedResult = (index + results.count) % results.count
        map.follow = .none
        // Keep the pin in the upper half, clear of the result card.
        let v = Viewport(center: results[selectedResult].coordinate, zoom: max(map.zoom, 15), heading: map.viewport.heading)
            .panned(by: CGSize(width: 0, height: map.size.height * 0.1))
        map.fly(to: v)
        Guidance.shared.tap(.select)
    }

    func clearResults() {
        selectedResult = 0
        results = []
        resultsTitle = nil
        droppedPin = nil
    }

    func handle(url: URL) {
        guard url.scheme == "wayfinder" else { return }
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func v(_ k: String) -> String? { q.first { $0.name == k }?.value }
        switch url.host() {
        case "search": pending = .search
        case "home": pending = .home
        case "work": pending = .work
        case "parking": pending = .parking
        case "saveparking": pending = .saveParking
        case "timeline": pending = .timeline
        case "go": pending = .go
        case "nearby": pending = .nearby(v("q") ?? "Restaurants")
        case "navigate":
            if let lat = v("lat").flatMap(Double.init), let lng = v("lng").flatMap(Double.init) {
                pending = .navigate(Place(name: v("name") ?? "Destination", coordinate: .init(latitude: lat, longitude: lng)))
            }
        default: break
        }
    }
}

/// Quick category chips — the same set Google Maps shows under the search bar.
struct QuickCategory: Identifiable, Hashable {
    let id: String
    let title: String
    let query: String
    let symbol: String
    let color: Color

    static let all: [QuickCategory] = [
        .init(id: "restaurants", title: "Restaurants", query: "restaurants", symbol: "fork.knife", color: .orange),
        .init(id: "coffee", title: "Coffee", query: "coffee", symbol: "cup.and.saucer.fill", color: .orange),
        .init(id: "gas", title: "Petrol", query: "gas station", symbol: "fuelpump.fill", color: .blue),
        .init(id: "groceries", title: "Groceries", query: "grocery store", symbol: "cart.fill", color: .blue),
        .init(id: "hotels", title: "Hotels", query: "hotels", symbol: "bed.double.fill", color: .pink),
        .init(id: "atm", title: "ATMs", query: "atm", symbol: "banknote.fill", color: .teal),
        .init(id: "pharmacy", title: "Pharmacies", query: "pharmacy", symbol: "pills.fill", color: .red),
        .init(id: "hospital", title: "Hospitals", query: "hospital", symbol: "cross.case.fill", color: .red),
        .init(id: "parking", title: "Parking", query: "parking", symbol: "parkingsign", color: .blue),
        .init(id: "ev", title: "EV charging", query: "ev charging station", symbol: "bolt.car.fill", color: .green),
        .init(id: "parks", title: "Parks", query: "parks", symbol: "tree.fill", color: .green),
        .init(id: "shopping", title: "Shopping", query: "shopping", symbol: "bag.fill", color: .blue),
        .init(id: "attractions", title: "Things to do", query: "tourist attractions", symbol: "camera.fill", color: .teal),
        .init(id: "transit", title: "Transit", query: "bus station", symbol: "bus.fill", color: .indigo),
    ]
}
