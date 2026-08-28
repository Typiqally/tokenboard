import XCTest
@testable import TokenboardApp

/// The companion stores cache immutable bundle resources, so what matters is
/// that the cache is bounded, evicts exactly the least-recently-used entries,
/// and reports what it did — deterministically, unlike NSCache.
@MainActor
final class CompanionBoundedCacheTests: XCTestCase {
    func testStoresAndRetrievesValuesAndCountsHitsAndMisses() {
        let cache = CompanionBoundedCache<String>(countLimit: 4)
        XCTAssertNil(cache.value(forKey: "a"))
        cache.setValue("alpha", forKey: "a", cost: 3)
        XCTAssertEqual(cache.value(forKey: "a"), "alpha")
        XCTAssertEqual(cache.count, 1)
        XCTAssertEqual(cache.totalCost, 3)
        XCTAssertEqual(cache.statistics, .init(hits: 1, misses: 1, evictions: 0))
    }

    func testCountLimitEvictsTheLeastRecentlyUsedEntry() {
        let cache = CompanionBoundedCache<Int>(countLimit: 2)
        cache.setValue(1, forKey: "a")
        cache.setValue(2, forKey: "b")
        cache.setValue(3, forKey: "c")
        XCTAssertNil(cache.value(forKey: "a"), "the oldest entry goes first")
        XCTAssertEqual(cache.value(forKey: "b"), 2)
        XCTAssertEqual(cache.value(forKey: "c"), 3)
        XCTAssertEqual(cache.statistics.evictions, 1)
    }

    func testReadingAnEntryKeepsItAlive() {
        let cache = CompanionBoundedCache<Int>(countLimit: 2)
        cache.setValue(1, forKey: "a")
        cache.setValue(2, forKey: "b")
        _ = cache.value(forKey: "a")
        cache.setValue(3, forKey: "c")
        XCTAssertEqual(cache.value(forKey: "a"), 1, "the touched entry survives")
        XCTAssertNil(cache.value(forKey: "b"), "the untouched entry was evicted")
    }

    func testCostLimitEvictsUntilTheBudgetHoldsAgain() {
        let cache = CompanionBoundedCache<Int>(countLimit: 10, totalCostLimit: 10)
        cache.setValue(1, forKey: "a", cost: 4)
        cache.setValue(2, forKey: "b", cost: 4)
        cache.setValue(3, forKey: "c", cost: 4)
        XCTAssertNil(cache.value(forKey: "a"))
        XCTAssertEqual(cache.totalCost, 8)
        XCTAssertEqual(cache.statistics.evictions, 1)
    }

    func testReplacingAKeyReplacesItsCostInsteadOfAccumulating() {
        let cache = CompanionBoundedCache<Int>(countLimit: 4, totalCostLimit: 100)
        cache.setValue(1, forKey: "a", cost: 60)
        cache.setValue(2, forKey: "a", cost: 10)
        XCTAssertEqual(cache.count, 1)
        XCTAssertEqual(cache.totalCost, 10)
        XCTAssertEqual(cache.value(forKey: "a"), 2)
        XCTAssertEqual(cache.statistics.evictions, 0)
    }

    func testAnOversizedEntryIsCachedRatherThanReloadedForever() {
        let cache = CompanionBoundedCache<Int>(countLimit: 4, totalCostLimit: 10)
        cache.setValue(1, forKey: "small", cost: 2)
        cache.setValue(2, forKey: "huge", cost: 50)
        XCTAssertEqual(cache.value(forKey: "huge"), 2, "the newest entry is never evicted")
        XCTAssertNil(cache.value(forKey: "small"), "everything older made way")
        XCTAssertEqual(cache.totalCost, 50)
    }

    func testRemoveAllEmptiesTheCacheAndKeepsTheSessionStatistics() {
        let cache = CompanionBoundedCache<Int>(countLimit: 2)
        cache.setValue(1, forKey: "a")
        cache.setValue(2, forKey: "b")
        cache.setValue(3, forKey: "c")
        _ = cache.value(forKey: "b")
        cache.removeAll()
        XCTAssertEqual(cache.count, 0)
        XCTAssertEqual(cache.totalCost, 0)
        XCTAssertNil(cache.value(forKey: "b"))
        XCTAssertEqual(cache.statistics.evictions, 1, "statistics survive a reset")
    }
}
