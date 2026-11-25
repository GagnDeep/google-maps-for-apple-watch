import SwiftUI
import SwiftData
import CoreLocation

/// Turn-by-turn, Apple Watch style: three pages on the Digital Crown.
///   1. Map — maneuver banner pinned to the top edge, heading-up map, ETA bar with a one-tap voice toggle.
///   2. Steps — every upcoming turn, the next one highlighted.
///   3. Controls — big tiles: voice, wrist taps, overview, north-up, repeat, share ETA, end route.
struct NavigationScreen: View {
    @State private var nav = NavigationEngine.shared
    @State private var page = 0

    var body: some View {
        Group {
            if nav.phase == .arrived {
                ArrivalView()
            } else {
                TabView(selection: $page) {
                    NavMapPage(page: $page).tag(0)
                    NavStepsPage().tag(1)
                    NavControlsPage(page: $page).tag(2)
                }
                .tabViewStyle(.verticalPage(transitionStyle: .blur))
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .persistentSystemOverlays(.hidden)
        .onChange(of: page) { _, _ in Guidance.shared.tap(.select) }
    }
}

// MARK: - Page 1: map

struct NavMapPage: View {
    @Binding var page: Int
    @State private var nav = NavigationEngine.shared
    @State private var location = LocationService.shared
    @State private var map = MapController(zoom: 17)
    @AppStorage(SettingsKey.navNorthUp) private var northUp = false
    @AppStorage(SettingsKey.showSpeedometer) private var showSpeed = true
    @AppStorage(SettingsKey.voiceMode) private var voiceRaw = VoiceMode.on.rawValue
    @State private var toast: String?

    private var voice: VoiceMode { VoiceMode(rawValue: voiceRaw) ?? .on }

    private var layer: TileLayer {
        var l = TileLayer.saved
        if nav.mode.isVehicle { l.traffic = true }
        return l
    }

    var body: some View {
        ZStack(alignment: .top) {
            GoogleMapView(controller: map, layer: layer, pins: pins, lines: lines, puck: puck,
                          interactive: false, crownZoom: false, showsAttribution: false)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    nav.overview.toggle()
                    Guidance.shared.tap(.select)
                    flash(nav.overview ? "Route overview" : "Following you")
                }
                .accessibilityLabel(nav.overview ? "Route overview. Double tap to follow your position." : "Map. Double tap for route overview.")

            VStack(spacing: 0) {
                ManeuverBanner()
                if let toast {
                    Text(toast)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(.black.opacity(0.78), in: Capsule())
                        .padding(.top, 5)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
                Spacer(minLength: 0)
                etaBar
            }
            .ignoresSafeArea()
        }
        .onAppear {
            map.follow = .followHeading
            if let c = nav.snapped ?? location.coordinate { map.set(Viewport(center: c, zoom: nav.mode.navZoom)) }
            followCamera(animated: false)
            if voice != .on { flash(voice == .muted ? "Voice muted" : "Voice: alerts only") }
        }
        .onChange(of: nav.snapped?.latitude) { _, _ in followCamera() }
        .onChange(of: location.location) { _, _ in if nav.snapped == nil { followCamera() } }
        .onChange(of: nav.course) { _, _ in followCamera() }
        .onChange(of: nav.overview) { _, _ in followCamera() }
        .onChange(of: northUp) { _, _ in followCamera() }
    }

    // MARK: Camera

    private func followCamera(animated: Bool = true) {
        if nav.overview, let r = nav.route, !r.coordinates.isEmpty {
            let from = r.cumulative.firstIndex { $0 >= nav.progress } ?? 0
            var remaining = Array(r.coordinates[min(from, r.coordinates.count - 1)...])
            if let s = nav.snapped { remaining.append(s) }
            map.fit(remaining, padding: 34, maxZoom: 17, animated: animated)
            return
        }
        guard let c = nav.snapped ?? location.coordinate else { return }
        let heading = northUp ? 0 : nav.course
        // Puck sits in the lower third so the road ahead fills the screen.
        let v = Viewport(center: c, zoom: zoomForSpeed(), heading: heading)
            .panned(by: CGSize(width: 0, height: map.size.height * 0.2))
        animated ? map.fly(to: v, duration: 0.9) : map.set(v)
    }

    private func zoomForSpeed() -> Double {
        let base = nav.mode.navZoom
        guard nav.mode.isVehicle else { return base }
        if nav.distanceToNext < 160 { return base + 0.5 }
        switch nav.speed {
        case 25...: return base - 1.3
        case 15...: return base - 0.7
        default: return base
        }
    }

    // MARK: Map content

    private var lines: [MapLine] {
        guard let r = nav.route, nav.mode != .transit else {
            if let d = nav.destination, let c = location.coordinate {
                return [MapLine(id: "direct", coordinates: [c, d.coordinate], color: Brand.blue, outline: nil, width: 4, dashed: true)]
            }
            return []
        }
        return [MapLine(id: "route-\(r.id)", coordinates: r.coordinates, color: Brand.blue, outline: Brand.routeOutline,
                        width: nav.mode.isVehicle ? 7 : 5, dashed: nav.mode == .walking,
                        travelledMeters: nav.progress, cumulative: r.cumulative)]
    }

    private var pins: [MapPin] {
        var out: [MapPin] = []
        if let d = nav.destination { out.append(MapPin(id: "dest", coordinate: d.coordinate, style: .end)) }
        if let step = nav.nextStep, step.maneuver != .arrive {
            out.append(MapPin(id: "turn", coordinate: step.location, style: .dot(.white)))
        }
        return out
    }

    private var puck: UserPuck? {
        guard let c = nav.snapped ?? location.coordinate else { return nil }
        return UserPuck(coordinate: c, heading: nav.course, accuracy: location.location?.horizontalAccuracy ?? 10, navigation: true)
    }

    // MARK: ETA bar

    private var etaBar: some View {
        HStack(spacing: 6) {
            Button {
                let next = voice.next
                voiceRaw = next.rawValue
                if next == .muted { Guidance.shared.stopSpeaking() }
                Guidance.shared.tap(next == .muted ? .toggleOff : .toggleOn)
                flash(next.label)
            } label: {
                Image(systemName: voice.symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(voice == .muted ? .red : .white)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 36, height: 36)
                    .background(.white.opacity(0.18), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Voice: \(voice.label). Double tap to change.")

            Button { page = 1 } label: {
                VStack(spacing: 0) {
                    Text(Fmt.duration(nav.remainingTime))
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(nav.route?.trafficColor ?? Brand.etaGreen)
                        .contentTransition(.numericText())
                        .lineLimit(1).minimumScaleFactor(0.7)
                    Text("\(Fmt.distance(nav.remainingDistance)) · \(Fmt.clock(nav.eta))")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(Fmt.duration(nav.remainingTime)) remaining, \(Fmt.distance(nav.remainingDistance)), arriving \(Fmt.clock(nav.eta))")
            .accessibilityHint("Shows upcoming steps")

            if showSpeed && nav.mode.isVehicle && nav.speed > 0.5 {
                let s = Fmt.speed(nav.speed)
                Button { page = 2 } label: {
                    VStack(spacing: -3) {
                        Text(s.value).font(.system(size: 14, weight: .bold, design: .rounded)).contentTransition(.numericText())
                        Text(s.unit).font(.system(size: 7, weight: .medium))
                    }
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(.white))
                    .foregroundStyle(.black)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Speed \(s.value) \(s.unit). Double tap for controls.")
            } else {
                Button { page = 2 } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14, weight: .bold))
                        .frame(width: 36, height: 36)
                        .background(.white.opacity(0.18), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Navigation controls")
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity)
        .background(LinearGradient(colors: [.black.opacity(0), .black.opacity(0.85), .black], startPoint: .top, endPoint: .bottom))
        .overlay(alignment: .top) {
            Image(systemName: "chevron.compact.down")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white.opacity(0.45))
                .padding(.top, 1)
                .accessibilityHidden(true)
        }
    }

    private func flash(_ text: String) {
        withAnimation(.snappy) { toast = text }
        Task {
            try? await Task.sleep(for: .seconds(1.4))
            withAnimation(.easeOut) { if toast == text { toast = nil } }
        }
    }
}

/// The maneuver banner, flush with the top edge of the display (Google's green card).
struct ManeuverBanner: View {
    @State private var nav = NavigationEngine.shared
    /// Collapsed by default: a small chip in the corner that keeps the map clear. Tap to expand.
    @State private var collapsed = true

    var body: some View {
        Group {
            if collapsed { compact } else { expanded }
        }
        .animation(.snappy(duration: 0.3), value: collapsed)
    }

    private func toggle() {
        collapsed.toggle()
        Guidance.shared.tap(.select)
        if !collapsed { nav.repeatInstruction() }
    }

    /// Small chip in the top-left corner: turn arrow + distance.
    private var compact: some View {
        HStack {
            Button(action: toggle) {
                HStack(spacing: 4) {
                    if nav.phase == .rerouting {
                        ProgressView().tint(.white).scaleEffect(0.7).frame(width: 20, height: 20)
                    } else if let step = nav.nextStep {
                        Image(systemName: step.maneuver.symbol)
                            .font(.system(size: 17, weight: .bold))
                            .symbolEffect(.pulse, isActive: nav.distanceToNext < nav.mode.nowDistance * 2)
                        Text(nav.mode == .transit ? Fmt.distance(nav.remainingDistance) : Fmt.distance(nav.distanceToNext))
                            .font(.system(size: 14, weight: .heavy, design: .rounded))
                            .contentTransition(.numericText())
                            .lineLimit(1)
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background((nav.phase == .rerouting ? Brand.traffic : Brand.navGreen).gradient, in: Capsule())
                .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(nav.nextStep.map { "In \(Fmt.spokenDistance(nav.distanceToNext)), \($0.instruction)" } ?? "Rerouting")
            .accessibilityHint("Double tap to expand directions")
            Spacer(minLength: 0)
        }
        .padding(.leading, 14)
        .padding(.top, 10)
        .transition(.scale(scale: 0.6, anchor: .topLeading).combined(with: .opacity))
    }

    private var expanded: some View {
        Group {
            if nav.phase == .rerouting {
                HStack(spacing: 8) {
                    ProgressView().tint(.white)
                    Text("Rerouting…").font(.headline)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.top, 22).padding(.bottom, 10)
                .frame(maxWidth: .infinity)
                .background(Brand.traffic.gradient)
            } else if let step = nav.nextStep {
                Button(action: toggle) {
                    VStack(spacing: 0) {
                        HStack(alignment: .center, spacing: 8) {
                            Image(systemName: step.maneuver.symbol)
                                .font(.system(size: 30, weight: .bold))
                                .frame(width: 38)
                                .symbolEffect(.pulse, isActive: nav.distanceToNext < nav.mode.nowDistance * 2)
                            VStack(alignment: .leading, spacing: -1) {
                                Text(nav.mode == .transit ? Fmt.distance(nav.remainingDistance) : Fmt.distance(nav.distanceToNext))
                                    .font(.system(size: 22, weight: .heavy, design: .rounded))
                                    .contentTransition(.numericText())
                                    .lineLimit(1).minimumScaleFactor(0.7)
                                Text(primaryText(step))
                                    .font(.system(size: 13, weight: .semibold))
                                    .lineLimit(2)
                                    .minimumScaleFactor(0.75)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.leading, 12).padding(.trailing, 10)
                        .padding(.top, 20)   // clears the rounded top corners of the display
                        .padding(.bottom, 7)
                        if let then = nav.thenStep {
                            HStack(spacing: 5) {
                                Text("Then").font(.system(size: 11, weight: .semibold))
                                Image(systemName: then.maneuver.symbol).font(.system(size: 12, weight: .bold))
                                Spacer()
                            }
                            .padding(.horizontal, 16).padding(.vertical, 3)
                            .background(Color.black.opacity(0.28))
                        }
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .background(Brand.navGreen.gradient)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("In \(Fmt.spokenDistance(nav.distanceToNext)), \(step.instruction)")
                .accessibilityHint("Double tap to collapse")
            }
        }
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 18, bottomTrailingRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
        .onTapGesture(perform: toggle)   // also collapses from the rerouting state
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    /// Long Google instructions keep the meaningful tail ("Clay St") readable on a small screen.
    private func primaryText(_ s: RouteStep) -> String {
        let t = s.instruction
        guard t.count > 34 else { return t }
        for marker in [" onto ", " toward ", " at "] {
            if let r = t.range(of: marker) {
                let verb = t[..<r.lowerBound].replacingOccurrences(of: "Turn ", with: "")
                return "\(verb.prefix(1).uppercased() + verb.dropFirst()) · \(t[r.upperBound...])"
            }
        }
        return t
    }
}

// MARK: - Page 2: steps

struct NavStepsPage: View {
    @State private var nav = NavigationEngine.shared

    private var upcoming: [RouteStep] {
        guard let r = nav.route else { return [] }
        return r.steps.filter { $0.id >= max(0, nav.nextStepIndex) }
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                HStack {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(Fmt.duration(nav.remainingTime)).font(.headline).foregroundStyle(nav.route?.trafficColor ?? Brand.etaGreen)
                        Text("\(Fmt.distance(nav.remainingDistance)) · \(Fmt.clock(nav.eta))").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 54)   // the clock lives top-right
                }
                .listRowBackground(Color.clear)
                ForEach(upcoming) { s in
                    let isNext = s.id == nav.nextStepIndex
                    HStack(alignment: .center, spacing: 10) {
                        Image(systemName: s.maneuver.symbol)
                            .font(.system(size: isNext ? 22 : 17, weight: .bold))
                            .frame(width: 30)
                            .foregroundStyle(isNext ? .white : (s.maneuver == .arrive ? .red : Brand.blue))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(Fmt.distance(max(0, s.startOffset - nav.progress)))
                                .font(.system(size: isNext ? 17 : 14, weight: .bold, design: .rounded))
                            Text(s.instruction).font(.footnote).lineLimit(3)
                        }
                    }
                    .padding(.vertical, 3)
                    .listRowBackground(isNext ? RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Brand.navGreen) : nil)
                    .id(s.id)
                    .accessibilityElement(children: .combine)
                }
            }
            .contentMargins(.top, 26, for: .scrollContent)
            .onAppear { proxy.scrollTo(nav.nextStepIndex, anchor: .top) }
        }
    }
}

// MARK: - Page 3: controls

struct NavControlsPage: View {
    @Binding var page: Int
    @State private var nav = NavigationEngine.shared
    @AppStorage(SettingsKey.voiceMode) private var voiceRaw = VoiceMode.on.rawValue
    @AppStorage(SettingsKey.hapticLevel) private var hapticRaw = HapticLevel.all.rawValue
    @AppStorage(SettingsKey.navNorthUp) private var northUp = false
    @State private var confirmEnd = false

    private let cols = [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)]

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Text(nav.destination.map { "To \($0.name)" } ?? "Navigation")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 4)
                LazyVGrid(columns: cols, spacing: 6) {
                    let voice = VoiceMode(rawValue: voiceRaw) ?? .on
                    tile(voice.label, voice.symbol, voice == .muted ? .red : Brand.blue, on: voice != .muted) {
                        voiceRaw = voice.next.rawValue
                        if voice.next == .muted { Guidance.shared.stopSpeaking() }
                        Guidance.shared.tap(voice.next == .muted ? .toggleOff : .toggleOn)
                    }
                    let haptic = HapticLevel(rawValue: hapticRaw) ?? .all
                    tile(haptic.label, haptic.symbol, haptic == .off ? .red : .orange, on: haptic != .off) {
                        let all = HapticLevel.allCases
                        let next = all[((all.firstIndex(of: haptic) ?? 0) + 1) % all.count]
                        hapticRaw = next.rawValue
                        Guidance.shared.tap(.right)   // preview the turn pattern at the new level
                    }
                    tile(nav.overview ? "Follow me" : "Overview", nav.overview ? "location.north.line.fill" : "map.fill", .teal, on: nav.overview) {
                        nav.overview.toggle()
                        Guidance.shared.tap(.select)
                        page = 0
                    }
                    tile(northUp ? "North up" : "Heading up", northUp ? "location.north.circle.fill" : "location.north.line.fill", .indigo, on: northUp) {
                        northUp.toggle()
                        Guidance.shared.tap(.select)
                    }
                    tile("Repeat", "arrow.counterclockwise", .green, on: false) {
                        nav.repeatInstruction()
                        page = 0
                    }
                    if let d = nav.destination {
                        ShareLink(item: d.directionsShareURL,
                                  message: Text("On my way to \(d.name), arriving around \(Fmt.clock(nav.eta))")) {
                            tileLabel("Share ETA", "square.and.arrow.up", .pink, on: false)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Button { confirmEnd = true } label: {
                    Label("End route", systemImage: "xmark")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.red.gradient, in: Capsule())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .confirmationDialog("End navigation?", isPresented: $confirmEnd) {
                    Button("End route", role: .destructive) {
                        Guidance.shared.tap(.end)
                        nav.stop()
                    }
                }
            }
        }
        .contentMargins(.top, 26, for: .scrollContent)
    }

    private func tile(_ title: String, _ symbol: String, _ tint: Color, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { tileLabel(title, symbol, tint, on: on) }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func tileLabel(_ title: String, _ symbol: String, _ tint: Color, on: Bool) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(on ? .white : tint)
                .contentTransition(.symbolEffect(.replace))
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, minHeight: 56)
        .background(on ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(tint.opacity(0.2)),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - Arrival

struct ArrivalView: View {
    @State private var nav = NavigationEngine.shared
    @Environment(\.modelContext) private var context
    @AppStorage(SettingsKey.askToSaveParking) private var askParking = true
    @State private var parkingSaved = false

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Image(systemName: "flag.checkered.circle.fill")
                    .font(.system(size: 46))
                    .foregroundStyle(Brand.etaGreen)
                    .symbolEffect(.bounce, options: .nonRepeating)
                Text("You've arrived").font(.title3.weight(.semibold))
                if let d = nav.destination {
                    Text(d.name).font(.headline).multilineTextAlignment(.center)
                    if !d.subtitle.isEmpty { Text(d.subtitle).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center) }
                }
                if let s = nav.startedAt {
                    HStack {
                        stat(Fmt.duration(Date().timeIntervalSince(s)), "Trip time")
                        stat(Fmt.distance(nav.travelledDistance > 0 ? nav.travelledDistance : (nav.route?.distance ?? 0)), "Distance")
                    }
                }
                if nav.mode.isVehicle && askParking {
                    Button {
                        Task {
                            if let c = LocationService.shared.coordinate {
                                _ = await Library.saveParking(at: c, context: context)
                                parkingSaved = true
                                Guidance.shared.tap(.toggleOn)
                            }
                        }
                    } label: {
                        Label(parkingSaved ? "Parking saved" : "Save parking", systemImage: parkingSaved ? "checkmark.circle.fill" : "parkingsign.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .tint(Brand.blue)
                    .disabled(parkingSaved)
                }
                Button("Done") { Guidance.shared.tap(.end); nav.stop() }
                    .buttonStyle(.borderedProminent)
                    .tint(Brand.blue)
            }
        }
    }

    private func stat(_ v: String, _ l: String) -> some View {
        VStack(spacing: 1) {
            Text(v).font(.headline)
            Text(l).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
