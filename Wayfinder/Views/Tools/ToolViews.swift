import SwiftUI
import SwiftData
import CoreLocation
import UserNotifications

// MARK: - Timeline

struct TimelineView: View {
    @State private var app = AppModel.shared
    @Environment(\.modelContext) private var context
    @Query(sort: \Trip.startedAt, order: .reverse) private var trips: [Trip]

    private var days: [(Date, [Trip])] {
        let groups = Dictionary(grouping: trips) { Calendar.current.startOfDay(for: $0.startedAt) }
        return groups.sorted { $0.key > $1.key }.map { ($0.key, $0.value) }
    }

    var body: some View {
        List {
            if trips.isEmpty {
                ContentUnavailableView("No trips yet", systemImage: "point.bottomleft.forward.to.point.topright.scurvepath",
                                       description: Text("Trips you navigate are kept here, on your watch only."))
            } else {
                Section {
                    let total = trips.reduce(0) { $0 + $1.distanceTraveled }
                    HStack {
                        stat("\(trips.count)", "Trips")
                        stat(Fmt.distance(total), "Travelled")
                        stat("\(Set(trips.compactMap { $0.destination?.id }).count)", "Places")
                    }
                }
            }
            ForEach(days, id: \.0) { day, items in
                Section(day.formatted(.dateTime.weekday(.wide).month().day())) {
                    ForEach(items) { t in
                        Button { app.open(.trip(t.persistentModelID)) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: t.mode.symbol).foregroundStyle(.white)
                                    .frame(width: 26, height: 26).background(Brand.blue.gradient, in: Circle())
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(t.destination?.name ?? "Trip").lineLimit(1)
                                    Text("\(Fmt.clock(t.startedAt)) · \(Fmt.duration(t.duration)) · \(Fmt.distance(t.distanceTraveled))")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .onDelete { idx in idx.map { items[$0] }.forEach(context.delete); try? context.save() }
                }
            }
        }
        .navigationTitle("Timeline")
    }

    private func stat(_ v: String, _ l: String) -> some View {
        VStack(spacing: 0) {
            Text(v).font(.headline).lineLimit(1).minimumScaleFactor(0.6)
            Text(l).font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

struct TripDetailView: View {
    let tripID: PersistentIdentifier
    @Environment(\.modelContext) private var context
    @State private var map = MapController()
    @State private var app = AppModel.shared

    var body: some View {
        if let trip = context.model(for: tripID) as? Trip {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    let path = trip.path
                    GoogleMapView(controller: map, layer: .saved,
                                  pins: [path.first.map { MapPin(id: "s", coordinate: $0, style: .start) },
                                         path.last.map { MapPin(id: "e", coordinate: $0, style: .end) }].compactMap { $0 },
                                  lines: [MapLine(id: "trip", coordinates: path)], crownZoom: false)
                        .frame(height: 120)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .onAppear { map.size = CGSize(width: 180, height: 120); map.fit(path, padding: 16, animated: false) }
                    Text(trip.destination?.name ?? "Trip").font(.headline)
                    Text("From \(trip.originName)").font(.caption2).foregroundStyle(.secondary)
                    Grid(alignment: .leading, verticalSpacing: 4) {
                        GridRow { Text("Mode").foregroundStyle(.secondary); Label(trip.mode.label, systemImage: trip.mode.symbol) }
                        GridRow { Text("Started").foregroundStyle(.secondary); Text(trip.startedAt.formatted(date: .abbreviated, time: .shortened)) }
                        GridRow { Text("Duration").foregroundStyle(.secondary); Text(Fmt.duration(trip.duration)) }
                        GridRow { Text("Distance").foregroundStyle(.secondary); Text(Fmt.distance(trip.distanceTraveled)) }
                        if trip.duration > 0 {
                            GridRow { Text("Avg speed").foregroundStyle(.secondary); Text(Fmt.speed(trip.distanceTraveled / trip.duration).value + " " + Fmt.speed(0).unit) }
                        }
                        GridRow { Text("Status").foregroundStyle(.secondary); Text(trip.arrived ? "Arrived" : "Ended early") }
                    }
                    .font(.caption)
                    if let d = trip.destination {
                        PillButton(title: "Go again", symbol: "arrow.triangle.turn.up.right.diamond.fill") {
                            app.open(.directions(d, trip.mode))
                        }
                    }
                }
            }
            .navigationTitle(trip.startedAt.formatted(.dateTime.month().day()))
        } else {
            ContentUnavailableView("Trip deleted", systemImage: "trash")
        }
    }
}

// MARK: - Parking

struct ParkingView: View {
    @State private var app = AppModel.shared
    @State private var location = LocationService.shared
    @Environment(\.modelContext) private var context
    @Query(sort: \ParkingSpot.date, order: .reverse) private var spots: [ParkingSpot]
    @State private var map = MapController()
    @State private var saving = false
    @State private var showTimer = false

    var body: some View {
        ScrollView {
            if let spot = spots.first {
                VStack(alignment: .leading, spacing: 8) {
                    GoogleMapView(controller: map, layer: .saved,
                                  pins: [MapPin(id: "p", coordinate: spot.coordinate, style: .parking)],
                                  puck: location.location.map { UserPuck(coordinate: $0.coordinate, heading: location.heading, accuracy: $0.horizontalAccuracy) },
                                  crownZoom: false)
                        .frame(height: 110)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .onAppear {
                            map.size = CGSize(width: 180, height: 110)
                            map.fit([spot.coordinate] + (location.coordinate.map { [$0] } ?? []), padding: 22, maxZoom: 18, animated: false)
                        }
                    Text("Parked \(Fmt.relative(spot.date))").font(.headline)
                    if let a = spot.address { Text(a).font(.caption2).foregroundStyle(.secondary) }
                    if let loc = location.location {
                        Text("\(Fmt.distance(loc.distance(from: CLLocation(latitude: spot.latitude, longitude: spot.longitude)))) away")
                            .font(.caption).foregroundStyle(Brand.blue)
                    }
                    if let exp = spot.meterExpiry, exp > .now {
                        Label { Text(exp, style: .timer) } icon: { Image(systemName: "timer") }
                            .font(.headline.monospacedDigit()).foregroundStyle(.orange)
                    }
                    HStack(spacing: 6) {
                        PillButton(title: "Walk", symbol: "figure.walk") { app.open(.directions(spot.asPlace, .walking)) }
                        PillButton(title: "Compass", symbol: "location.north.line.fill", filled: false) { app.open(.compass(spot.asPlace)) }
                    }
                    PillButton(title: spot.meterExpiry == nil ? "Parking timer" : "Change timer", symbol: "timer", tint: .orange, filled: false) { showTimer = true }
                    ShareLink(item: spot.asPlace.shareURL, message: Text("My car is parked here")) {
                        Label("Share parking", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity).font(.footnote)
                    }
                    Button(role: .destructive) {
                        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["parking-meter"])
                        spots.forEach(context.delete)
                        try? context.save()
                    } label: { Label("Clear parking", systemImage: "trash").frame(maxWidth: .infinity) }
                }
                .sheet(isPresented: $showTimer) { ParkingTimerView(spot: spot) }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "parkingsign.circle.fill").font(.system(size: 44)).foregroundStyle(Brand.blue)
                    Text("Save your parking").font(.headline)
                    Text("Find your way back to your car later.").font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    PillButton(title: saving ? "Saving…" : "Save parking here", symbol: "mappin.and.ellipse") {
                        Task {
                            saving = true
                            if let c = await location.currentLocation()?.coordinate {
                                _ = await Library.saveParking(at: c, context: context)
                                Guidance.shared.tap(.arrive)
                            }
                            saving = false
                        }
                    }
                    .disabled(saving)
                }
            }
        }
        .navigationTitle("Parking")
    }
}

struct ParkingTimerView: View {
    let spot: ParkingSpot
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var minutes = 60.0

    var body: some View {
        VStack(spacing: 8) {
            Text("\(Int(minutes)) min").font(.title2.monospacedDigit().weight(.semibold))
                .focusable()
                .digitalCrownRotation($minutes, from: 5, through: 600, by: 5, sensitivity: .low, isContinuous: false, isHapticFeedbackEnabled: true)
            Text("Turn the crown").font(.caption2).foregroundStyle(.secondary)
            Button("Start timer") {
                let exp = Date().addingTimeInterval(minutes * 60)
                spot.meterExpiry = exp
                try? context.save()
                Task {
                    await NotificationsHelper.requestIfNeeded()
                    schedule(at: exp)
                    dismiss()
                }
            }
            .buttonStyle(.borderedProminent).tint(.orange)
        }
        .navigationTitle("Parking timer")
    }

    private func schedule(at date: Date) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ["parking-meter", "parking-meter-warn"])
        func add(_ id: String, _ fire: Date, _ body: String) {
            guard fire > .now else { return }
            let c = UNMutableNotificationContent()
            c.title = "Parking"
            c.body = body
            c.sound = .default
            let t = UNTimeIntervalNotificationTrigger(timeInterval: fire.timeIntervalSinceNow, repeats: false)
            center.add(UNNotificationRequest(identifier: id, content: c, trigger: t))
        }
        add("parking-meter-warn", date.addingTimeInterval(-600), "Your parking expires in 10 minutes.")
        add("parking-meter", date, "Your parking time is up.")
    }
}

// MARK: - Compass

struct CompassView: View {
    let target: Place?
    @State private var location = LocationService.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 6) {
                let heading = location.heading ?? location.location.map { $0.course >= 0 ? $0.course : 0 } ?? 0
                ZStack {
                    Circle().stroke(Color.white.opacity(0.2), lineWidth: 2)
                    ForEach(0..<72, id: \.self) { i in
                        Rectangle()
                            .fill(i % 18 == 0 ? Color.white : Color.white.opacity(0.4))
                            .frame(width: i % 18 == 0 ? 2 : 1, height: i % 6 == 0 ? 8 : 4)
                            .offset(y: -58)
                            .rotationEffect(.degrees(Double(i) * 5))
                    }
                    ForEach(Array(["N", "E", "S", "W"].enumerated()), id: \.0) { i, l in
                        Text(l).font(.caption.weight(.bold))
                            .foregroundStyle(l == "N" ? .red : .white)
                            .offset(y: -44)
                            .rotationEffect(.degrees(Double(i) * 90))
                    }
                    if let t = target, let c = location.coordinate {
                        Image(systemName: "location.north.fill")
                            .font(.system(size: 34))
                            .foregroundStyle(Brand.blue)
                            .rotationEffect(.degrees(c.bearing(to: t.coordinate)))
                    } else {
                        Image(systemName: "arrowtriangle.up.fill").font(.system(size: 18)).foregroundStyle(.red).offset(y: -22)
                    }
                }
                .rotationEffect(.degrees(-heading))
                .animation(.easeOut(duration: 0.25), value: heading)
                .frame(width: 130, height: 130)

                Text("\(Int(heading.rounded()))° \(Compass.cardinal(heading))")
                    .font(.title3.monospacedDigit().weight(.semibold))
                if let t = target, let loc = location.location {
                    Text("\(t.name) · \(Fmt.distance(loc.distance(from: t.location)))").font(.caption).foregroundStyle(Brand.blue)
                }
                if let loc = location.location {
                    VStack(spacing: 2) {
                        Text(Fmt.dms(loc.coordinate)).font(.caption2.monospacedDigit())
                        Text(PlusCode.encode(loc.coordinate)).font(.caption2.monospaced())
                        Text("Elevation \(Fmt.altitude(loc.altitude)) · ±\(Int(loc.horizontalAccuracy)) m").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle(target == nil ? "Compass" : "Find")
        .onAppear { location.startHeading() }
        .onDisappear { location.stopHeading() }
    }
}

// MARK: - Measure distance

struct MeasureView: View {
    @State private var map = MapController()
    @State private var points: [CLLocationCoordinate2D] = []
    @State private var app = AppModel.shared

    private var total: Double {
        zip(points, points.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) }
    }

    var body: some View {
        ZStack {
            GoogleMapView(controller: map, layer: .saved,
                          pins: points.enumerated().map { MapPin(id: "m\($0.offset)", coordinate: $0.element, style: .measure($0.offset + 1)) },
                          lines: points.count > 1 ? [MapLine(id: "measure", coordinates: points, color: .black, outline: .white, width: 3)]
                                                  : [],
                          onLongPress: { points.append($0) })
                .ignoresSafeArea()
            Image(systemName: "plus")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.black)
                .shadow(color: .white, radius: 1)
                .allowsHitTesting(false)
            VStack {
                Text(points.count < 2 ? "Move map, tap +" : Fmt.distance(total))
                    .font(.headline.monospacedDigit())
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(.regularMaterial, in: Capsule())
                Spacer()
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                Button { if !points.isEmpty { points.removeLast() } } label: { Image(systemName: "arrow.uturn.backward") }
                    .disabled(points.isEmpty)
                    .accessibilityLabel("Undo")
                Spacer()
                Button { points.append(map.viewport.center); Guidance.shared.tap(.prepare) } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Add point at center")
                Spacer()
                Button { points.removeAll() } label: { Image(systemName: "trash") }
                    .disabled(points.isEmpty)
                    .accessibilityLabel("Clear")
            }
        }
        .onAppear { map.set(Viewport(center: app.map.viewport.center, zoom: max(app.map.zoom, 15))) }
    }
}

// MARK: - Layers

struct LayersView: View {
    @AppStorage(SettingsKey.mapType) private var mapType = MapType.standard.rawValue
    @AppStorage(SettingsKey.showTraffic) private var traffic = false
    @AppStorage(SettingsKey.showTransit) private var transit = false
    @AppStorage(SettingsKey.showBiking) private var biking = false
    @AppStorage(SettingsKey.darkMap) private var dark = false

    var body: some View {
        List {
            Section("Map type") {
                LazyVGrid(columns: [GridItem(), GridItem()], spacing: 6) {
                    ForEach(MapType.allCases) { t in
                        Button { mapType = t.rawValue } label: {
                            VStack(spacing: 3) {
                                Image(systemName: t.symbol).font(.title3)
                                Text(t.label).font(.caption2)
                            }
                            .frame(maxWidth: .infinity, minHeight: 50)
                            .background(mapType == t.rawValue ? Brand.blue.opacity(0.35) : Color.white.opacity(0.08),
                                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(mapType == t.rawValue ? Brand.blue : .clear, lineWidth: 1.5))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(mapType == t.rawValue ? .isSelected : [])
                    }
                }
                .listRowBackground(Color.clear)
            }
            Section("Map details") {
                Toggle(isOn: $traffic) { Label("Traffic", systemImage: "car.rear.road.lane") }
                Toggle(isOn: $transit) { Label("Transit", systemImage: "tram.fill") }
                Toggle(isOn: $biking) { Label("Biking", systemImage: "bicycle") }
                Toggle(isOn: $dark) { Label("Dark map", systemImage: "moon.fill") }
            }
        }
        .navigationTitle("Layers")
    }
}

// MARK: - Settings

struct SettingsView: View {
    @AppStorage(SettingsKey.distanceUnit) private var unit = DistanceUnit.automatic.rawValue
    @AppStorage(SettingsKey.defaultMode) private var mode = TravelMode.driving.rawValue
    @AppStorage(SettingsKey.voiceMode) private var voice = VoiceMode.on.rawValue
    @AppStorage(SettingsKey.hapticLevel) private var haptics = HapticLevel.all.rawValue
    @AppStorage(SettingsKey.avoidHighways) private var avoidHighways = false
    @AppStorage(SettingsKey.avoidTolls) private var avoidTolls = false
    @AppStorage(SettingsKey.avoidFerries) private var avoidFerries = false
    @AppStorage(SettingsKey.navNorthUp) private var northUp = false
    @AppStorage(SettingsKey.showSpeedometer) private var speedo = true
    @AppStorage(SettingsKey.askToSaveParking) private var askParking = true
    @AppStorage(SettingsKey.saveTimeline) private var timeline = true
    @AppStorage(SettingsKey.voiceRate) private var rate = 0.52
    @Environment(\.modelContext) private var context
    @State private var location = LocationService.shared

    var body: some View {
        List {
            Section("Navigation") {
                Picker("Voice", selection: $voice) {
                    ForEach(VoiceMode.allCases) { Label($0.label, systemImage: $0.symbol).tag($0.rawValue) }
                }
                Picker("Wrist taps", selection: $haptics) {
                    ForEach(HapticLevel.allCases) { Label($0.label, systemImage: $0.symbol).tag($0.rawValue) }
                }
                Toggle("North up", isOn: $northUp)
                Toggle("Speedometer", isOn: $speedo)
                Toggle("Ask to save parking", isOn: $askParking)
                Button("Try a right turn") {
                    Guidance.shared.speak("In 300 meters, turn right.", interrupt: true)
                    Guidance.shared.tap(.right)
                }
                Button("Try a left turn") {
                    Guidance.shared.speak("Turn left.", interrupt: true)
                    Guidance.shared.tap(.left)
                }
                Slider(value: $rate, in: 0.4...0.62, step: 0.04) { Text("Voice speed") }
            }
            Section("Route options") {
                Picker("Default mode", selection: $mode) {
                    ForEach(TravelMode.allCases) { Text($0.label).tag($0.rawValue) }
                }
                Toggle("Avoid highways", isOn: $avoidHighways)
                Toggle("Avoid tolls", isOn: $avoidTolls)
                Toggle("Avoid ferries", isOn: $avoidFerries)
            }
            Section("Units") {
                Picker("Distance", selection: $unit) {
                    ForEach(DistanceUnit.allCases) { Text($0.label).tag($0.rawValue) }
                }
            }
            Section("Privacy") {
                Toggle("Keep Timeline", isOn: $timeline)
                Button("Clear search history", role: .destructive) {
                    try? context.delete(model: RecentEntry.self); try? context.save()
                }
                Button("Delete Timeline", role: .destructive) {
                    try? context.delete(model: Trip.self); try? context.save()
                }
                Button("Clear map cache") {
                    TileStore.shared.clearDisk()
                }
                if !location.isAuthorized {
                    Text("Location is off. Turn it on in Settings › Privacy › Location Services › Wayfinder.")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
            Section {
                Text("Map, search, places, traffic and routes come live from Google Maps. Everything you save stays on this watch.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
    }
}
