import XCTest
@testable import TokenboardApp

/// Idle memory must stay flat: the asset stores are bounded LRU caches, so a
/// browse through every theme and stage cannot grow the app without limit,
/// while the working set of one scene always fits without thrash.
///
/// The stores are process-global and their statistics are cumulative, so
/// every assertion here works in deltas and stays order-independent.
@MainActor
final class CompanionAssetCacheTests: XCTestCase, CompanionSceneFixtures {
    func testLoadingTheWholeCorpusStaysWithinTheCacheLimits() throws {
        let cache = CompanionAssetImageStore.cache
        for theme in CompanionTheme.allCases where theme != .none {
            let variant = try XCTUnwrap(CompanionCatalog.variants(for: theme).first)
            for stage in 0..<CompanionJourney.stageCount {
                for scenery in 0..<CompanionAssetCatalog.sceneryCount(for: theme) {
                    let asset = CompanionAssetCatalog.scene(
                        theme: theme,
                        variant: variant,
                        stage: stage,
                        scenery: scenery,
                        fraction: 1,
                        seed: seed
                    )
                    for resource in asset?.allResources ?? [] {
                        _ = CompanionAssetImageStore.image(resource: resource)
                    }
                }
                if let icon = CompanionAssetCatalog.menuIconResource(
                    theme: theme,
                    variant: variant,
                    stage: stage
                ) {
                    _ = CompanionAssetImageStore.image(resource: icon)
                }
                XCTAssertLessThanOrEqual(cache.count, cache.countLimit)
                XCTAssertLessThanOrEqual(cache.totalCost, cache.totalCostLimit)
            }
        }
    }

    func testACachedRereadBumpsOnlyHits() throws {
        let cache = CompanionAssetImageStore.cache
        let resource = "Forest/sprites/oak-0.png"
        _ = try XCTUnwrap(CompanionAssetImageStore.image(resource: resource))

        let before = cache.statistics
        _ = try XCTUnwrap(CompanionAssetImageStore.image(resource: resource))
        let after = cache.statistics
        XCTAssertEqual(after.hits, before.hits + 1)
        XCTAssertEqual(after.misses, before.misses)
        XCTAssertEqual(after.evictions, before.evictions)
    }

    func testTheHeaviestSceneFitsWithoutASingleEviction() throws {
        // The lit village summit plus the settings shelf is the largest
        // working set one moment of the app can need at once.
        let cache = CompanionAssetImageStore.cache
        cache.removeAll()
        let before = cache.statistics.evictions

        let variant = try XCTUnwrap(CompanionCatalog.variants(for: .village).first)
        for stage in [
            CompanionJourney.finalStage,
            CompanionAssetCatalog.shelfPreviewStage(for: .village)
        ] {
            for scenery in 0..<CompanionAssetCatalog.sceneryCount(for: .village) {
                let asset = CompanionAssetCatalog.scene(
                    theme: .village,
                    variant: variant,
                    stage: stage,
                    scenery: scenery,
                    fraction: 1,
                    seed: seed
                )
                for resource in asset?.allResources ?? [] {
                    _ = CompanionAssetImageStore.image(resource: resource)
                }
            }
        }

        XCTAssertGreaterThan(cache.count, 0)
        XCTAssertEqual(cache.statistics.evictions, before, "the working set must fit")
    }

    func testEveryVillageWindowMapFitsTheWindowCacheWithoutEvictions() {
        let cache = CompanionWindowMapStore.cache
        let before = cache.statistics.evictions
        for style in CompanionAssetCatalog.villageStyles {
            for level in 0...3 {
                for light in ["day", "lit"] {
                    _ = CompanionWindowMapStore.windows(
                        resource: "Village/sprites/\(style)-\(level)-\(light).png"
                    )
                }
            }
        }
        XCTAssertLessThanOrEqual(cache.count, cache.countLimit)
        XCTAssertEqual(cache.statistics.evictions, before)
    }
}
