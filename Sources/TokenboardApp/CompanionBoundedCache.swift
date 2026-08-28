import Foundation

/// A deterministic LRU cache for the companion asset stores.
///
/// Chosen over `NSCache` on purpose: its eviction policy is opaque and
/// pressure-driven (untestable), and it cannot hold value types like
/// `[CompanionWindowCell]` without boxing. This cache evicts exactly the
/// least-recently-used entries, exactly when a limit is exceeded, and counts
/// what it did so tests and diagnostics can see it.
///
/// No explicit invalidation exists because none is needed: keys are immutable
/// bundle resource paths whose content never changes while the app runs, and
/// LRU aging evicts the plates of themes and days no longer on screen.
@MainActor
final class CompanionBoundedCache<Value> {
    struct Statistics: Equatable, Sendable {
        var hits = 0
        var misses = 0
        var evictions = 0
    }

    private struct Entry {
        let value: Value
        let cost: Int
    }

    let countLimit: Int
    let totalCostLimit: Int
    private var entries: [String: Entry] = [:]
    /// Least-recently-used first.
    private var order: [String] = []
    private(set) var totalCost = 0
    private(set) var statistics = Statistics()

    init(countLimit: Int, totalCostLimit: Int = .max) {
        precondition(countLimit > 0, "A cache that can hold nothing caches nothing")
        precondition(totalCostLimit > 0, "A cache that can hold nothing caches nothing")
        self.countLimit = countLimit
        self.totalCostLimit = totalCostLimit
    }

    var count: Int { entries.count }

    func value(forKey key: String) -> Value? {
        guard let entry = entries[key] else {
            statistics.misses += 1
            return nil
        }
        statistics.hits += 1
        touch(key)
        return entry.value
    }

    /// Stores a value and evicts least-recently-used entries until the limits
    /// hold again. The entry just stored is never evicted, so one oversized
    /// value is cached (and the cache briefly exceeds `totalCostLimit` by at
    /// most that one entry) rather than reloaded forever.
    func setValue(_ value: Value, forKey key: String, cost: Int = 0) {
        let cost = max(0, cost)
        if let existing = entries.removeValue(forKey: key) {
            totalCost -= existing.cost
            order.removeAll { $0 == key }
        }
        entries[key] = Entry(value: value, cost: cost)
        order.append(key)
        totalCost += cost

        while entries.count > countLimit || totalCost > totalCostLimit,
              let oldest = order.first, oldest != key {
            order.removeFirst()
            if let evicted = entries.removeValue(forKey: oldest) {
                totalCost -= evicted.cost
                statistics.evictions += 1
            }
        }
    }

    /// Empties the cache. Statistics are cumulative and survive, so a
    /// diagnostics reader keeps the session's whole story.
    func removeAll() {
        entries.removeAll()
        order.removeAll()
        totalCost = 0
    }

    private func touch(_ key: String) {
        guard order.last != key else { return }
        order.removeAll { $0 == key }
        order.append(key)
    }
}
