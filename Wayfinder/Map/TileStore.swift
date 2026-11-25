import SwiftUI
import UIKit
import Observation

struct TileKey: Hashable {
    let x: Int, y: Int, z: Int, layer: String
}

/// Fetches and caches Google map tiles. Memory LRU of decoded images + a 120 MB disk cache, so places
/// you've browsed keep rendering offline (like Google's offline areas, but automatic).
@MainActor
@Observable
final class TileStore {
    static let shared = TileStore()

    private(set) var revision = 0
    @ObservationIgnored private var images: [TileKey: UIImage] = [:]
    @ObservationIgnored private var order: [TileKey] = []
    @ObservationIgnored private var inFlight: Set<TileKey> = []
    @ObservationIgnored private var failed: [TileKey: Date] = [:]
    @ObservationIgnored private let limit = 56
    /// Each map on screen (explore, navigation, mini maps) keeps its own queue so one can't starve another.
    @ObservationIgnored private var queues: [ObjectIdentifier: [(TileKey, TileLayer)]] = [:]
    @ObservationIgnored private var lastClient: ObjectIdentifier?
    @ObservationIgnored private var active = 0
    @ObservationIgnored private let maxConcurrent = 6

    @ObservationIgnored private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.urlCache = URLCache(memoryCapacity: 2 << 20, diskCapacity: 120 << 20,
                              directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("tiles"))
        c.requestCachePolicy = .returnCacheDataElseLoad
        c.httpAdditionalHeaders = ["User-Agent": GoogleClient.userAgent, "Referer": "https://www.google.com/maps"]
        c.timeoutIntervalForRequest = 15
        c.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: c)
    }()

    func image(_ key: TileKey) -> UIImage? {
        images[key]
    }

    /// Queues the visible tiles (nearest-first) and drops stale queued requests.
    func request(_ keys: [TileKey], layer: TileLayer, client: ObjectIdentifier) {
        let wanted = keys.filter { images[$0] == nil && !inFlight.contains($0) && (failed[$0].map { Date().timeIntervalSince($0) > 8 } ?? true) }
        queues[client] = wanted.isEmpty ? nil : wanted.map { ($0, layer) }
        pump()
    }

    /// Next queued tile, taking turns between maps (newest request first within a map).
    private func nextPending() -> (TileKey, TileLayer)? {
        let clients = queues.keys.sorted { $0.hashValue < $1.hashValue }
        guard !clients.isEmpty else { return nil }
        let start = lastClient.flatMap { c in clients.firstIndex(of: c).map { $0 + 1 } } ?? 0
        for i in 0..<clients.count {
            let c = clients[(start + i) % clients.count]
            guard var q = queues[c], !q.isEmpty else { queues[c] = nil; continue }
            let item = q.removeFirst()
            queues[c] = q.isEmpty ? nil : q
            lastClient = c
            return item
        }
        return nil
    }

    private func pump() {
        while active < maxConcurrent, let (key, layer) = nextPending() {
            guard images[key] == nil, !inFlight.contains(key) else { continue }
            inFlight.insert(key)
            active += 1
            let url = layer.url(x: key.x, y: key.y, z: key.z)
            Task { [weak self] in
                let image = await Self.download(url, session: self?.session)
                guard let self else { return }
                self.inFlight.remove(key)
                self.active -= 1
                if let image {
                    self.insert(image, for: key)
                } else {
                    self.failed[key] = Date()
                }
                self.pump()
            }
        }
    }

    nonisolated private static func download(_ url: URL, session: URLSession?) async -> UIImage? {
        guard let session else { return nil }
        do {
            let (data, resp) = try await session.data(from: url)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            guard code == 200 else { return nil }
            return UIImage(data: data)
        } catch { return nil }
    }

    private func insert(_ image: UIImage, for key: TileKey) {
        images[key] = image
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > limit {
            let old = order.removeFirst()
            images[old] = nil
        }
        revision &+= 1
    }

    func touch(_ key: TileKey) {
        guard images[key] != nil, let i = order.firstIndex(of: key), i < order.count - 12 else { return }
        order.remove(at: i)
        order.append(key)
    }

    func clearDisk() {
        session.configuration.urlCache?.removeAllCachedResponses()
        purgeMemory()
    }

    func purgeMemory() {
        images.removeAll(); order.removeAll(); revision &+= 1
    }
}
