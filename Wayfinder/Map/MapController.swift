import SwiftUI
import CoreLocation
import Observation

/// Web-Mercator math for Google's 256-pt tile pyramid.
enum Mercator {
    static let tileSize = 256.0
    static let minZoom = 2.0, maxZoom = 20.5

    static func world(_ c: CLLocationCoordinate2D, zoom: Double) -> CGPoint {
        let scale = tileSize * pow(2, zoom)
        let x = (c.longitude + 180) / 360 * scale
        let s = min(max(sin(c.latitude * .pi / 180), -0.9999), 0.9999)
        let y = (0.5 - log((1 + s) / (1 - s)) / (4 * .pi)) * scale
        return CGPoint(x: x, y: y)
    }

    static func coordinate(_ p: CGPoint, zoom: Double) -> CLLocationCoordinate2D {
        let scale = tileSize * pow(2, zoom)
        let lon = p.x / scale * 360 - 180
        let n = .pi - 2 * .pi * p.y / scale
        let lat = 180 / .pi * atan(0.5 * (exp(n) - exp(-n)))
        return .init(latitude: lat, longitude: lon)
    }

    static func metersPerPoint(latitude: Double, zoom: Double) -> Double {
        156_543.033_92 * cos(latitude * .pi / 180) / pow(2, zoom)
    }
}

struct Viewport: Equatable {
    var center: CLLocationCoordinate2D
    var zoom: Double
    /// Map rotation: the compass bearing that points "up" on screen.
    var heading: Double = 0

    static func == (a: Viewport, b: Viewport) -> Bool {
        a.center.latitude == b.center.latitude && a.center.longitude == b.center.longitude && a.zoom == b.zoom && a.heading == b.heading
    }

    /// Screen position of a coordinate for a view of `size`.
    func point(for c: CLLocationCoordinate2D, in size: CGSize, anchor: CGPoint? = nil) -> CGPoint {
        let w = Mercator.world(c, zoom: zoom), cw = Mercator.world(center, zoom: zoom)
        var dx = w.x - cw.x
        let worldWidth = Mercator.tileSize * pow(2, zoom)
        if dx > worldWidth / 2 { dx -= worldWidth } else if dx < -worldWidth / 2 { dx += worldWidth }
        let dy = w.y - cw.y
        let r = -heading * .pi / 180
        let rx = dx * cos(r) - dy * sin(r), ry = dx * sin(r) + dy * cos(r)
        let a = anchor ?? CGPoint(x: size.width / 2, y: size.height / 2)
        return CGPoint(x: a.x + rx, y: a.y + ry)
    }

    func coordinate(at p: CGPoint, in size: CGSize) -> CLLocationCoordinate2D {
        let dx = p.x - size.width / 2, dy = p.y - size.height / 2
        let r = heading * .pi / 180
        let wx = dx * cos(r) - dy * sin(r), wy = dx * sin(r) + dy * cos(r)
        let cw = Mercator.world(center, zoom: zoom)
        return Mercator.coordinate(CGPoint(x: cw.x + wx, y: cw.y + wy), zoom: zoom)
    }

    /// Moves the center by a screen-space translation.
    func panned(by t: CGSize) -> Viewport {
        let r = heading * .pi / 180
        let wx = t.width * cos(r) - t.height * sin(r), wy = t.width * sin(r) + t.height * cos(r)
        let cw = Mercator.world(center, zoom: zoom)
        var v = self
        v.center = Mercator.coordinate(CGPoint(x: cw.x - wx, y: cw.y - wy), zoom: zoom)
        v.center.latitude = min(max(v.center.latitude, -85), 85)
        return v
    }
}

enum FollowMode: Equatable { case none, follow, followHeading }

/// Owns the camera for a GoogleMapView: smooth fly-to animations, follow modes and fitting.
@MainActor
@Observable
final class MapController {
    var viewport: Viewport
    var follow: FollowMode = .none
    var size: CGSize = CGSize(width: 200, height: 240)
    /// Vertical position (0…1) of the user puck while navigating (Google keeps it in the lower third).
    var userAnchorY: Double = 0.5
    @ObservationIgnored private var animation: Task<Void, Never>?

    init(center: CLLocationCoordinate2D = .init(latitude: 37.7880, longitude: -122.4075), zoom: Double = 15) {
        viewport = Viewport(center: center, zoom: zoom)
    }

    var zoom: Double {
        get { viewport.zoom }
        set { viewport.zoom = min(max(newValue, Mercator.minZoom), Mercator.maxZoom) }
    }

    func stopAnimation() { animation?.cancel(); animation = nil }

    func set(_ v: Viewport) { stopAnimation(); viewport = v }

    /// Smoothly animates to a viewport (ease-in-out; flies out and back in for long hops like Google's camera).
    func fly(to target: Viewport, duration: Double = 0.55) {
        stopAnimation()
        let start = viewport
        let startW = Mercator.world(start.center, zoom: start.zoom)
        let endW = Mercator.world(target.center, zoom: start.zoom)
        let hop = hypot(endW.x - startW.x, endW.y - startW.y)
        let dur = hop > 2000 ? max(duration, 1.0) : duration
        let dHeading = (target.heading - start.heading).normalizedAngle
        animation = Task { @MainActor [weak self] in
            let t0 = Date()
            while !Task.isCancelled {
                let t = min(1, Date().timeIntervalSince(t0) / dur)
                let e = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
                let lat = start.center.latitude + (target.center.latitude - start.center.latitude) * e
                let lon = start.center.longitude + (target.center.longitude - start.center.longitude) * e
                var z = start.zoom + (target.zoom - start.zoom) * e
                if hop > 2000 { z -= sin(e * .pi) * min(3, log2(hop / 400)) }
                var h = start.heading + dHeading * e
                h = (h + 360).truncatingRemainder(dividingBy: 360)
                self?.viewport = Viewport(center: .init(latitude: lat, longitude: lon), zoom: z, heading: h)
                if t >= 1 { break }
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    func fly(to c: CLLocationCoordinate2D, zoom: Double? = nil) {
        fly(to: Viewport(center: c, zoom: zoom ?? max(viewport.zoom, 15), heading: viewport.heading))
    }

    /// Fits a set of coordinates on screen with padding (points).
    func fit(_ coords: [CLLocationCoordinate2D], padding: Double = 26, maxZoom: Double = 17, animated: Bool = true) {
        guard let first = coords.first else { return }
        guard coords.count > 1 else { animated ? fly(to: first, zoom: maxZoom) : set(Viewport(center: first, zoom: maxZoom)); return }
        let pts = coords.map { Mercator.world($0, zoom: 0) }
        let minX = pts.map(\.x).min()!, maxX = pts.map(\.x).max()!
        let minY = pts.map(\.y).min()!, maxY = pts.map(\.y).max()!
        let w = max(maxX - minX, 1e-9), h = max(maxY - minY, 1e-9)
        let availW = max(size.width - padding * 2, 40), availH = max(size.height - padding * 2, 40)
        let z = min(maxZoom, log2(min(availW / w, availH / h)))
        let center = Mercator.coordinate(CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2), zoom: 0)
        let v = Viewport(center: center, zoom: max(Mercator.minZoom, z), heading: 0)
        animated ? fly(to: v) : set(v)
    }

    func resetNorth() {
        var v = viewport; v.heading = 0
        fly(to: v, duration: 0.35)
    }
}
