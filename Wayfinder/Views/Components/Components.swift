import SwiftUI
import SwiftData
import CoreLocation

/// Google-style star rating: "4.6 ★★★★½ (1,204)".
struct RatingView: View {
    let rating: Double
    var count: Int?
    var compact = false

    var body: some View {
        HStack(spacing: 2) {
            Text(rating, format: .number.precision(.fractionLength(1)))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.primary)
            if !compact {
                ForEach(0..<5, id: \.self) { i in
                    Image(systemName: Double(i) + 0.75 <= rating ? "star.fill" : Double(i) + 0.25 <= rating ? "star.leadinghalf.filled" : "star")
                        .font(.system(size: 8))
                        .foregroundStyle(Brand.star)
                }
            } else {
                Image(systemName: "star.fill").font(.system(size: 8)).foregroundStyle(Brand.star)
            }
            if let count {
                Text("(\(count.formatted(.number.notation(.compactName))))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Rated \(rating, specifier: "%.1f") out of 5\(count.map { " from \($0) reviews" } ?? "")")
    }
}

struct OpenStatusText: View {
    let place: Place
    var body: some View {
        if let status = place.openStatus {
            let parts = status.components(separatedBy: " · ")
            let head = Text(parts[0]).foregroundStyle(place.isOpenNow == true ? Brand.etaGreen : place.isOpenNow == false ? Color.red : Color.secondary)
            let tail = Text(parts.count > 1 ? " · " + parts.dropFirst().joined(separator: " · ") : "").foregroundStyle(Color.secondary)
            Text("\(head)\(tail)")
                .font(.caption2)
                .lineLimit(1)
        }
    }
}

struct CategoryBadge: View {
    let category: PlaceCategory
    var size: CGFloat = 26
    var body: some View {
        Image(systemName: category.symbol)
            .font(.system(size: size * 0.48, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(category.color.gradient, in: Circle())
            .accessibilityHidden(true)
    }
}

struct PlaceRow: View {
    let place: Place
    var showsDistance = true
    @State private var location = LocationService.shared

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            CategoryBadge(category: place.category)
            VStack(alignment: .leading, spacing: 1) {
                Text(place.name)
                    .font(.headline)
                    .lineLimit(2)
                if let r = place.rating {
                    RatingView(rating: r, count: place.reviewCount, compact: true)
                }
                HStack(spacing: 4) {
                    if showsDistance, let d = place.distance(from: location.location) {
                        Text(Fmt.distance(d)).foregroundStyle(.secondary)
                    }
                    if let cat = place.primaryCategory {
                        Text(cat).foregroundStyle(.secondary).lineLimit(1)
                    } else if !place.subtitle.isEmpty {
                        Text(place.subtitle).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .font(.caption2)
                OpenStatusText(place: place)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

struct PillButton: View {
    let title: String
    let symbol: String
    var tint: Color = Brand.blue
    var filled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .foregroundStyle(filled ? .white : tint)
                .background(filled ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(tint.opacity(0.18)), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct RoundAction: View {
    let title: String
    let symbol: String
    var tint: Color = Brand.blue
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .background(tint.opacity(0.2), in: Circle())
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(size: 10))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

/// Persistence helpers shared by several screens.
@MainActor
enum Library {
    static func saved(_ list: SavedList, in context: ModelContext) -> [SavedPlace] {
        let raw = list.rawValue
        let d = FetchDescriptor<SavedPlace>(predicate: #Predicate { $0.listRaw == raw }, sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        return (try? context.fetch(d)) ?? []
    }

    static func lists(containing place: Place, in context: ModelContext) -> Set<SavedList> {
        let all = (try? context.fetch(FetchDescriptor<SavedPlace>())) ?? []
        return Set(all.filter { $0.place?.id == place.id }.map(\.list))
    }

    static func toggle(_ place: Place, in list: SavedList, context: ModelContext) {
        let existing = saved(list, in: context)
        if list.isSingleton {
            existing.forEach { context.delete($0) }
            context.insert(SavedPlace(place: place, list: list))
        } else if let hit = existing.first(where: { $0.place?.id == place.id }) {
            context.delete(hit)
        } else {
            context.insert(SavedPlace(place: place, list: list))
        }
        try? context.save()
    }

    static func home(_ context: ModelContext) -> Place? { saved(.home, in: context).first?.place }
    static func work(_ context: ModelContext) -> Place? { saved(.work, in: context).first?.place }

    static func addRecent(_ place: Place, context: ModelContext) {
        let all = (try? context.fetch(FetchDescriptor<RecentEntry>(sortBy: [SortDescriptor(\.date, order: .reverse)]))) ?? []
        all.filter { $0.place?.id == place.id }.forEach { context.delete($0) }
        context.insert(RecentEntry(place: place))
        all.dropFirst(30).forEach { context.delete($0) }
        try? context.save()
    }

    static func addRecent(query: String, context: ModelContext) {
        let all = (try? context.fetch(FetchDescriptor<RecentEntry>(sortBy: [SortDescriptor(\.date, order: .reverse)]))) ?? []
        all.filter { $0.query?.caseInsensitiveCompare(query) == .orderedSame }.forEach { context.delete($0) }
        context.insert(RecentEntry(query: query))
        try? context.save()
    }

    static func parking(_ context: ModelContext) -> ParkingSpot? {
        try? context.fetch(FetchDescriptor<ParkingSpot>(sortBy: [SortDescriptor(\.date, order: .reverse)])).first
    }

    static func saveParking(at c: CLLocationCoordinate2D, context: ModelContext) async -> ParkingSpot {
        ((try? context.fetch(FetchDescriptor<ParkingSpot>())) ?? []).forEach { context.delete($0) }
        let spot = ParkingSpot(coordinate: c, address: nil)
        context.insert(spot)
        try? context.save()
        if let addr = await GoogleDirections.reverseAddress(c) {
            spot.address = addr
            try? context.save()
        }
        return spot
    }
}

extension View {
    /// Standard material card used across list screens.
    func card(_ color: Color = Color.white.opacity(0.08)) -> some View {
        padding(8).background(color, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
