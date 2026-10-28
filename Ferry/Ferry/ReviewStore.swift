import Foundation
import Observation

// MARK: - Server sync seam

/// How 已看 state will be synced once the server exposes it.
///
/// Today 已看 lives only on the phone (`ferry.local.reviewSeenIDs`), so the
/// shipped implementation is `NoopReviewReadStatusSync`. When the endpoint
/// exists, implement this protocol and assign it to
/// `ReviewStore.readStatusSync` — nothing else in the app changes:
/// `markSeen(_:)` still writes locally and simply drains its pending queue
/// through `pushRead(ids:)` afterwards.
@MainActor
protocol ReviewReadStatusSyncing {
    /// Tell the server these items were read. Return the ids it confirmed so
    /// the local pending queue can drop them (unconfirmed ids stay queued).
    func pushRead(ids: [String]) async -> Set<String>
    /// Ids the server already knows are read (for example read on another
    /// device, or before this phone was paired).
    func pullReadIDs() async -> Set<String>
}

/// Ships today: 已看 never leaves the device.
@MainActor
struct NoopReviewReadStatusSync: ReviewReadStatusSyncing {
    func pushRead(ids: [String]) async -> Set<String> { [] }
    func pullReadIDs() async -> Set<String> { [] }
}

// MARK: - Store

/// The 待查看 list: items parsed out of incoming messages, plus the
/// phone-local 已看 state (deduplicated by item id).
@MainActor @Observable
final class ReviewStore {
    private(set) var items: [ReviewItem] = []
    private(set) var seenIDs: Set<String> = []
    /// Ids marked read here but not yet acknowledged by the server. Drained by
    /// `syncReadStatus()`; with the no-op sync it simply accumulates, which is
    /// exactly the backlog the real endpoint will pick up.
    private(set) var pendingSyncIDs: [String] = []

    /// Seam for the future server sync (see `ReviewReadStatusSyncing`).
    var readStatusSync: any ReviewReadStatusSyncing = NoopReviewReadStatusSync()

    private let defaults: UserDefaults
    private let legacySpace: String?
    private var activeSpace: String?

    private enum Keys {
        static let seen = "ferry.local.reviewSeenIDs"
        static let pending = "ferry.local.reviewPendingSyncIDs"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let priorOrigin = defaults.string(forKey: "ferry.server.origin")
        let mapping = defaults.dictionary(forKey: "ferry.spaceKeys") as? [String: String] ?? [:]
        legacySpace = priorOrigin.map { mapping[$0] ?? $0 }
    }

    func activate(space: SpaceKey) {
        activeSpace = space.value
        let seenKey = Keys.seen + "." + space.folderName
        let pendingKey = Keys.pending + "." + space.folderName
        if defaults.object(forKey: seenKey) == nil, legacySpace == space.value {
            // The legacy unscoped read-state belongs only to the previously
            // connected server. Preserve it without deleting the old keys.
            defaults.set(defaults.stringArray(forKey: Keys.seen) ?? [], forKey: seenKey)
            defaults.set(defaults.stringArray(forKey: Keys.pending) ?? [], forKey: pendingKey)
        }
        seenIDs = Set(defaults.stringArray(forKey: seenKey) ?? [])
        pendingSyncIDs = defaults.stringArray(forKey: pendingKey) ?? []
        items = []
    }

    /// Number of items not yet marked 已看 — the "（N）" on the pinned entry.
    var unseenCount: Int {
        items.reduce(0) { $0 + (seenIDs.contains($1.id) ? 0 : 1) }
    }

    func isSeen(_ id: String) -> Bool { seenIDs.contains(id) }

    func item(id: String) -> ReviewItem? { items.first { $0.id == id } }

    // MARK: - Ingest

    /// Add (or refresh) the item carried by one message. Cheap enough to run
    /// for every message that arrives on the 2 s poll.
    func ingest(message: MessagePayload) {
        guard let item = ReviewItemParser.parse(message: message) else { return }
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = item
        } else {
            items.append(item)
            items.sort { $0.sequence > $1.sequence }
        }
    }

    /// Rebuild from everything currently loaded: initial load, an older page
    /// being prepended, and after messages are locally deleted or cleared.
    /// Items are deduplicated by id, newest first.
    func rebuild(from messages: [MessagePayload]) {
        var collected: [ReviewItem] = []
        var ids: Set<String> = []
        for message in messages {
            guard let item = ReviewItemParser.parse(message: message) else { continue }
            guard ids.insert(item.id).inserted else { continue }
            collected.append(item)
        }
        items = collected.sorted { $0.sequence > $1.sequence }
    }

    // MARK: - 已看

    func markSeen(_ id: String) {
        guard !seenIDs.contains(id) else { return }
        seenIDs.insert(id)
        persistSeen()
        pendingSyncIDs.append(id)
        persistPending()
        Task { await syncReadStatus() }
    }

    /// Pull the server's read ids, then push the pending ones. No-op today,
    /// which is why marking an item 已看 stays instant and offline-safe.
    func syncReadStatus() async {
        let remote = await readStatusSync.pullReadIDs()
        if !remote.isEmpty {
            seenIDs.formUnion(remote)
            persistSeen()
        }
        guard !pendingSyncIDs.isEmpty else { return }
        let confirmed = await readStatusSync.pushRead(ids: pendingSyncIDs)
        guard !confirmed.isEmpty else { return }
        pendingSyncIDs.removeAll { confirmed.contains($0) }
        persistPending()
    }

    private func persistSeen() {
        guard let space = activeSpace else { return }
        defaults.set(Array(seenIDs), forKey: Keys.seen + "." + SpaceKey(value: space).folderName)
    }
    private func persistPending() {
        guard let space = activeSpace else { return }
        defaults.set(pendingSyncIDs, forKey: Keys.pending + "." + SpaceKey(value: space).folderName)
    }
}
