import Foundation
import CoreLocation
import MapKit

enum DistanceUnit: String, CaseIterable, Identifiable {
    case automatic, kilometers, miles
    var id: String { rawValue }
    var label: String {
        switch self {
        case .automatic: "Automatic"
        case .kilometers: "Kilometers"
        case .miles: "Miles"
        }
    }

    var usesMetric: Bool {
        switch self {
        case .automatic: Locale.current.measurementSystem == .metric
        case .kilometers: true
        case .miles: false
        }
    }
}

enum Fmt {
    static var unit: DistanceUnit {
        DistanceUnit(rawValue: UserDefaults.standard.string(forKey: SettingsKey.distanceUnit) ?? "") ?? .automatic
    }

    /// "350 m", "1.4 km", "500 ft", "2.3 mi" — rounded the way navigation apps speak them.
    static func distance(_ meters: CLLocationDistance) -> String {
        guard meters.isFinite, meters >= 0 else { return "—" }
        if unit.usesMetric {
            if meters < 1000 {
                if meters < 10 { return "\(Int(meters.rounded())) m" }
                let rounded = meters < 100 ? (meters / 10).rounded() * 10 : (meters / 50).rounded() * 50
                return "\(Int(rounded)) m"
            }
            let km = meters / 1000
            return km < 10 ? String(format: "%.1f km", km) : "\(Int(km.rounded())) km"
        } else {
            let feet = meters * 3.28084
            if feet < 1000 {
                let rounded = feet < 300 ? (feet / 10).rounded() * 10 : (feet / 50).rounded() * 50
                return "\(Int(rounded)) ft"
            }
            let miles = meters / 1609.344
            return miles < 10 ? String(format: "%.1f mi", miles) : "\(Int(miles.rounded())) mi"
        }
    }

    /// Spoken form: "400 meters", "1.5 kilometers", "a quarter mile".
    static func spokenDistance(_ meters: CLLocationDistance) -> String {
        if unit.usesMetric {
            if meters < 1000 {
                let r = meters < 100 ? Int((meters / 10).rounded() * 10) : Int((meters / 50).rounded() * 50)
                return "\(max(r, 10)) meters"
            }
            let km = meters / 1000
            return km < 10 ? String(format: "%.1f kilometers", km) : "\(Int(km.rounded())) kilometers"
        } else {
            let miles = meters / 1609.344
            if miles < 0.19 {
                let feet = Int(((meters * 3.28084) / 50).rounded() * 50)
                return "\(max(feet, 50)) feet"
            }
            if miles < 0.35 { return "a quarter mile" }
            if miles < 0.65 { return "half a mile" }
            if miles < 0.85 { return "three quarters of a mile" }
            return miles < 10 ? String(format: "%.1f miles", miles) : "\(Int(miles.rounded())) miles"
        }
    }

    /// "5 min", "1 hr 20 min", "2 d 4 hr"
    static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "—" }
        let mins = Int((seconds / 60).rounded())
        if mins < 1 { return "<1 min" }
        if mins < 60 { return "\(mins) min" }
        let h = mins / 60, m = mins % 60
        if h >= 24 { return "\(h / 24) d \(h % 24) hr" }
        return m == 0 ? "\(h) hr" : "\(h) hr \(m) min"
    }

    static func compactDuration(_ seconds: TimeInterval) -> String {
        let mins = Int((seconds / 60).rounded())
        if mins < 60 { return "\(max(mins, 1))m" }
        return "\(mins / 60)h\(mins % 60 == 0 ? "" : " \(mins % 60)m")"
    }

    static func clock(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    static func speed(_ mps: CLLocationSpeed) -> (value: String, unit: String) {
        let v = max(mps, 0)
        return unit.usesMetric ? ("\(Int((v * 3.6).rounded()))", "km/h") : ("\(Int((v * 2.23694).rounded()))", "mph")
    }

    static func altitude(_ meters: Double) -> String {
        unit.usesMetric ? "\(Int(meters.rounded())) m" : "\(Int((meters * 3.28084).rounded())) ft"
    }

    static func coordinate(_ c: CLLocationCoordinate2D) -> String {
        String(format: "%.5f, %.5f", c.latitude, c.longitude)
    }

    static func dms(_ c: CLLocationCoordinate2D) -> String {
        func part(_ v: Double, _ pos: String, _ neg: String) -> String {
            let a = abs(v)
            let d = Int(a), mFull = (a - Double(d)) * 60, m = Int(mFull), s = (mFull - Double(m)) * 60
            return String(format: "%d°%02d'%04.1f\"%@", d, m, s, v >= 0 ? pos : neg)
        }
        return "\(part(c.latitude, "N", "S")) \(part(c.longitude, "E", "W"))"
    }

    static func relative(_ date: Date) -> String {
        date.formatted(.relative(presentation: .named))
    }
}

extension CLLocationCoordinate2D {
    func distance(to other: CLLocationCoordinate2D) -> CLLocationDistance {
        MKMapPoint(self).distance(to: MKMapPoint(other))
    }

    /// Initial bearing in degrees (0 = north) from self to other.
    func bearing(to other: CLLocationCoordinate2D) -> Double {
        let lat1 = latitude * .pi / 180, lat2 = other.latitude * .pi / 180
        let dLon = (other.longitude - longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let deg = atan2(y, x) * 180 / .pi
        return (deg + 360).truncatingRemainder(dividingBy: 360)
    }
}

extension Double {
    /// Normalizes an angle difference to -180...180.
    var normalizedAngle: Double {
        var a = truncatingRemainder(dividingBy: 360)
        if a > 180 { a -= 360 }
        if a < -180 { a += 360 }
        return a
    }
}

enum Compass {
    static func cardinal(_ degrees: Double) -> String {
        let dirs = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        let i = Int(((degrees.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) + 22.5) / 45) % 8
        return dirs[i]
    }
}
