import Foundation
import CoreLocation

/// Thin client for Google Maps' public, keyless web endpoints (the same ones google.com/maps uses).
enum GoogleClient {
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

    static var language: String { Locale.current.language.languageCode?.identifier ?? "en" }
    static var region: String { (Locale.current.region?.identifier ?? "US").lowercased() }

    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = ["User-Agent": userAgent, "Accept-Language": Locale.preferredLanguages.first ?? "en"]
        config.timeoutIntervalForRequest = 20
        config.requestCachePolicy = .useProtocolCachePolicy
        config.urlCache = URLCache(memoryCapacity: 4 << 20, diskCapacity: 20 << 20)
        return URLSession(configuration: config)
    }()

    enum Failure: LocalizedError {
        case badResponse(Int), unreadable, offline
        var errorDescription: String? {
            switch self {
            case .badResponse(let code): "Google Maps answered with an error (\(code))."
            case .unreadable: "Couldn't read Google Maps' answer."
            case .offline: "You're offline."
            }
        }
    }

    /// Fetches one of Google's `)]}'`-prefixed JSON responses and returns the parsed tree.
    static func fetch(_ url: URL) async throws -> J {
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(from: url)
        } catch let e as URLError where e.code == .notConnectedToInternet || e.code == .networkConnectionLost {
            throw Failure.offline
        }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw Failure.badResponse(http.statusCode) }
        guard var text = String(data: data, encoding: .utf8) else { throw Failure.unreadable }
        if text.hasPrefix(")]}'") { text = String(text.drop(while: { $0 != "\n" }).dropFirst()) }
        // The search endpoint appends a trailing "/*""*/" marker.
        if let r = text.range(of: "/*\"\"*/", options: .backwards) { text.removeSubrange(r) }
        guard let json = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]) else {
            throw Failure.unreadable
        }
        return J(json)
    }

    static func url(_ base: String, _ query: [String: String]) -> URL {
        var c = URLComponents(string: base)!
        c.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        // Google's protobuf-in-URL ("pb") parameter must keep its "!" separators unescaped.
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "%21", with: "!")
        return c.url!
    }

    /// Viewport block shared by search and directions requests.
    static func viewport(_ center: CLLocationCoordinate2D, span meters: Double) -> String {
        "!1m3!1d\(Int(meters))!2d\(center.longitude)!3d\(center.latitude)"
    }
}

/// Minimal navigator for Google's positional JSON arrays.
struct J: @unchecked Sendable {
    let raw: Any?
    init(_ raw: Any?) { self.raw = raw is NSNull ? nil : raw }

    subscript(_ i: Int) -> J {
        guard let a = raw as? [Any], i >= 0, i < a.count else { return J(nil) }
        return J(a[i])
    }
    subscript(_ path: Int...) -> J { path.reduce(self) { $0[$1] } }

    var array: [J] { (raw as? [Any])?.map(J.init) ?? [] }
    var string: String? { raw as? String }
    var double: Double? { (raw as? NSNumber)?.doubleValue }
    var int: Int? { (raw as? NSNumber)?.intValue }
    var bool: Bool? { (raw as? NSNumber)?.boolValue }
    var isNil: Bool { raw == nil }
    var count: Int { (raw as? [Any])?.count ?? 0 }

    /// `[null, null, lat, lng]` → coordinate.
    var latLng: CLLocationCoordinate2D? {
        guard let lat = self[2].double, let lng = self[3].double else { return nil }
        return .init(latitude: lat, longitude: lng)
    }

    /// Depth-first search for the first string matching a predicate.
    func firstString(where predicate: (String) -> Bool, depth: Int = 0) -> String? {
        if let s = string, predicate(s) { return s }
        guard depth < 14, let a = raw as? [Any] else { return nil }
        for x in a { if let hit = J(x).firstString(where: predicate, depth: depth + 1) { return hit } }
        return nil
    }

    /// Depth-first search for the first `[null,null,lat,lng]` coordinate.
    func firstLatLng(depth: Int = 0) -> CLLocationCoordinate2D? {
        guard let a = raw as? [Any] else { return nil }
        if a.count == 4, a[0] is NSNull, a[1] is NSNull, let c = latLng, abs(c.latitude) <= 90 { return c }
        guard depth < 14 else { return nil }
        for x in a { if let c = J(x).firstLatLng(depth: depth + 1) { return c } }
        return nil
    }
}
