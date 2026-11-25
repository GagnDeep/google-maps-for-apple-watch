import SwiftUI

enum SettingsKey {
    static let distanceUnit = "distanceUnit"
    static let defaultMode = "defaultMode"
    static let voiceGuidance = "voiceGuidance"
    static let haptics = "haptics"
    static let avoidTolls = "avoidTolls"
    static let avoidHighways = "avoidHighways"
    static let avoidFerries = "avoidFerries"
    static let mapType = "mapType"
    static let showTraffic = "showTraffic"
    static let showTransit = "showTransit"
    static let showBiking = "showBiking"
    static let darkMap = "darkMap"
    static let navNorthUp = "navNorthUp"
    static let showSpeedometer = "showSpeedometer"
    static let askToSaveParking = "askToSaveParking"
    static let saveTimeline = "saveTimeline"
    static let voiceRate = "voiceRate"
    static let voiceMode = "voiceMode"
    static let hapticLevel = "hapticLevel"
    static let activeTrip = "activeTrip"
    static let lastMapCenter = "lastMapCenter"
}

/// Google's base map types (Map / Satellite / Terrain) + the hybrid label overlay.
enum MapType: String, CaseIterable, Identifiable {
    case standard, satellite, hybrid, terrain
    var id: String { rawValue }
    var label: String {
        switch self {
        case .standard: "Default"
        case .satellite: "Satellite"
        case .hybrid: "Hybrid"
        case .terrain: "Terrain"
        }
    }
    var symbol: String {
        switch self {
        case .standard: "map.fill"
        case .satellite: "globe.americas.fill"
        case .hybrid: "square.2.layers.3d.fill"
        case .terrain: "mountain.2.fill"
        }
    }
    /// Google tile `lyrs` code.
    var code: String {
        switch self {
        case .standard: "m"
        case .satellite: "s"
        case .hybrid: "y"
        case .terrain: "p"
        }
    }
}

/// Everything that changes which Google tiles we fetch.
struct TileLayer: Hashable {
    var type: MapType = .standard
    var traffic = false
    var transit = false
    var biking = false
    var dark = false

    static var saved: TileLayer {
        let d = UserDefaults.standard
        return TileLayer(type: MapType(rawValue: d.string(forKey: SettingsKey.mapType) ?? "") ?? .standard,
                         traffic: d.bool(forKey: SettingsKey.showTraffic),
                         transit: d.bool(forKey: SettingsKey.showTransit),
                         biking: d.bool(forKey: SettingsKey.showBiking),
                         dark: d.bool(forKey: SettingsKey.darkMap))
    }

    var cacheKey: String { "\(type.code)\(traffic ? "t" : "")\(transit ? "r" : "")\(biking ? "b" : "")\(dark ? "d" : "")" }

    /// Google's night-mode map style (same palette Google Maps uses after dark).
    static let darkStyle = [
        "s.e:g|p.c:#ff242f3e",
        "s.e:l.t.f|p.c:#ff746855",
        "s.e:l.t.s|p.c:#ff242f3e",
        "s.t:3|s.e:g|p.c:#ff38414e",
        "s.t:3|s.e:g.s|p.c:#ff212a37",
        "s.t:3|s.e:l.t.f|p.c:#ff9ca5b3",
        "s.t:49|s.e:g|p.c:#ff746855",
        "s.t:49|s.e:g.s|p.c:#ff1f2835",
        "s.t:49|s.e:l.t.f|p.c:#fff3d19c",
        "s.t:6|s.e:g|p.c:#ff17263c",
        "s.t:6|s.e:l.t.f|p.c:#ff515c6d",
        "s.t:40|s.e:g|p.c:#ff263c3f",
        "s.t:2|s.e:l.t.f|p.c:#ffd59563",
        "s.t:4|s.e:g|p.c:#ff2f3948",
    ].joined(separator: ",")

    func url(x: Int, y: Int, z: Int) -> URL {
        var lyrs = type.code
        if traffic { lyrs += ",traffic" }
        if transit { lyrs += ",transit" }
        if biking { lyrs += ",bike" }
        var s = "https://mt\((x + y) % 4).google.com/vt/lyrs=\(lyrs)&x=\(x)&y=\(y)&z=\(z)&scale=2&hl=\(GoogleClient.language)&gl=\(GoogleClient.region)"
        if dark && (type == .standard || type == .terrain) {
            s += "&apistyle=" + (TileLayer.darkStyle.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")
        }
        return URL(string: s)!
    }
}

enum AppDefaults {
    static func register() {
        UserDefaults.standard.register(defaults: [
            SettingsKey.distanceUnit: DistanceUnit.automatic.rawValue,
            SettingsKey.defaultMode: TravelMode.driving.rawValue,
            SettingsKey.voiceGuidance: true,
            SettingsKey.haptics: true,
            SettingsKey.avoidTolls: false,
            SettingsKey.avoidHighways: false,
            SettingsKey.avoidFerries: false,
            SettingsKey.mapType: MapType.standard.rawValue,
            SettingsKey.showTraffic: false,
            SettingsKey.showTransit: false,
            SettingsKey.showBiking: false,
            SettingsKey.darkMap: false,
            SettingsKey.navNorthUp: false,
            SettingsKey.showSpeedometer: true,
            SettingsKey.askToSaveParking: true,
            SettingsKey.saveTimeline: true,
            SettingsKey.voiceRate: 0.52,
            SettingsKey.voiceMode: "on",
            SettingsKey.hapticLevel: "all",
        ])
    }

    static var defaultMode: TravelMode {
        TravelMode(rawValue: UserDefaults.standard.string(forKey: SettingsKey.defaultMode) ?? "") ?? .driving
    }
}

enum Brand {
    /// Google Maps route blue.
    static let blue = Color(red: 0.10, green: 0.45, blue: 0.91)
    static let routeOutline = Color(red: 0.05, green: 0.28, blue: 0.63)
    /// Turn-by-turn banner green.
    static let navGreen = Color(red: 0.05, green: 0.40, blue: 0.24)
    static let etaGreen = Color(red: 0.20, green: 0.78, blue: 0.40)
    static let traffic = Color(red: 0.95, green: 0.62, blue: 0.10)
    static let star = Color(red: 0.98, green: 0.74, blue: 0.02)
}
