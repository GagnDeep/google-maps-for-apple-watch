import SwiftUI
import SwiftData
import CoreLocation

/// Hub: every Google Maps destination that doesn't fit on the map screen.
struct MenuView: View {
    @State private var app = AppModel.shared
    @State private var location = LocationService.shared
    @Query(sort: \ParkingSpot.date, order: .reverse) private var parking: [ParkingSpot]
    @Query private var saved: [SavedPlace]
    @AppStorage(SettingsKey.voiceMode) private var voiceRaw = VoiceMode.on.rawValue

    var body: some View {
        List {
            quickRow
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 6, trailing: 0))
            Section {
                row("Go", "car.fill", .green, "Home, work & recent ETAs") { app.open(.go) }
                row("Saved", "bookmark.fill", Brand.blue, "Lists, home & work") { app.open(.saved) }
                row("Explore nearby", "safari.fill", .orange, "Food, petrol, ATMs…") { app.open(.explore) }
            }
            Section {
                row("Parking", "parkingsign.circle.fill", Brand.blue,
                    parking.first.map { "Saved \(Fmt.relative($0.date))" } ?? "Save where you parked") { app.open(.parking) }
                row("Timeline", "point.bottomleft.forward.to.point.topright.scurvepath.fill", .pink, "Your trips") { app.open(.timeline) }
                row("Measure distance", "ruler.fill", .teal, "Tap points on the map") { app.open(.measure) }
                row("Compass", "location.north.circle.fill", .red, "Heading & coordinates") { app.open(.compass(nil)) }
            }
            Section {
                if let loc = location.location {
                    ShareLink(item: Place.droppedPin(at: loc.coordinate).shareURL,
                              subject: Text("My location"),
                              message: Text("I'm here: \(PlusCode.encode(loc.coordinate))")) {
                        Label { VStack(alignment: .leading) { Text("Share location"); Text(PlusCode.encode(loc.coordinate)).font(.caption2).foregroundStyle(.secondary) } }
                            icon: { Image(systemName: "person.wave.2.fill").foregroundStyle(.green) }
                    }
                }
                row("Layers", "square.3.layers.3d", .indigo, "Map type & details") { app.open(.layers) }
                row("Settings", "gearshape.fill", .gray, nil) { app.open(.settings) }
            }
        }
        .navigationTitle("Maps")
    }

    /// One-tap essentials: home, work, parking, voice.
    private var quickRow: some View {
        let home = saved.first { $0.list == .home }?.place
        let work = saved.first { $0.list == .work }?.place
        let voice = VoiceMode(rawValue: voiceRaw) ?? .on
        return HStack(spacing: 4) {
            quick("Home", "house.fill", Brand.blue) {
                if let home { app.open(.directions(home, nil)) } else { app.open(.search(.setHome)) }
            }
            quick("Work", "briefcase.fill", .brown) {
                if let work { app.open(.directions(work, nil)) } else { app.open(.search(.setWork)) }
            }
            quick("Parking", "parkingsign", .indigo) { app.open(.parking) }
            quick(voice == .muted ? "Muted" : voice == .alertsOnly ? "Alerts" : "Voice", voice.symbol,
                  voice == .muted ? .red : .green) {
                voiceRaw = voice.next.rawValue
                Guidance.shared.tap(voice.next == .muted ? .toggleOff : .toggleOn)
            }
        }
    }

    private func quick(_ title: String, _ symbol: String, _ color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 40, height: 40)
                    .background(color.gradient, in: Circle())
                Text(title).font(.system(size: 10, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private func row(_ title: String, _ symbol: String, _ color: Color, _ sub: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(color.gradient, in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.body)
                    if let sub { Text(sub).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                }
            }
        }
    }
}

struct SavedView: View {
    @State private var app = AppModel.shared
    @Query private var saved: [SavedPlace]
    @Query(sort: \RecentEntry.date, order: .reverse) private var recents: [RecentEntry]

    var body: some View {
        List {
            Section {
                labelRow(.home)
                labelRow(.work)
            }
            Section("Your lists") {
                ForEach(SavedList.collections) { l in
                    Button { app.open(.savedList(l)) } label: {
                        HStack {
                            Image(systemName: l.symbol).foregroundStyle(l.color).frame(width: 22)
                            VStack(alignment: .leading) {
                                Text(l.title)
                                Text("\(saved.filter { $0.list == l }.count) places").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            let visited = recents.compactMap(\.place).prefix(8)
            if !visited.isEmpty {
                Section("Recently viewed") {
                    ForEach(Array(visited)) { p in
                        Button { app.open(.place(p)) } label: { PlaceRow(place: p) }
                    }
                }
            }
        }
        .navigationTitle("Saved")
    }

    private func labelRow(_ l: SavedList) -> some View {
        let place = saved.first { $0.list == l }?.place
        return Button {
            if let place { app.open(.place(place)) } else { app.open(.search(l == .home ? .setHome : .setWork)) }
        } label: {
            HStack {
                Image(systemName: l.symbol).foregroundStyle(Brand.blue).frame(width: 22)
                VStack(alignment: .leading) {
                    Text(l.title)
                    Text(place?.subtitle ?? "Set location").font(.caption2).foregroundStyle(place == nil ? Brand.blue : .secondary).lineLimit(1)
                }
            }
        }
        .swipeActions {
            if place != nil {
                Button("Edit") { app.open(.search(l == .home ? .setHome : .setWork)) }.tint(Brand.blue)
            }
        }
    }
}

struct SavedListView: View {
    let list: SavedList
    @State private var app = AppModel.shared
    @Environment(\.modelContext) private var context
    @Query private var all: [SavedPlace]

    private var items: [SavedPlace] { all.filter { $0.list == list }.sorted { $0.createdAt > $1.createdAt } }

    var body: some View {
        List {
            if items.isEmpty {
                ContentUnavailableView("No places yet", systemImage: list.symbol, description: Text("Save places from their details page."))
            }
            ForEach(items) { s in
                if let p = s.place {
                    Button { app.open(.place(p)) } label: { PlaceRow(place: p) }
                }
            }
            .onDelete { idx in idx.map { items[$0] }.forEach(context.delete); try? context.save() }
            Button { app.open(.search(.addToList(list))) } label: {
                Label("Add place", systemImage: "plus.circle.fill").foregroundStyle(Brand.blue)
            }
            if !items.isEmpty {
                Button {
                    app.show(results: items.compactMap(\.place), title: list.title)
                } label: { Label("Show on map", systemImage: "map") }
            }
        }
        .navigationTitle(list.title)
    }
}

/// Google's "Go" tab: live ETAs to home, work and recent destinations.
struct GoView: View {
    @State private var app = AppModel.shared
    @State private var location = LocationService.shared
    @Query private var saved: [SavedPlace]
    @Query(sort: \RecentEntry.date, order: .reverse) private var recents: [RecentEntry]
    @State private var etas: [String: (TimeInterval, Route?)] = [:]
    private let mode = AppDefaults.defaultMode == .transit ? TravelMode.driving : AppDefaults.defaultMode

    private var targets: [(String, String, Place)] {
        var out: [(String, String, Place)] = []
        if let h = saved.first(where: { $0.list == .home })?.place { out.append(("Home", "house.fill", h)) }
        if let w = saved.first(where: { $0.list == .work })?.place { out.append(("Work", "briefcase.fill", w)) }
        var seen = Set(out.map(\.2.id))
        for r in recents {
            guard let p = r.place, !seen.contains(p.id) else { continue }
            seen.insert(p.id)
            out.append((p.name, "clock.arrow.circlepath", p))
            if out.count >= 7 { break }
        }
        return out
    }

    var body: some View {
        List {
            if targets.isEmpty {
                ContentUnavailableView("Nowhere to go yet", systemImage: "car", description: Text("Set Home and Work in Saved to see live ETAs here."))
            }
            ForEach(targets, id: \.2.id) { name, symbol, place in
                Button { app.open(.directions(place, mode)) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: symbol).foregroundStyle(Brand.blue).frame(width: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(name).lineLimit(1)
                            if let (t, r) = etas[place.id] {
                                Text("\(Fmt.duration(t)) · arrive \(Fmt.clock(Date().addingTimeInterval(t)))")
                                    .font(.caption2).foregroundStyle(r?.trafficColor ?? Brand.etaGreen)
                                if let s = r?.summary, !s.isEmpty { Text("via \(s)").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1) }
                            } else {
                                Text("Checking traffic…").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                        Image(systemName: mode.symbol).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Go")
        .task {
            guard let o = await location.currentLocation()?.coordinate else { return }
            await withTaskGroup(of: (String, TimeInterval, Route?)?.self) { group in
                for (_, _, p) in targets {
                    group.addTask {
                        guard let r = try? await GoogleDirections.routes(from: o, to: p.coordinate, mode: mode, destinationName: p.name) else { return nil }
                        let best = await MainActor.run { r.routes.first }
                        guard let t = await MainActor.run(body: { best?.duration ?? r.modeETAs[mode] }) else { return nil }
                        return (p.id, t, best)
                    }
                }
                for await item in group { if let (id, t, r) = item { etas[id] = (t, r) } }
            }
        }
    }
}
