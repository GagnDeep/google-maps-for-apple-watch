import SwiftUI
import SwiftData
import CoreLocation

/// Home screen: full-screen Google map, like opening Google Maps.
struct ExploreView: View {
    @State private var app = AppModel.shared
    @State private var location = LocationService.shared
    @Environment(\.modelContext) private var context
    @Query private var saved: [SavedPlace]
    @Query(sort: \ParkingSpot.date, order: .reverse) private var parking: [ParkingSpot]

    @AppStorage(SettingsKey.mapType) private var mapType = MapType.standard.rawValue
    @AppStorage(SettingsKey.showTraffic) private var traffic = false
    @AppStorage(SettingsKey.showTransit) private var transit = false
    @AppStorage(SettingsKey.showBiking) private var biking = false
    @AppStorage(SettingsKey.darkMap) private var dark = false
    @State private var resolvingPin = false

    private var layer: TileLayer {
        TileLayer(type: MapType(rawValue: mapType) ?? .standard, traffic: traffic, transit: transit, biking: biking, dark: dark)
    }

    var body: some View {
        ZStack(alignment: .top) {
            GoogleMapView(controller: app.map, layer: layer, pins: pins, puck: puck,
                          onTapPin: tapped, onLongPress: dropPin)
                .ignoresSafeArea()

            VStack(spacing: 4) {
                if let title = app.resultsTitle {
                    resultsChip(title)
                }
                Spacer()
                if let place = app.results[safe: app.selectedResult] {
                    resultCard(place)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, app.results.isEmpty ? 0 : 4)
            .ignoresSafeArea(edges: app.results.isEmpty ? [] : .bottom)
            .animation(.snappy, value: app.selectedResult)

            if abs(app.map.viewport.heading) > 1, app.map.follow != .followHeading {
                HStack {
                    Spacer()
                    Button { app.map.resetNorth() } label: {
                        Image(systemName: "location.north.fill")
                            .rotationEffect(.degrees(-app.map.viewport.heading))
                            .foregroundStyle(.red)
                            .frame(width: 28, height: 28)
                            .background(.regularMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Reset to north")
                }
                .padding(.trailing, 6)
                .padding(.top, app.resultsTitle == nil ? 4 : 36)
            }

            if resolvingPin {
                ProgressView().padding(8).background(.regularMaterial, in: Circle()).frame(maxHeight: .infinity)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { app.open(.search(.browse)) } label: { Image(systemName: "magnifyingglass") }
                    .accessibilityLabel("Search Google Maps")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { app.open(.menu) } label: { Image(systemName: "line.3.horizontal") }
                    .accessibilityLabel("Menu")
            }
            if app.results.isEmpty {
                ToolbarItemGroup(placement: .bottomBar) {
                    Button(action: cycleFollow) { Image(systemName: followSymbol) }
                        .accessibilityLabel(followLabel)
                    Spacer()
                    Button { app.open(.explore) } label: { Image(systemName: "safari") }
                        .accessibilityLabel("Explore nearby")
                    Spacer()
                    Button { app.open(.layers) } label: { Image(systemName: "square.3.layers.3d") }
                        .accessibilityLabel("Layers")
                }
            }
        }
        .onChange(of: location.location) { _, loc in
            guard let loc, !NavigationEngine.shared.isActive else { return }
            if !app.didCenterOnUser {
                app.didCenterOnUser = true
                app.map.follow = .follow
                app.map.set(Viewport(center: loc.coordinate, zoom: 16))
                return
            }
            if app.map.follow != .none {
                var v = app.map.viewport
                v.center = loc.coordinate
                app.map.fly(to: v, duration: 0.5)
            }
        }
        .onChange(of: location.heading) { _, h in
            guard app.map.follow == .followHeading, let h else { return }
            app.map.viewport.heading = h
        }
        .onDisappear { location.stopHeading() }
        .onAppear {
            location.startHeading()
            if !app.didCenterOnUser, let c = location.coordinate {
                app.didCenterOnUser = true
                app.map.follow = .follow
                app.map.set(Viewport(center: c, zoom: 16))
            }
        }
    }

    // MARK: - Pins

    private var pins: [MapPin] {
        var out: [MapPin] = []
        for s in saved {
            guard let p = s.place else { continue }
            switch s.list {
            case .home: out.append(MapPin(id: "home", coordinate: p.coordinate, style: .home, payload: p))
            case .work: out.append(MapPin(id: "work", coordinate: p.coordinate, style: .work, payload: p))
            default:
                if !out.contains(where: { $0.id == "saved-\(p.id)" }) {
                    out.append(MapPin(id: "saved-\(p.id)", coordinate: p.coordinate,
                                      style: .saved(symbol: s.list.symbol, color: s.list.color), payload: p))
                }
            }
        }
        if let spot = parking.first {
            out.append(MapPin(id: "parking", coordinate: spot.coordinate, style: .parking, payload: spot.asPlace))
        }
        for (i, p) in app.results.enumerated() {
            out.append(MapPin(id: "r-\(p.id)", coordinate: p.coordinate,
                              style: i == app.selectedResult ? .selected(symbol: p.category.symbol, color: .red) : .place(symbol: p.category.symbol, color: p.category.color),
                              payload: p))
        }
        if let pin = app.droppedPin {
            out.append(MapPin(id: "dropped", coordinate: pin.coordinate, style: .dropped, payload: pin))
        }
        return out
    }

    private var puck: UserPuck? {
        guard let loc = location.location else { return nil }
        return UserPuck(coordinate: loc.coordinate, heading: location.heading, accuracy: loc.horizontalAccuracy)
    }

    private func tapped(_ pin: MapPin) {
        if pin.id == "parking" { app.open(.parking); return }
        if let i = app.results.firstIndex(where: { "r-\($0.id)" == pin.id }), i != app.selectedResult {
            app.selectResult(i)   // first tap selects, second tap opens
            return
        }
        if let p = pin.payload { app.open(.place(p)) }
    }

    private func dropPin(_ c: CLLocationCoordinate2D) {
        app.droppedPin = .droppedPin(at: c)
        resolvingPin = true
        Task {
            let place = await GoogleSearch.whatsHere(c)
            resolvingPin = false
            app.droppedPin = place
            app.open(.place(place))
        }
    }

    // MARK: - Controls

    private func resultsChip(_ title: String) -> some View {
        HStack(spacing: 6) {
            Button { app.open(.results(title)) } label: {
                HStack(spacing: 5) {
                    Image(systemName: "list.bullet").font(.caption2.weight(.bold))
                    Text(title).font(.caption.weight(.semibold)).lineLimit(1)
                    Text("\(app.results.count)").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title), \(app.results.count) results. Show list.")
            Button { withAnimation(.snappy) { app.clearResults() }; Guidance.shared.tap(.toggleOff) } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Clear results")
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(.regularMaterial, in: Capsule())
    }

    /// Bottom card that steps through results one by one (Google's result carousel).
    private func resultCard(_ p: Place) -> some View {
        HStack(spacing: 4) {
            stepButton("chevron.left", label: "Previous result") { app.selectResult(app.selectedResult - 1) }
            Button { app.open(.place(p)) } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(p.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    HStack(spacing: 3) {
                        if let r = p.rating {
                            Text(String(format: "%.1f", r)).fontWeight(.semibold)
                            Image(systemName: "star.fill").foregroundStyle(Brand.star).font(.system(size: 8))
                        }
                        if let d = p.distance(from: location.location) { Text("· \(Fmt.distance(d))") }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    Text("\(app.selectedResult + 1) of \(app.results.count)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Brand.blue)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(p.name), result \(app.selectedResult + 1) of \(app.results.count)")
            .accessibilityHint("Opens details")
            stepButton("chevron.right", label: "Next result") { app.selectResult(app.selectedResult + 1) }
        }
        .padding(.horizontal, 4).padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.bottom, 2)
    }

    private func stepButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .bold))
                .frame(width: 28, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(app.results.count < 2)
        .accessibilityLabel(label)
    }

    private var followSymbol: String {
        switch app.map.follow {
        case .none: "location"
        case .follow: "location.fill"
        case .followHeading: "location.north.line.fill"
        }
    }

    private var followLabel: String {
        switch app.map.follow {
        case .none: "Show your location"
        case .follow: "Follow heading"
        case .followHeading: "Stop following heading"
        }
    }

    private func cycleFollow() {
        location.start()
        switch app.map.follow {
        case .none:
            app.map.follow = .follow
            if let c = location.coordinate { app.map.fly(to: Viewport(center: c, zoom: max(app.map.zoom, 16), heading: 0)) }
        case .follow:
            app.map.follow = .followHeading
            location.startHeading()
        case .followHeading:
            app.map.follow = .follow
            location.stopHeading()
            app.map.resetNorth()
        }
    }
}
