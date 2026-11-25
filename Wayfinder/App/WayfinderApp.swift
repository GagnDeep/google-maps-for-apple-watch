import SwiftUI
import SwiftData
import UserNotifications

@main
struct WayfinderApp: App {
    let container: ModelContainer

    init() {
        AppDefaults.register()
        do {
            container = try ModelContainer(for: SavedPlace.self, RecentEntry.self, ParkingSpot.self, Trip.self)
        } catch {
            container = try! ModelContainer(for: SavedPlace.self, RecentEntry.self, ParkingSpot.self, Trip.self,
                                            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        }
        NavigationEngine.shared.modelContext = container.mainContext
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .onOpenURL { AppModel.shared.handle(url: $0) }
        }
        .modelContainer(container)
    }
}

final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = NotificationDelegate()
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
