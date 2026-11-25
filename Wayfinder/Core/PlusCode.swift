import CoreLocation

/// Open Location Code ("Plus Code") encoder — the same open standard Google Maps shows on every dropped pin.
enum PlusCode {
    private static let alphabet = Array("23456789CFGHJMPQRVWX")
    private static let encodingBase = 20.0
    private static let latMax = 90.0, lngMax = 180.0

    /// Full 10-digit code, e.g. "849VCWC8+R9".
    static func encode(_ coordinate: CLLocationCoordinate2D, length: Int = 10) -> String {
        var lat = min(max(coordinate.latitude, -latMax), latMax)
        if lat == latMax { lat -= 0.000_001 }
        var lng = coordinate.longitude
        while lng < -lngMax { lng += 360 }
        while lng >= lngMax { lng -= 360 }

        lat += latMax
        lng += lngMax
        var code = ""
        var resolution = encodingBase // 20 degrees for the first pair
        for pair in 0..<(length / 2) {
            let placeValue = pair == 0 ? 20.0 : resolution
            let latDigit = Int(lat / placeValue)
            let lngDigit = Int(lng / placeValue)
            lat -= Double(latDigit) * placeValue
            lng -= Double(lngDigit) * placeValue
            code.append(alphabet[min(max(latDigit, 0), 19)])
            code.append(alphabet[min(max(lngDigit, 0), 19)])
            if code.count == 8 { code.append("+") }
            resolution = placeValue / encodingBase
        }
        if code.count == 8 { code.append("+") }
        return code
    }

    /// Short form as Google displays it next to a locality: drops the first 4 digits ("CWC8+R9").
    static func short(_ coordinate: CLLocationCoordinate2D) -> String {
        String(encode(coordinate).dropFirst(4))
    }
}
