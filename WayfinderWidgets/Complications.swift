import WidgetKit
import SwiftUI

struct StaticEntry: TimelineEntry { let date: Date }

struct StaticProvider: TimelineProvider {
    func placeholder(in context: Context) -> StaticEntry { .init(date: .now) }
    func getSnapshot(in context: Context, completion: @escaping (StaticEntry) -> Void) { completion(.init(date: .now)) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<StaticEntry>) -> Void) {
        completion(Timeline(entries: [.init(date: .now)], policy: .never))
    }
}

private let mapsBlue = Color(red: 0.10, green: 0.45, blue: 0.91)

/// One launcher complication per Google Maps quick action.
func launcher(kind: String, title: String, symbol: String, tint: Color, url: String, description: String) -> some WidgetConfiguration {
    StaticConfiguration(kind: kind, provider: StaticProvider()) { _ in
        LauncherView(title: title, symbol: symbol, tint: tint)
            .widgetURL(URL(string: url)!)
            .containerBackground(tint.gradient, for: .widget)
    }
    .configurationDisplayName(title)
    .description(description)
    .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryRectangular, .accessoryInline])
}

struct SearchWidget: Widget {
    var body: some WidgetConfiguration { launcher(kind: "search", title: "Search", symbol: "magnifyingglass", tint: mapsBlue, url: "wayfinder://search", description: "Search Google Maps.") }
}
struct HomeWidget: Widget {
    var body: some WidgetConfiguration { launcher(kind: "home", title: "Home", symbol: "house.fill", tint: mapsBlue, url: "wayfinder://home", description: "Directions home with live traffic.") }
}
struct WorkWidget: Widget {
    var body: some WidgetConfiguration { launcher(kind: "work", title: "Work", symbol: "briefcase.fill", tint: mapsBlue, url: "wayfinder://work", description: "Directions to work with live traffic.") }
}
struct ParkingWidget: Widget {
    var body: some WidgetConfiguration { launcher(kind: "parking", title: "Parking", symbol: "parkingsign.circle.fill", tint: mapsBlue, url: "wayfinder://parking", description: "Find your parked car.") }
}
struct FoodWidget: Widget {
    var body: some WidgetConfiguration { launcher(kind: "nearby", title: "Food", symbol: "fork.knife", tint: .orange, url: "wayfinder://nearby?q=restaurants", description: "Restaurants near you.") }
}
struct PetrolWidget: Widget {
    var body: some WidgetConfiguration { launcher(kind: "petrol", title: "Petrol", symbol: "fuelpump.fill", tint: .green, url: "wayfinder://nearby?q=gas%20station", description: "Petrol pumps near you.") }
}

struct LauncherView: View {
    let title: String
    let symbol: String
    let tint: Color
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryCorner:
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .widgetLabel(title)
        case .accessoryRectangular:
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.title3.weight(.semibold))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(tint.opacity(0.35)))
                VStack(alignment: .leading, spacing: 0) {
                    Text("Wayfinder").font(.caption2).foregroundStyle(.secondary)
                    Text(title).font(.headline).widgetAccentable()
                }
                Spacer(minLength: 0)
            }
        case .accessoryInline:
            Label(title, systemImage: symbol)
        default:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: symbol).font(.system(size: 20, weight: .semibold)).widgetAccentable()
            }
        }
    }
}

@main
struct WayfinderWidgets: WidgetBundle {
    var body: some Widget {
        SearchWidget()
        HomeWidget()
        WorkWidget()
        ParkingWidget()
        FoodWidget()
        PetrolWidget()
    }
}
