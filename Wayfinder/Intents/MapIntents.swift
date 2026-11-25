import AppIntents
import Foundation

enum NearbyKind: String, AppEnum {
    case restaurants, coffee, gas, atm, pharmacy, parking, hospital, groceries, hotels, evCharging

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Place type"
    static let caseDisplayRepresentations: [NearbyKind: DisplayRepresentation] = [
        .restaurants: "Restaurants", .coffee: "Coffee", .gas: "Petrol stations", .atm: "ATMs",
        .pharmacy: "Pharmacies", .parking: "Parking", .hospital: "Hospitals", .groceries: "Groceries",
        .hotels: "Hotels", .evCharging: "EV charging",
    ]

    var query: String {
        switch self {
        case .restaurants: "restaurants"
        case .coffee: "coffee"
        case .gas: "gas station"
        case .atm: "atm"
        case .pharmacy: "pharmacy"
        case .parking: "parking"
        case .hospital: "hospital"
        case .groceries: "grocery store"
        case .hotels: "hotels"
        case .evCharging: "ev charging station"
        }
    }
}

struct NavigateHomeIntent: AppIntent {
    static let title: LocalizedStringResource = "Navigate Home"
    static let description = IntentDescription("Starts Google Maps directions home on your watch.")
    static let openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult {
        AppModel.shared.pending = .home
        return .result()
    }
}

struct NavigateWorkIntent: AppIntent {
    static let title: LocalizedStringResource = "Navigate to Work"
    static let openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult {
        AppModel.shared.pending = .work
        return .result()
    }
}

struct FindNearbyIntent: AppIntent {
    static let title: LocalizedStringResource = "Find Nearby"
    static let description = IntentDescription("Shows nearby places from Google Maps.")
    static let openAppWhenRun = true
    @Parameter(title: "Type", default: .restaurants) var kind: NearbyKind

    @MainActor func perform() async throws -> some IntentResult {
        AppModel.shared.pending = .nearby(kind.query)
        return .result()
    }
}

struct SaveParkingIntent: AppIntent {
    static let title: LocalizedStringResource = "Save Parking"
    static let description = IntentDescription("Remembers where you parked.")
    static let openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult {
        AppModel.shared.pending = .saveParking
        return .result()
    }
}

struct FindMyCarIntent: AppIntent {
    static let title: LocalizedStringResource = "Find My Car"
    static let openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult {
        AppModel.shared.pending = .parking
        return .result()
    }
}

struct SearchMapsIntent: AppIntent {
    static let title: LocalizedStringResource = "Search Maps"
    static let openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult {
        AppModel.shared.pending = .search
        return .result()
    }
}

struct WayfinderShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: NavigateHomeIntent(), phrases: ["Take me home with \(.applicationName)", "\(.applicationName) home"],
                    shortTitle: "Navigate Home", systemImageName: "house.fill")
        AppShortcut(intent: NavigateWorkIntent(), phrases: ["Take me to work with \(.applicationName)"],
                    shortTitle: "Navigate to Work", systemImageName: "briefcase.fill")
        AppShortcut(intent: FindNearbyIntent(), phrases: ["Find nearby \(\.$kind) in \(.applicationName)", "Find \(\.$kind) with \(.applicationName)"],
                    shortTitle: "Find Nearby", systemImageName: "magnifyingglass")
        AppShortcut(intent: SaveParkingIntent(), phrases: ["Save my parking in \(.applicationName)", "Remember where I parked with \(.applicationName)"],
                    shortTitle: "Save Parking", systemImageName: "parkingsign.circle.fill")
        AppShortcut(intent: FindMyCarIntent(), phrases: ["Where did I park with \(.applicationName)", "Find my car with \(.applicationName)"],
                    shortTitle: "Find My Car", systemImageName: "car.fill")
        AppShortcut(intent: SearchMapsIntent(), phrases: ["Search \(.applicationName)"],
                    shortTitle: "Search", systemImageName: "magnifyingglass")
    }
}
