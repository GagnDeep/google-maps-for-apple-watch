import SwiftUI
import CoreLocation
import WatchKit

struct MapPin: Identifiable, Equatable {
    enum Style: Equatable {
        case place(symbol: String, color: Color)
        case selected(symbol: String, color: Color)
        case dot(Color)
        case home, work, parking, start, end, dropped
        case saved(symbol: String, color: Color)
        case measure(Int)
    }
    let id: String
    var coordinate: CLLocationCoordinate2D
    var style: Style
    var payload: Place?

    static func == (a: MapPin, b: MapPin) -> Bool {
        a.id == b.id && a.style == b.style && a.coordinate.latitude == b.coordinate.latitude && a.coordinate.longitude == b.coordinate.longitude
    }
}

struct MapLine: Identifiable, Equatable {
    let id: String
    var coordinates: [CLLocationCoordinate2D]
    var color: Color = Brand.blue
    var outline: Color? = Brand.routeOutline
    var width: Double = 5
    var dashed = false
    /// Meters of the line already travelled (drawn grey, like Google's navigation trail).
    var travelledMeters: Double = 0
    var cumulative: [Double]? = nil

    static func == (a: MapLine, b: MapLine) -> Bool {
        a.id == b.id && a.coordinates.count == b.coordinates.count && a.color == b.color
            && a.travelledMeters == b.travelledMeters && a.width == b.width
    }
}

struct UserPuck: Equatable {
    var coordinate: CLLocationCoordinate2D
    var heading: Double?
    var accuracy: Double
    var navigation = false

    static func == (a: UserPuck, b: UserPuck) -> Bool {
        a.coordinate.latitude == b.coordinate.latitude && a.coordinate.longitude == b.coordinate.longitude
            && a.heading == b.heading && a.accuracy == b.accuracy && a.navigation == b.navigation
    }
}

/// A Google Maps raster map for watchOS: Google's own tiles, drawn with Canvas, panned by touch,
/// zoomed with the Digital Crown (or double-tap), rotatable for heading-up navigation.
struct GoogleMapView: View {
    @Bindable var controller: MapController
    var layer: TileLayer
    var pins: [MapPin] = []
    var lines: [MapLine] = []
    var puck: UserPuck?
    var interactive = true
    var crownZoom = true
    var showsAttribution = true
    var onTapPin: ((MapPin) -> Void)? = nil
    var onLongPress: ((CLLocationCoordinate2D) -> Void)? = nil
    var onUserPan: (() -> Void)? = nil

    @State private var store = TileStore.shared
    @State private var dragOrigin: Viewport?
    @State private var moved = false
    @State private var longPressFired = false
    @State private var longPressTask: Task<Void, Never>?
    @State private var lastTap: (Date, CGPoint)?

    var body: some View {
        GeometryReader { geo in
            let _ = store.revision
            let viewport = controller.viewport
            Canvas(rendersAsynchronously: false) { ctx, size in
                drawTiles(&ctx, size: size, viewport: viewport)
                drawLines(&ctx, size: size, viewport: viewport)
                if let puck { drawPuck(&ctx, puck, size: size, viewport: viewport) }
                drawPins(&ctx, size: size, viewport: viewport)
            }
            .background(layer.dark ? Color(red: 0.14, green: 0.18, blue: 0.24) : Color(red: 0.90, green: 0.91, blue: 0.92))
            .overlay(alignment: .bottomLeading) {
                if showsAttribution {
                    Text("Google")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(layer.type == .standard && !layer.dark ? Color.black.opacity(0.55) : .white.opacity(0.85))
                        .padding(.leading, 6).padding(.bottom, 3)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .gesture(interactive ? dragGesture(size: geo.size) : nil)
            .onAppear {
                controller.size = geo.size
                requestTiles(size: geo.size)
            }
            .onChange(of: geo.size) { _, s in controller.size = s; requestTiles(size: s) }
            .onChange(of: controller.viewport) { _, _ in requestTiles(size: geo.size) }
            .onChange(of: layer) { _, _ in requestTiles(size: geo.size) }
            // Re-check after the cache changes (memory purge on wrist-down, LRU eviction by another map),
            // so a map that isn't moving — like navigation while stopped — never stays blank.
            .onChange(of: store.revision) { _, _ in requestTiles(size: geo.size) }
        }
        .modifier(CrownZoom(controller: controller, enabled: crownZoom && interactive))
        .accessibilityElement()
        .accessibilityLabel("Google map")
        .accessibilityHint(interactive ? "Drag to pan, turn the Digital Crown to zoom, touch and hold to drop a pin" : "")
    }

    // MARK: - Tiles

    private func tileZoom(_ zoom: Double) -> Int { Int(min(max(zoom.rounded(), 2), 20)) }

    private func visibleTiles(size: CGSize, viewport v: Viewport) -> [TileKey] {
        let tz = tileZoom(v.zoom)
        let scale = pow(2, v.zoom - Double(tz))
        let cw = Mercator.world(v.center, zoom: Double(tz))
        let radius = hypot(size.width, size.height) / 2 / scale + 8
        let n = 1 << tz
        let minX = Int(floor((cw.x - radius) / 256)), maxX = Int(floor((cw.x + radius) / 256))
        let minY = max(0, Int(floor((cw.y - radius) / 256))), maxY = min(n - 1, Int(floor((cw.y + radius) / 256)))
        guard minY <= maxY else { return [] }
        var keys: [(TileKey, Double)] = []
        for ty in minY...maxY {
            for tx in minX...maxX {
                let wx = ((tx % n) + n) % n
                let d = hypot(Double(tx) * 256 + 128 - cw.x, Double(ty) * 256 + 128 - cw.y)
                keys.append((TileKey(x: wx, y: ty, z: tz, layer: layer.cacheKey), d))
            }
        }
        return keys.sorted { $0.1 < $1.1 }.map(\.0)
    }

    private func requestTiles(size: CGSize) {
        guard size.width > 1 else { return }
        store.request(visibleTiles(size: size, viewport: controller.viewport), layer: layer, client: ObjectIdentifier(controller))
    }

    private func drawTiles(_ ctx: inout GraphicsContext, size: CGSize, viewport v: Viewport) {
        let tz = tileZoom(v.zoom)
        let scale = pow(2, v.zoom - Double(tz))
        let cw = Mercator.world(v.center, zoom: Double(tz))
        let n = 1 << tz
        let radius = hypot(size.width, size.height) / 2 / scale + 8
        let minX = Int(floor((cw.x - radius) / 256)), maxX = Int(floor((cw.x + radius) / 256))
        let minY = max(0, Int(floor((cw.y - radius) / 256))), maxY = min(n - 1, Int(floor((cw.y + radius) / 256)))
        guard minY <= maxY else { return }

        var c = ctx
        c.translateBy(x: size.width / 2, y: size.height / 2)
        c.rotate(by: .degrees(-v.heading))
        let tile = 256 * scale
        for ty in minY...maxY {
            for tx in minX...maxX {
                let wx = ((tx % n) + n) % n
                let rect = CGRect(x: (Double(tx) * 256 - cw.x) * scale, y: (Double(ty) * 256 - cw.y) * scale,
                                  width: tile + 0.6, height: tile + 0.6)
                let key = TileKey(x: wx, y: ty, z: tz, layer: layer.cacheKey)
                if let img = store.image(key) {
                    c.draw(Image(uiImage: img), in: rect)
                    continue
                }
                // Fallback: stretch the nearest cached ancestor tile while the sharp one loads.
                for k in 1...5 where tz - k >= 0 {
                    let pk = TileKey(x: wx >> k, y: ty >> k, z: tz - k, layer: layer.cacheKey)
                    guard let img = store.image(pk) else { continue }
                    let span = Double(1 << k)
                    let px = Double(tx >> k) * 256 * span, py = Double(ty >> k) * 256 * span
                    let prect = CGRect(x: (px - cw.x) * scale, y: (py - cw.y) * scale, width: tile * span + 0.6, height: tile * span + 0.6)
                    c.drawLayer { l in
                        l.clip(to: Path(rect))
                        l.draw(Image(uiImage: img), in: prect)
                    }
                    break
                }
            }
        }
    }

    // MARK: - Overlays

    private func drawLines(_ ctx: inout GraphicsContext, size: CGSize, viewport v: Viewport) {
        let bounds = CGRect(origin: .zero, size: size).insetBy(dx: -size.width, dy: -size.height)
        for line in lines where line.coordinates.count > 1 {
            var ahead = Path(), behind = Path()
            var last: CGPoint?
            var lastAhead = false
            for (i, c) in line.coordinates.enumerated() {
                let p = v.point(for: c, in: size)
                let travelled = (line.cumulative?[safe: i] ?? .infinity) <= line.travelledMeters
                if let l = last {
                    if hypot(p.x - l.x, p.y - l.y) < 1.2 && i < line.coordinates.count - 1 { continue }
                    if bounds.contains(p) || bounds.contains(l) {
                        if travelled {
                            behind.move(to: l); behind.addLine(to: p)
                        } else {
                            if !lastAhead { ahead.move(to: l) }
                            ahead.addLine(to: p)
                        }
                    }
                    lastAhead = !travelled && (bounds.contains(p) || bounds.contains(l))
                }
                last = p
            }
            let w = line.width
            let style = StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round, dash: line.dashed ? [1, w * 1.8] : [])
            if !behind.isEmpty {
                ctx.stroke(behind, with: .color(.gray.opacity(0.7)), style: StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round))
            }
            if let outline = line.outline, !line.dashed {
                ctx.stroke(ahead, with: .color(outline), style: StrokeStyle(lineWidth: w + 2.5, lineCap: .round, lineJoin: .round))
            }
            ctx.stroke(ahead, with: .color(line.color), style: style)
        }
    }

    private func drawPuck(_ ctx: inout GraphicsContext, _ puck: UserPuck, size: CGSize, viewport v: Viewport) {
        let p = v.point(for: puck.coordinate, in: size)
        let mpp = Mercator.metersPerPoint(latitude: puck.coordinate.latitude, zoom: v.zoom)
        let acc = puck.accuracy / mpp
        if acc > 12, acc < 400, !puck.navigation {
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - acc, y: p.y - acc, width: acc * 2, height: acc * 2)), with: .color(Brand.blue.opacity(0.15)))
        }
        if puck.navigation {
            // Google's navigation chevron.
            let heading = ((puck.heading ?? v.heading) - v.heading) * .pi / 180
            var arrow = Path()
            arrow.move(to: CGPoint(x: 0, y: -13))
            arrow.addLine(to: CGPoint(x: 10, y: 10))
            arrow.addLine(to: CGPoint(x: 0, y: 5))
            arrow.addLine(to: CGPoint(x: -10, y: 10))
            arrow.closeSubpath()
            let t = CGAffineTransform(translationX: p.x, y: p.y).rotated(by: heading)
            let a = arrow.applying(t)
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - 17, y: p.y - 17, width: 34, height: 34)), with: .color(.black.opacity(0.18)))
            ctx.stroke(a, with: .color(.white), style: StrokeStyle(lineWidth: 3, lineJoin: .round))
            ctx.fill(a, with: .color(Brand.blue))
            return
        }
        if let h = puck.heading {
            let angle = (h - v.heading - 90) * .pi / 180
            var cone = Path()
            cone.move(to: p)
            cone.addArc(center: p, radius: 30, startAngle: .radians(angle - 0.5), endAngle: .radians(angle + 0.5), clockwise: false)
            cone.closeSubpath()
            ctx.fill(cone, with: .radialGradient(Gradient(colors: [Brand.blue.opacity(0.55), Brand.blue.opacity(0)]),
                                                 center: p, startRadius: 4, endRadius: 30))
        }
        ctx.fill(Path(ellipseIn: CGRect(x: p.x - 9, y: p.y - 9, width: 18, height: 18)), with: .color(.white))
        ctx.fill(Path(ellipseIn: CGRect(x: p.x - 6.5, y: p.y - 6.5, width: 13, height: 13)), with: .color(Brand.blue))
    }

    private func drawPins(_ ctx: inout GraphicsContext, size: CGSize, viewport v: Viewport) {
        let frame = CGRect(origin: .zero, size: size).insetBy(dx: -30, dy: -40)
        // Draw selected/important pins last so they sit on top.
        let ordered = pins.sorted { rank($0.style) < rank($1.style) }
        for pin in ordered {
            let p = v.point(for: pin.coordinate, in: size)
            guard frame.contains(p) else { continue }
            switch pin.style {
            case .dot(let color):
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12)), with: .color(.white))
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 4.5, y: p.y - 4.5, width: 9, height: 9)), with: .color(color))
            case .place(let symbol, let color):
                drawBadge(&ctx, at: p, symbol: symbol, color: color, radius: 9)
            case .saved(let symbol, let color):
                drawBadge(&ctx, at: p, symbol: symbol, color: color, radius: 9)
            case .home:
                drawBadge(&ctx, at: p, symbol: "house.fill", color: Brand.blue, radius: 10)
            case .work:
                drawBadge(&ctx, at: p, symbol: "briefcase.fill", color: Brand.blue, radius: 10)
            case .parking:
                drawBadge(&ctx, at: p, symbol: "p.circle.fill", color: Brand.blue, radius: 10)
            case .start:
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 7, y: p.y - 7, width: 14, height: 14)), with: .color(.white))
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 4.5, y: p.y - 4.5, width: 9, height: 9)), with: .color(.black))
            case .measure(let n):
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 8, y: p.y - 8, width: 16, height: 16)), with: .color(.white))
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 6.5, y: p.y - 6.5, width: 13, height: 13)), with: .color(.black))
                ctx.draw(Text("\(n)").font(.system(size: 8, weight: .bold)).foregroundStyle(.white), at: p)
            case .end, .dropped:
                drawTeardrop(&ctx, tip: p, symbol: nil, color: Color(red: 0.92, green: 0.26, blue: 0.21), scale: 1.0)
            case .selected(let symbol, let color):
                drawTeardrop(&ctx, tip: p, symbol: symbol, color: color == .red ? Color(red: 0.92, green: 0.26, blue: 0.21) : color, scale: 1.15)
            }
        }
    }

    private func rank(_ s: MapPin.Style) -> Int {
        switch s {
        case .dot: 0
        case .place, .saved: 1
        case .home, .work, .parking, .start, .measure: 2
        case .end, .dropped, .selected: 3
        }
    }

    private func drawBadge(_ ctx: inout GraphicsContext, at p: CGPoint, symbol: String, color: Color, radius r: Double) {
        ctx.fill(Path(ellipseIn: CGRect(x: p.x - r - 1.5, y: p.y - r - 1.5, width: (r + 1.5) * 2, height: (r + 1.5) * 2)), with: .color(.white))
        ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)), with: .color(color))
        var img = ctx.resolve(Image(systemName: symbol))
        img.shading = .color(.white)
        let s = r * 1.15
        ctx.draw(img, in: CGRect(x: p.x - s / 2, y: p.y - s / 2, width: s, height: s))
    }

    /// The classic Google Maps red pin.
    private func drawTeardrop(_ ctx: inout GraphicsContext, tip: CGPoint, symbol: String?, color: Color, scale k: Double) {
        let r = 11.0 * k, h = 30.0 * k
        let cy = tip.y - h + r
        var pin = Path()
        pin.move(to: tip)
        pin.addCurve(to: CGPoint(x: tip.x - r, y: cy), control1: CGPoint(x: tip.x - r * 0.25, y: tip.y - h * 0.25), control2: CGPoint(x: tip.x - r, y: cy + r * 0.8))
        pin.addArc(center: CGPoint(x: tip.x, y: cy), radius: r, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        pin.addCurve(to: tip, control1: CGPoint(x: tip.x + r, y: cy + r * 0.8), control2: CGPoint(x: tip.x + r * 0.25, y: tip.y - h * 0.25))
        pin.closeSubpath()
        ctx.fill(Path(ellipseIn: CGRect(x: tip.x - 4, y: tip.y - 1.5, width: 8, height: 3)), with: .color(.black.opacity(0.3)))
        ctx.fill(pin, with: .color(color))
        ctx.stroke(pin, with: .color(Color(red: 0.65, green: 0.10, blue: 0.08)), lineWidth: 0.8)
        if let symbol {
            var img = ctx.resolve(Image(systemName: symbol))
            img.shading = .color(.white)
            let s = r * 1.1
            ctx.draw(img, in: CGRect(x: tip.x - s / 2, y: cy - s / 2, width: s, height: s))
        } else {
            ctx.fill(Path(ellipseIn: CGRect(x: tip.x - r * 0.38, y: cy - r * 0.38, width: r * 0.76, height: r * 0.76)),
                     with: .color(Color(red: 0.50, green: 0.06, blue: 0.05)))
        }
    }

    // MARK: - Gestures

    private func dragGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                if dragOrigin == nil {
                    dragOrigin = controller.viewport
                    moved = false
                    longPressFired = false
                    let start = value.startLocation
                    longPressTask?.cancel()
                    if let onLongPress {
                        longPressTask = Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(480))
                            guard !Task.isCancelled, !moved, dragOrigin != nil else { return }
                            longPressFired = true
                            WKInterfaceDevice.current().play(.click)
                            onLongPress(controller.viewport.coordinate(at: start, in: size))
                        }
                    }
                }
                if !moved, hypot(value.translation.width, value.translation.height) > 5 {
                    moved = true
                    longPressTask?.cancel()
                    controller.stopAnimation()
                    if controller.follow != .none { controller.follow = .none }
                    onUserPan?()
                }
                if moved, let origin = dragOrigin {
                    var o = origin
                    o.zoom = controller.viewport.zoom
                    controller.viewport = o.panned(by: value.translation)
                }
            }
            .onEnded { value in
                longPressTask?.cancel()
                defer { dragOrigin = nil }
                if moved, let origin = dragOrigin {
                    let fling = CGSize(width: value.predictedEndTranslation.width - value.translation.width,
                                       height: value.predictedEndTranslation.height - value.translation.height)
                    if hypot(fling.width, fling.height) > 40 {
                        var o = origin
                        o.zoom = controller.viewport.zoom
                        let total = CGSize(width: value.translation.width + fling.width * 0.45,
                                           height: value.translation.height + fling.height * 0.45)
                        controller.fly(to: o.panned(by: total), duration: 0.45)
                    }
                    return
                }
                guard !longPressFired else { return }
                handleTap(at: value.location, size: size)
            }
    }

    private func handleTap(at location: CGPoint, size: CGSize) {
        let v = controller.viewport
        // Hit-test pins (generous 22 pt targets; teardrops are hit on their head).
        var best: (MapPin, Double)?
        for pin in pins {
            var p = v.point(for: pin.coordinate, in: size)
            switch pin.style {
            case .end, .dropped, .selected: p.y -= 19
            default: break
            }
            let d = hypot(p.x - location.x, p.y - location.y)
            if d < 22, d < (best?.1 ?? .infinity) { best = (pin, d) }
        }
        if let (pin, _) = best, let onTapPin {
            WKInterfaceDevice.current().play(.click)
            onTapPin(pin)
            lastTap = nil
            return
        }
        // Double-tap zooms in on the tapped point.
        if let (t, p) = lastTap, Date().timeIntervalSince(t) < 0.32, hypot(p.x - location.x, p.y - location.y) < 30 {
            lastTap = nil
            let target = v.coordinate(at: location, in: size)
            var nv = v
            nv.zoom = min(Mercator.maxZoom, v.zoom + 1)
            let mid = CLLocationCoordinate2D(latitude: (v.center.latitude + target.latitude) / 2,
                                             longitude: (v.center.longitude + target.longitude) / 2)
            nv.center = mid
            controller.follow = .none
            controller.fly(to: nv, duration: 0.3)
        } else {
            lastTap = (Date(), location)
        }
    }
}

/// Digital Crown → zoom, without the focus ring.
private struct CrownZoom: ViewModifier {
    @Bindable var controller: MapController
    var enabled: Bool
    @State private var crown: Double = 15

    func body(content: Content) -> some View {
        if enabled {
            content
                .focusable()
                .focusEffectDisabled()
                .digitalCrownRotation($crown, from: Mercator.minZoom, through: Mercator.maxZoom, by: 0.05,
                                      sensitivity: .medium, isContinuous: false, isHapticFeedbackEnabled: true)
                .onAppear { crown = controller.zoom }
                .onChange(of: crown) { _, z in
                    guard abs(z - controller.zoom) > 0.001 else { return }
                    controller.stopAnimation()
                    controller.zoom = z
                }
                .onChange(of: controller.viewport.zoom) { _, z in
                    if abs(z - crown) > 0.06 { crown = z }
                }
        } else {
            content
        }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { i >= 0 && i < count ? self[i] : nil }
}
