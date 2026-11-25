import SwiftUI
import SwiftData
import CoreLocation

struct DirectionsView: View {
    let destination: Place
    let initialMode: TravelMode?

    @State private var location = LocationService.shared
    @State private var app = AppModel.shared
    @Environment(\.modelContext) private var context
    @State private var mode: TravelMode = .driving
    @State private var results: [TravelMode: DirectionsResult] = [:]
    @State private var etas: [TravelMode: TimeInterval] = [:]
    @State private var selected: UUID?
    @State private var loading = false
    @State private var error: String?
    @State private var options = RouteOptions.saved
    @State private var showOptions = false
    @State private var preview = MapController()
    @State private var origin: CLLocationCoordinate2D?
    @State private var didInit = false

    init(destination: Place, initialMode: TravelMode?) {
        self.destination = destination
        self.initialMode = initialMode
        _mode = State(initialValue: initialMode ?? AppDefaults.defaultMode)
    }

    private var routes: [Route] { results[mode]?.routes ?? [] }
    private var current: Route? { routes.first { $0.id == selected } ?? routes.first }
    private var modes: [TravelMode] {
        TravelMode.allCases.filter { $0 != .twoWheeler || etas[.twoWheeler] != nil || mode == .twoWheeler }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                endpoints
                modeStrip
                if loading && routes.isEmpty {
                    HStack { Spacer(); ProgressView(); Spacer() }.frame(height: 60)
                } else if let error, routes.isEmpty {
                    Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.secondary)
                    Button("Try again") { Task { await load(force: true) } }
                }
                if let current {
                    HStack(spacing: 6) {
                        PillButton(title: "Start", symbol: "location.north.line.fill") { start(current, simulate: false) }
                        if mode != .transit {
                            smallAction("list.bullet", "Steps") { app.open(.steps(current)) }
                        }
                        smallAction("play.fill", "Preview drive") { start(current, simulate: true) }
                    }
                    routeMap(current)
                    if routes.count > 1 {
                        Text("\(routes.count) routes").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    ForEach(routes) { r in routeCard(r) }
                    if mode == .transit {
                        Text("Transit times are from Apple Maps — Google only serves transit to signed-in browsers.")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    ShareLink(item: destination.directionsShareURL) {
                        Label("Share directions", systemImage: "square.and.arrow.up").font(.footnote)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .navigationTitle(Fmt.compactDurationOrNil(current?.duration) ?? "Directions")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showOptions = true } label: { Image(systemName: "slider.horizontal.3") }
                    .accessibilityLabel("Route options")
            }
        }
        .sheet(isPresented: $showOptions, onDismiss: {
            if options != RouteOptions.saved { saveOptions(); results = [:]; Task { await load(force: true) } }
        }) {
            RouteOptionsView(options: $options)
        }
        .task {
            guard !didInit else { return }
            didInit = true
            Library.addRecent(destination, context: context)
            await load()
        }
        .onChange(of: mode) { _, _ in selected = nil; Task { await load() } }
    }

    // MARK: - UI

    private var endpoints: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().stroke(Brand.blue, lineWidth: 2.5).frame(width: 9, height: 9)
                Text("Your location").font(.caption2).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Image(systemName: "mappin").font(.caption2).foregroundStyle(.red).frame(width: 9)
                Text(destination.name).font(.caption.weight(.semibold)).lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("From your location to \(destination.name)")
    }

    private var modeStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(modes) { m in
                    Button {
                        mode = m
                        if m != .transit { UserDefaults.standard.set(m.rawValue, forKey: SettingsKey.defaultMode) }
                        Guidance.shared.tap(.select)
                    } label: {
                        VStack(spacing: 1) {
                            Image(systemName: m.symbol).font(.system(size: 14, weight: .semibold))
                            Text(etas[m].map { Fmt.compactDuration($0) } ?? (m == mode && loading ? "…" : "—"))
                                .font(.system(size: 10, weight: .semibold))
                                .lineLimit(1)
                        }
                        .frame(minWidth: 40, minHeight: 36)
                        .padding(.horizontal, 3)
                        .foregroundStyle(m == mode ? .white : .primary)
                        .background(m == mode ? AnyShapeStyle(Brand.blue.gradient) : AnyShapeStyle(Color.white.opacity(0.1)),
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(m.label)\(etas[m].map { ", \(Fmt.duration($0))" } ?? "")")
                    .accessibilityAddTraits(m == mode ? .isSelected : [])
                }
            }
        }
    }

    private func routeMap(_ route: Route) -> some View {
        let lines = routes.filter { $0.id != route.id }.map {
            MapLine(id: $0.id.uuidString, coordinates: $0.coordinates, color: Color(white: 0.62), outline: Color(white: 0.45), width: 4)
        } + [MapLine(id: route.id.uuidString, coordinates: route.coordinates,
                     color: mode == .walking ? Brand.blue : Brand.blue, outline: Brand.routeOutline,
                     width: 5, dashed: mode == .walking || mode == .transit)]
        return GoogleMapView(controller: preview, layer: .saved,
                             pins: [MapPin(id: "s", coordinate: route.coordinates.first!, style: .start),
                                    MapPin(id: "e", coordinate: destination.coordinate, style: .end)],
                             lines: lines, interactive: false, crownZoom: false, onTapPin: nil)
            .frame(height: 112)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .onAppear { preview.size = CGSize(width: 180, height: 112); preview.fit(route.coordinates + [destination.coordinate], padding: 14, animated: false) }
            .onChange(of: route.id) { _, _ in preview.fit(route.coordinates + [destination.coordinate], padding: 14) }
            .accessibilityLabel("Route map")
    }

    private func smallAction(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 40, height: 40)
                .background(Color.white.opacity(0.14), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func routeCard(_ r: Route) -> some View {
        let isSel = r.id == current?.id
        return Button { selected = r.id; Guidance.shared.tap(.select) } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(Fmt.duration(r.duration)).font(.headline).foregroundStyle(r.trafficColor)
                    Spacer()
                    Text(Fmt.distance(r.distance)).font(.caption2).foregroundStyle(.secondary)
                }
                if !r.summary.isEmpty {
                    Text("via \(r.summary)").font(.caption2).lineLimit(2)
                }
                Text("Arrive \(Fmt.clock(Date().addingTimeInterval(r.duration)))").font(.caption2).foregroundStyle(.secondary)
                if let note = r.trafficNote {
                    Text(note).font(.system(size: 10)).foregroundStyle(Brand.traffic)
                } else if let range = r.durationRange, mode == .driving {
                    Text("Typically \(range)").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                if let label = r.label {
                    Label(label, systemImage: label.lowercased().contains("fastest") ? "bolt.fill" : "info.circle")
                        .font(.system(size: 10)).foregroundStyle(label.lowercased().contains("fastest") ? Brand.etaGreen : .secondary)
                }
                if r.avoidsHighways || r.avoidsTolls {
                    Text([r.avoidsHighways ? "Avoids highways" : nil, r.avoidsTolls ? "Avoids tolls" : nil].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            .padding(8)
            .background(isSel ? Brand.blue.opacity(0.22) : Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(isSel ? Brand.blue : .clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSel ? .isSelected : [])
    }

    // MARK: - Data

    private func load(force: Bool = false) async {
        if !force, results[mode] != nil { return }
        loading = true; error = nil
        defer { loading = false }
        guard let o = await location.currentLocation()?.coordinate else {
            error = "Waiting for your location…"
            return
        }
        origin = o
        do {
            let r = try await GoogleDirections.routes(from: o, to: destination.coordinate, mode: mode, options: options, destinationName: destination.name)
            results[mode] = r
            etas.merge(r.modeETAs) { _, new in new }
            if let best = r.routes.first { etas[mode] = best.duration }
            if r.routes.isEmpty { error = "No \(mode.label.lowercased()) route" }
            if mode != .transit, etas[.transit] == nil {
                if let t = try? await GoogleDirections.routes(from: o, to: destination.coordinate, mode: .transit) {
                    results[.transit] = t
                    etas[.transit] = t.routes.first?.duration
                }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func saveOptions() {
        let d = UserDefaults.standard
        d.set(options.avoidHighways, forKey: SettingsKey.avoidHighways)
        d.set(options.avoidTolls, forKey: SettingsKey.avoidTolls)
        d.set(options.avoidFerries, forKey: SettingsKey.avoidFerries)
    }

    private func start(_ r: Route, simulate: Bool) {
        NavigationEngine.shared.start(route: r, to: destination, simulate: simulate)
    }
}

struct RouteOptionsView: View {
    @Binding var options: RouteOptions
    @AppStorage(SettingsKey.defaultMode) private var defaultMode = TravelMode.driving.rawValue

    var body: some View {
        List {
            Section("Avoid") {
                Toggle("Highways", isOn: $options.avoidHighways)
                Toggle("Tolls", isOn: $options.avoidTolls)
                Toggle("Ferries", isOn: $options.avoidFerries)
            }
            Section("Default mode") {
                Picker("Travel mode", selection: $defaultMode) {
                    ForEach(TravelMode.allCases) { Label($0.label, systemImage: $0.symbol).tag($0.rawValue) }
                }
            }
        }
        .navigationTitle("Route options")
    }
}

struct StepsView: View {
    let route: Route

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading) {
                    Text(Fmt.duration(route.duration)).font(.headline).foregroundStyle(route.trafficColor)
                    Text("\(Fmt.distance(route.distance)) · \(route.summary)").font(.caption2).foregroundStyle(.secondary)
                }
            }
            ForEach(route.steps) { s in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: s.maneuver.symbol)
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 22)
                        .foregroundStyle(s.maneuver == .arrive ? .red : Brand.blue)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(s.instruction).font(.footnote)
                        if s.distance > 0 {
                            Text("\(Fmt.distance(s.distance)) · \(Fmt.duration(s.duration))").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .navigationTitle("Steps")
    }
}

extension Fmt {
    static func compactDurationOrNil(_ s: TimeInterval?) -> String? { s.map(compactDuration) }
}
