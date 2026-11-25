import SwiftUI
import SwiftData

struct RootView: View {
    @State private var app = AppModel.shared
    @State private var nav = NavigationEngine.shared
    @State private var location = LocationService.shared
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @State private var resumeTrip: (destination: Place, mode: TravelMode)?
    @State private var resuming = false

    var body: some View {
        NavigationStack(path: $app.path) {
            ExploreView()
                .navigationDestination(for: Screen.self) { screen in
                    destination(screen)
                }
        }
        .fullScreenCover(isPresented: Binding(get: { nav.isActive }, set: { if !$0 { nav.stop() } })) {
            NavigationScreen()
        }
        .task {
            location.start()
            if !nav.isActive, let t = NavigationEngine.interruptedTrip() { resumeTrip = t }
        }
        .sheet(isPresented: Binding(get: { resumeTrip != nil }, set: { if !$0 { resumeTrip = nil } })) {
            if let t = resumeTrip { resumeSheet(t) }
        }
        .onChange(of: app.pending) { _, link in
            guard let link else { return }
            app.pending = nil
            Task { await handle(link) }
        }
        .onChange(of: nav.isActive) { _, active in
            // Like Google: after starting a route, you come back to the map, and the screens
            // underneath stop drawing (their tiles would crowd out the navigation map's).
            if active { app.path.removeAll() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { app.saveMapPosition() }
            if phase == .background, !nav.isActive { TileStore.shared.purgeMemory() }
        }
    }

    private func resumeSheet(_ t: (destination: Place, mode: TravelMode)) -> some View {
        ScrollView {
            VStack(spacing: 10) {
                Image(systemName: t.mode.symbol)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 50, height: 50)
                    .background(Brand.navGreen.gradient, in: Circle())
                Text("Resume route?").font(.headline)
                Text(t.destination.name).font(.subheadline).multilineTextAlignment(.center).lineLimit(2)
                Button {
                    resuming = true
                    Task {
                        let ok = await nav.resume(to: t.destination, mode: t.mode)
                        resuming = false
                        if ok { resumeTrip = nil } else { Guidance.shared.tap(.warning) }
                    }
                } label: {
                    HStack {
                        if resuming { ProgressView().frame(width: 18, height: 18) } else { Image(systemName: "location.north.line.fill") }
                        Text("Resume")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Brand.blue)
                .disabled(resuming)
                Button("Not now") {
                    NavigationEngine.discardInterruptedTrip()
                    resumeTrip = nil
                }
            }
        }
    }

    @ViewBuilder
    private func destination(_ screen: Screen) -> some View {
        switch screen {
        case .search(let purpose): SearchView(purpose: purpose)
        case .results(let title): ResultsListView(title: title)
        case .place(let place): PlaceDetailView(place: place)
        case .directions(let place, let mode): DirectionsView(destination: place, initialMode: mode)
        case .steps(let route): StepsView(route: route)
        case .menu: MenuView()
        case .saved: SavedView()
        case .savedList(let list): SavedListView(list: list)
        case .timeline: TimelineView()
        case .trip(let id): TripDetailView(tripID: id)
        case .parking: ParkingView()
        case .measure: MeasureView()
        case .layers: LayersView()
        case .settings: SettingsView()
        case .go: GoView()
        case .explore: ExploreCategoriesView()
        case .compass(let target): CompassView(target: target)
        }
    }

    private func handle(_ link: DeepLink) async {
        if nav.isActive { return }
        app.path.removeAll()
        switch link {
        case .search: app.open(.search(.browse))
        case .timeline: app.open(.timeline)
        case .go: app.open(.go)
        case .parking: app.open(.parking)
        case .saveParking:
            if let c = await location.currentLocation()?.coordinate {
                _ = await Library.saveParking(at: c, context: context)
                Guidance.shared.tap(.arrive)
            }
            app.open(.parking)
        case .home, .work:
            let place = link == .home ? Library.home(context) : Library.work(context)
            if let place { app.open(.directions(place, nil)) } else { app.open(.search(link == .home ? .setHome : .setWork)) }
        case .nearby(let q):
            guard let c = await location.currentLocation()?.coordinate ?? Optional(app.map.viewport.center) else { return }
            if let results = try? await GoogleSearch.search(q, near: c) {
                app.show(results: results, title: q.capitalized)
            }
        case .navigate(let place):
            app.open(.directions(place, nil))
        }
    }
}

import UserNotifications

enum NotificationsHelper {
    static func requestIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
    }
}
