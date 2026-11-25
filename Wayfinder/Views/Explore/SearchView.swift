import SwiftUI
import SwiftData
import CoreLocation

struct SearchView: View {
    let purpose: SearchPurpose

    @State private var app = AppModel.shared
    @State private var location = LocationService.shared
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \RecentEntry.date, order: .reverse) private var recents: [RecentEntry]
    @Query private var saved: [SavedPlace]

    @State private var query = ""
    @State private var suggestions: [Suggestion] = []
    @State private var results: [Place] = []
    @State private var loading = false
    @State private var error: String?

    private var center: CLLocationCoordinate2D { location.coordinate ?? app.map.viewport.center }
    private var isPicking: Bool { purpose != .browse }

    var body: some View {
        List {
            Section {
                TextField(prompt, text: $query)
                    .textContentType(.fullStreetAddress)
                    .submitLabel(.search)
                    .onSubmit { Task { await runSearch(query) } }
                    .accessibilityLabel("Search Google Maps")
            }

            if loading {
                HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear)
            }
            if let error {
                Label(error, systemImage: "wifi.exclamationmark").font(.footnote).foregroundStyle(.secondary)
            }

            if !results.isEmpty {
                Section("Results") {
                    ForEach(results) { p in
                        Button { pick(p) } label: { PlaceRow(place: p) }
                    }
                }
            } else if !query.isEmpty && !suggestions.isEmpty {
                Section {
                    ForEach(suggestions) { s in
                        Button { Task { await choose(s) } } label: { suggestionRow(s) }
                    }
                }
            } else if query.isEmpty {
                if !isPicking { categories }
                if !isPicking { shortcuts }
                recentSection
            }
        }
        .navigationTitle(title)
        .task(id: query) {
            results = []
            guard query.count >= 2 else { suggestions = []; return }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            suggestions = (try? await GoogleSearch.suggest(query, near: center)) ?? []
        }
    }

    private var title: String {
        switch purpose {
        case .browse: "Search"
        case .setHome: "Set home"
        case .setWork: "Set work"
        case .addToList(let l): "Add to \(l.title)"
        }
    }

    private var prompt: String {
        switch purpose {
        case .setHome: "Home address"
        case .setWork: "Work address"
        default: "Search here"
        }
    }

    private func suggestionRow(_ s: Suggestion) -> some View {
        HStack(spacing: 8) {
            Image(systemName: s.isQuery ? "magnifyingglass" : "mappin.circle.fill")
                .foregroundStyle(s.isQuery ? Color.secondary : Color.red)
            VStack(alignment: .leading, spacing: 1) {
                Text(s.title).font(.body).lineLimit(2)
                if !s.subtitle.isEmpty { Text(s.subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 0)
            if let c = s.coordinate, let loc = location.location {
                Text(Fmt.distance(loc.distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude))))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var categories: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(QuickCategory.all) { c in
                        Button { Task { await runSearch(c.query, title: c.title) } } label: {
                            Label(c.title, systemImage: c.symbol)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(c.color.opacity(0.22), in: Capsule())
                                .foregroundStyle(.primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        }
    }

    @ViewBuilder
    private var shortcuts: some View {
        let home = saved.first { $0.list == .home }?.place
        let work = saved.first { $0.list == .work }?.place
        Section {
            Button { home.map { app.open(.directions($0, nil)) } ?? app.open(.search(.setHome)) } label: {
                Label { Text(home == nil ? "Set home" : "Home") } icon: { Image(systemName: "house.fill").foregroundStyle(Brand.blue) }
            }
            Button { work.map { app.open(.directions($0, nil)) } ?? app.open(.search(.setWork)) } label: {
                Label { Text(work == nil ? "Set work" : "Work") } icon: { Image(systemName: "briefcase.fill").foregroundStyle(Brand.blue) }
            }
        }
    }

    @ViewBuilder
    private var recentSection: some View {
        let items = Array(recents.prefix(12))
        if !items.isEmpty {
            Section("Recent") {
                ForEach(items) { r in
                    if let p = r.place {
                        Button { pick(p) } label: {
                            Label { VStack(alignment: .leading) { Text(p.name).lineLimit(1); Text(p.subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1) } }
                                icon: { Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary) }
                        }
                    } else if let q = r.query {
                        Button { query = q; Task { await runSearch(q) } } label: {
                            Label(q, systemImage: "magnifyingglass")
                        }
                    }
                }
                .onDelete { idx in idx.map { items[$0] }.forEach(context.delete); try? context.save() }
            }
        }
    }

    // MARK: - Actions

    private func runSearch(_ q: String, title: String? = nil) async {
        let q = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        loading = true; error = nil
        defer { loading = false }
        do {
            let span = app.map.viewport.zoom > 13 ? Mercator.metersPerPoint(latitude: center.latitude, zoom: app.map.viewport.zoom) * 400 : 8000
            let places = try await GoogleSearch.search(q, near: location.coordinate ?? app.map.viewport.center, spanMeters: max(3000, min(span, 40000)))
            if title == nil { Library.addRecent(query: q, context: context) }
            if places.isEmpty { error = "No results for “\(q)”"; return }
            if isPicking {
                results = places
            } else if places.count == 1 {
                Library.addRecent(places[0], context: context)
                app.open(.place(places[0]))
            } else {
                app.show(results: places, title: title ?? q)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func choose(_ s: Suggestion) async {
        if s.isQuery { query = s.title; await runSearch(s.title); return }
        loading = true
        defer { loading = false }
        if let place = try? await GoogleSearch.resolve(s, near: center) {
            pick(place)
        } else if let c = s.coordinate {
            pick(Place(name: s.title, subtitle: s.subtitle, fullAddress: s.subtitle, coordinate: c))
        }
    }

    private func pick(_ place: Place) {
        switch purpose {
        case .browse:
            Library.addRecent(place, context: context)
            app.open(.place(place))
        case .setHome:
            Library.toggle(place, in: .home, context: context)
            Guidance.shared.tap(.arrive)
            dismiss()
        case .setWork:
            Library.toggle(place, in: .work, context: context)
            Guidance.shared.tap(.arrive)
            dismiss()
        case .addToList(let list):
            if !Library.lists(containing: place, in: context).contains(list) { Library.toggle(place, in: list, context: context) }
            Guidance.shared.tap(.arrive)
            dismiss()
        }
    }
}

struct ResultsListView: View {
    let title: String
    @State private var app = AppModel.shared
    @State private var sort = 0

    private func chip(_ label: String, _ symbol: String, _ tag: Int) -> some View {
        Button {
            withAnimation(.snappy) { sort = tag }
            Guidance.shared.tap(.select)
        } label: {
            Label(label, systemImage: symbol)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(sort == tag ? AnyShapeStyle(Brand.blue) : AnyShapeStyle(.white.opacity(0.14)), in: Capsule())
                .foregroundStyle(sort == tag ? .white : .primary)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(sort == tag ? .isSelected : [])
    }

    private var sorted: [Place] {
        let loc = LocationService.shared.location
        switch sort {
        case 1: return app.results.sorted { ($0.distance(from: loc) ?? 0) < ($1.distance(from: loc) ?? 0) }
        case 2: return app.results.sorted { ($0.rating ?? 0) > ($1.rating ?? 0) }
        case 3: return app.results.filter { $0.isOpenNow == true }
        default: return app.results
        }
    }

    var body: some View {
        List {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        chip("Relevance", "sparkles", 0)
                        chip("Nearest", "location.fill", 1)
                        chip("Top rated", "star.fill", 2)
                        chip("Open now", "clock.fill", 3)
                    }
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            if sorted.isEmpty {
                Text("Nothing open right now").font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(sorted) { p in
                Button { app.open(.place(p)) } label: { PlaceRow(place: p) }
                    .swipeActions(edge: .trailing) {
                        Button { app.open(.directions(p, nil)) } label: { Image(systemName: "arrow.triangle.turn.up.right.diamond.fill") }
                            .tint(Brand.blue)
                    }
            }
            Section {
                Button {
                    if let i = app.results.firstIndex(where: { $0.id == sorted.first?.id }) { app.selectResult(i) }
                    app.path.removeAll()
                } label: {
                    Label("Show on map", systemImage: "map.fill")
                }
            }
        }
        .navigationTitle(title)
    }
}

/// Google's "Explore" tab: nearby categories.
struct ExploreCategoriesView: View {
    @State private var app = AppModel.shared
    @State private var loading: String?
    private let columns = [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(QuickCategory.all) { c in
                    Button { Task { await search(c) } } label: {
                        VStack(spacing: 4) {
                            if loading == c.id { ProgressView().frame(height: 22) } else {
                                Image(systemName: c.symbol).font(.title3).foregroundStyle(c.color)
                            }
                            Text(c.title).font(.caption2.weight(.medium)).lineLimit(1).minimumScaleFactor(0.7)
                        }
                        .frame(maxWidth: .infinity, minHeight: 58)
                        .background(c.color.opacity(0.16), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 2)
        }
        .navigationTitle("Explore nearby")
    }

    private func search(_ c: QuickCategory) async {
        loading = c.id
        defer { loading = nil }
        let center = await LocationService.shared.currentLocation(timeout: 3)?.coordinate ?? app.map.viewport.center
        if let places = try? await GoogleSearch.search(c.query, near: center, spanMeters: 5000), !places.isEmpty {
            app.show(results: places, title: c.title)
        }
    }
}
