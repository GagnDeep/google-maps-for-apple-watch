import SwiftUI
import SwiftData
import CoreLocation

/// Google's place sheet: rating, open-now, directions/start/call/save/share, hours, reviews, plus code.
struct PlaceDetailView: View {
    @State var place: Place
    @State private var app = AppModel.shared
    @State private var location = LocationService.shared
    @Environment(\.modelContext) private var context
    @Query private var saved: [SavedPlace]
    @State private var etas: [TravelMode: TimeInterval] = [:]
    @State private var showHours = false
    @State private var showSave = false
    @State private var startingNav = false
    @State private var mini = MapController()

    init(place: Place) { _place = State(initialValue: place) }

    private var defaultMode: TravelMode { AppDefaults.defaultMode == .transit ? .driving : AppDefaults.defaultMode }
    private var savedLists: Set<SavedList> { Set(saved.filter { $0.place?.id == place.id }.map(\.list)) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                header
                actions
                miniMap
                if let summary = place.summary { Text(summary).font(.footnote).foregroundStyle(.secondary) }
                infoRows
                if !place.hours.isEmpty { hoursSection }
                if !place.reviews.isEmpty { reviewsSection }
            }
            .padding(.horizontal, 2)
        }
        .navigationTitle(place.isDroppedPin ? "Dropped pin" : place.category.symbol == "mappin" ? "Place" : (place.primaryCategory ?? "Place"))
        .sheet(isPresented: $showSave) { SaveSheet(place: place) }
        .task(id: place.id) {
            mini.size = CGSize(width: 180, height: 90)
            mini.set(Viewport(center: place.coordinate, zoom: 16))
            await loadETAs()
            if (place.rating == nil || place.reviews.isEmpty) && !place.isDroppedPin, let fresh = await GoogleSearch.refresh(place) {
                place = fresh.reviews.isEmpty && fresh.rating == nil ? place : fresh
            }
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(place.name)
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            if let r = place.rating {
                RatingView(rating: r, count: place.reviewCount)
            }
            HStack(spacing: 4) {
                if let price = place.priceLevel { Text(price) }
                if let cat = place.primaryCategory { Text(cat).lineLimit(1) }
                if let d = place.distance(from: location.location) {
                    Text("· \(Fmt.distance(d))")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            OpenStatusText(place: place)
        }
    }

    private var actions: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                PillButton(title: etas[defaultMode].map { Fmt.compactDuration($0) } ?? "Directions",
                           symbol: "arrow.triangle.turn.up.right.diamond.fill") {
                    app.open(.directions(place, nil))
                }
                PillButton(title: "Start", symbol: "location.north.line.fill", filled: false) {
                    Task { await quickStart() }
                }
                .disabled(startingNav)
                .overlay { if startingNav { ProgressView().scaleEffect(0.6) } }
            }
            HStack(spacing: 2) {
                if let phone = place.phone, let url = URL(string: "tel:" + phone.filter { $0.isNumber || $0 == "+" }) {
                    Link(destination: url) {
                        roundLabel("Call", "phone.fill", Brand.blue)
                    }
                    .buttonStyle(.plain)
                }
                RoundAction(title: savedLists.isEmpty ? "Save" : "Saved", symbol: savedLists.isEmpty ? "bookmark" : "bookmark.fill") { showSave = true }
                ShareLink(item: place.shareURL, subject: Text(place.name), message: Text(place.name)) {
                    roundLabel("Share", "square.and.arrow.up", Brand.blue)
                }
                .buttonStyle(.plain)
                RoundAction(title: "Nearby", symbol: "magnifyingglass") { searchNearby() }
            }
        }
    }

    private func roundLabel(_ title: String, _ symbol: String, _ tint: Color) -> some View {
        VStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 34, height: 34)
                .background(tint.opacity(0.2), in: Circle())
                .foregroundStyle(tint)
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var miniMap: some View {
        GoogleMapView(controller: mini, layer: .saved,
                      pins: [MapPin(id: "p", coordinate: place.coordinate, style: .selected(symbol: place.category.symbol, color: .red))],
                      puck: location.location.map { UserPuck(coordinate: $0.coordinate, heading: nil, accuracy: $0.horizontalAccuracy) },
                      interactive: false, crownZoom: false)
            .frame(height: 90)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .onTapGesture {
                app.map.follow = .none
                app.map.fly(to: place.coordinate, zoom: 17)
                if !app.results.contains(where: { $0.id == place.id }) { app.droppedPin = place }
                app.path.removeAll()
            }
            .accessibilityLabel("Show on map")
            .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private var infoRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let a = place.fullAddress ?? (place.subtitle.isEmpty ? nil : place.subtitle) {
                info("mappin.and.ellipse", a)
            }
            if let phone = place.phone { info("phone", phone) }
            if let url = place.url {
                Link(destination: url) { info("globe", url.host() ?? url.absoluteString, tint: Brand.blue) }
                    .buttonStyle(.plain)
            }
            info("plus.viewfinder", place.plusCodeLocality ?? PlusCode.encode(place.coordinate))
            info("location", Fmt.coordinate(place.coordinate))
            if let s = savedLists.first {
                info(s.symbol, "Saved in \(savedLists.map(\.title).sorted().joined(separator: ", "))", tint: s.color)
            }
        }
        .card()
    }

    private func info(_ symbol: String, _ text: String, tint: Color = .secondary) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint).frame(width: 16)
            Text(text).font(.footnote).foregroundStyle(tint == .secondary ? .primary : tint)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private var hoursSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { withAnimation { showHours.toggle() } } label: {
                HStack {
                    Image(systemName: "clock")
                    Text("Hours").font(.footnote.weight(.semibold))
                    Spacer()
                    Image(systemName: showHours ? "chevron.up" : "chevron.down").font(.caption2)
                }
            }
            .buttonStyle(.plain)
            ForEach(showHours ? place.hours : Array(place.hours.prefix(1)), id: \.day) { d in
                HStack(alignment: .top) {
                    Text(d.day).font(.caption2.weight(d.isToday ? .bold : .regular)).frame(width: 64, alignment: .leading)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(d.hours).font(.caption2.weight(d.isToday ? .bold : .regular))
                        if let note = d.note { Text(note).font(.system(size: 9)).foregroundStyle(.orange) }
                    }
                }
            }
        }
        .card()
    }

    private var reviewsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Reviews", systemImage: "text.bubble").font(.footnote.weight(.semibold))
            ForEach(place.reviews.prefix(3), id: \.self) { r in
                Text("“\(r)”").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .card()
    }

    // MARK: - Actions

    private func loadETAs() async {
        guard let origin = await location.currentLocation(timeout: 4)?.coordinate else { return }
        if let r = try? await GoogleDirections.routes(from: origin, to: place.coordinate, mode: defaultMode, destinationName: place.name) {
            var e = r.modeETAs
            if let best = r.routes.first { e[defaultMode] = best.duration }
            etas = e
        }
    }

    private func quickStart() async {
        startingNav = true
        defer { startingNav = false }
        guard let origin = await location.currentLocation()?.coordinate,
              let r = try? await GoogleDirections.routes(from: origin, to: place.coordinate, mode: defaultMode, destinationName: place.name),
              let best = r.routes.first else {
            Guidance.shared.tap(.warning)
            return
        }
        Library.addRecent(place, context: context)
        NavigationEngine.shared.start(route: best, to: place)
    }

    private func searchNearby() {
        app.map.follow = .none
        app.map.set(Viewport(center: place.coordinate, zoom: 15))
        app.path.removeAll()
        app.open(.search(.browse))
    }
}

/// Google's "Save to lists" sheet + Home/Work labels.
struct SaveSheet: View {
    let place: Place
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var saved: [SavedPlace]

    private var lists: Set<SavedList> { Set(saved.filter { $0.place?.id == place.id }.map(\.list)) }

    var body: some View {
        List {
            Section("Save to") {
                ForEach(SavedList.collections) { l in row(l) }
            }
            Section("Label as") {
                row(.home)
                row(.work)
            }
        }
        .navigationTitle("Save")
    }

    private func row(_ l: SavedList) -> some View {
        Button {
            Library.toggle(place, in: l, context: context)
            Guidance.shared.tap(.prepare)
        } label: {
            HStack {
                Image(systemName: l.symbol).foregroundStyle(l.color).frame(width: 20)
                Text(l.title)
                Spacer()
                if lists.contains(l) { Image(systemName: "checkmark").foregroundStyle(Brand.blue) }
            }
        }
    }
}
