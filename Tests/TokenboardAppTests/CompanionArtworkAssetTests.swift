import AppKit
import Foundation
import ImageIO
import XCTest
@testable import TokenboardApp

final class CompanionArtworkAssetTests: XCTestCase {
    func testEveryVisibleThemeAndStageResolvesToBundledArtwork() throws {
        for theme in CompanionTheme.allCases where theme != .none {
            let variants = CompanionCatalog.variants(for: theme)
            XCTAssertFalse(variants.isEmpty, "\(theme.title) needs built-in artwork")

            for variant in variants {
                for stage in 0..<CompanionJourney.thresholds.count {
                    for scenery in 0..<CompanionAssetCatalog.sceneryCount(for: theme) {
                        let scene = try XCTUnwrap(
                            CompanionAssetCatalog.scene(
                                theme: theme,
                                variant: variant,
                                stage: stage,
                                scenery: scenery
                            ),
                            "Missing \(theme.title), \(variant.title), stage \(stage + 1), scenery \(scenery)"
                        )

                        XCTAssertFalse(scene.backgroundResource.isEmpty)
                        XCTAssertFalse(scene.allResources.isEmpty)
                        for resource in scene.allResources {
                            XCTAssertFalse(resource.hasPrefix("/"), resource)
                            XCTAssertFalse(resource.contains("://"), resource)
                            XCTAssertTrue(
                                FileManager.default.fileExists(
                                    atPath: developmentCompanionResourceURL(resource).path
                                ),
                                "Missing bundled companion asset: \(resource)"
                            )
                        }
                    }
                }
            }
        }
    }

    func testEveryThemeTellsItsJourneyThroughTwelveDistinctBackgrounds() throws {
        for theme in CompanionTheme.allCases where theme != .none {
            let variant = try XCTUnwrap(CompanionCatalog.variants(for: theme).first)
            let backgrounds = try (0..<CompanionJourney.thresholds.count).map { stage in
                try XCTUnwrap(
                    CompanionAssetCatalog.scene(theme: theme, variant: variant, stage: stage)
                ).backgroundResource
            }
            XCTAssertEqual(
                Set(backgrounds).count,
                CompanionJourney.thresholds.count,
                "\(theme.title) reuses a background between stages: \(backgrounds)"
            )
        }
    }

    func testEveryBackgroundPlateHasRetinaPanoramaResolution() throws {
        var resources = Set<String>()
        for theme in CompanionTheme.allCases where theme != .none {
            let variant = try XCTUnwrap(CompanionCatalog.variants(for: theme).first)
            for stage in 0..<CompanionJourney.thresholds.count {
                for scenery in 0..<CompanionAssetCatalog.sceneryCount(for: theme) {
                    let scene = try XCTUnwrap(
                        CompanionAssetCatalog.scene(
                            theme: theme,
                            variant: variant,
                            stage: stage,
                            scenery: scenery
                        )
                    )
                    resources.insert(scene.backgroundResource)
                }
            }
        }

        for resource in resources {
            let url = developmentCompanionResourceURL(resource)
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            let properties = try XCTUnwrap(
                CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            )
            let width = try XCTUnwrap(properties[kCGImagePropertyPixelWidth] as? Int)
            let height = try XCTUnwrap(properties[kCGImagePropertyPixelHeight] as? Int)
            XCTAssertGreaterThanOrEqual(width, 1_240, resource)
            XCTAssertGreaterThanOrEqual(height, 832, resource)
        }
    }

    func testEveryStageOffersDistinctDailySceneryOfTheSamePlace() throws {
        for theme in CompanionTheme.allCases where theme != .none {
            let variant = try XCTUnwrap(CompanionCatalog.variants(for: theme).first)
            for stage in 0..<CompanionJourney.thresholds.count {
                let scenes = try (0..<CompanionAssetCatalog.sceneryCount(for: theme)).map {
                    try XCTUnwrap(
                        CompanionAssetCatalog.scene(
                            theme: theme,
                            variant: variant,
                            stage: stage,
                            scenery: $0
                        )
                    )
                }
                XCTAssertEqual(
                    Set(scenes.map(\.backgroundResource)).count,
                    scenes.count,
                    "\(theme.title) stage \(stage + 1) repeats a scenery plate"
                )
                // Scenery only changes the day, never the stage's subjects.
                for scene in scenes.dropFirst() {
                    XCTAssertEqual(scene.layers, scenes[0].layers)
                }
            }
        }
    }

    func testSceneryLookupWrapsInsteadOfCrashing() throws {
        let variant = try XCTUnwrap(CompanionCatalog.variants(for: .village).first)
        XCTAssertEqual(
            CompanionAssetCatalog.scene(theme: .village, variant: variant, stage: 2, scenery: 3),
            CompanionAssetCatalog.scene(theme: .village, variant: variant, stage: 2, scenery: 0)
        )
        XCTAssertEqual(
            CompanionAssetCatalog.scene(theme: .village, variant: variant, stage: 2, scenery: -1),
            CompanionAssetCatalog.scene(theme: .village, variant: variant, stage: 2, scenery: 2)
        )
    }

    func testNoneNeverResolvesArtwork() {
        XCTAssertNil(
            CompanionAssetCatalog.scene(
                theme: .none,
                variant: CompanionVariant(id: "none", title: "None"),
                stage: 0
            )
        )
        XCTAssertNil(
            CompanionAssetCatalog.menuIconResource(
                theme: .none,
                variant: CompanionVariant(id: "none", title: "None"),
                stage: 0
            )
        )
    }

    func testStageLookupClampsToTheJourneyBounds() throws {
        let variant = try XCTUnwrap(CompanionCatalog.variants(for: .forest).first)

        XCTAssertEqual(
            CompanionAssetCatalog.scene(theme: .forest, variant: variant, stage: -1),
            CompanionAssetCatalog.scene(theme: .forest, variant: variant, stage: 0)
        )
        XCTAssertEqual(
            CompanionAssetCatalog.scene(theme: .forest, variant: variant, stage: 99),
            CompanionAssetCatalog.scene(
                theme: .forest,
                variant: variant,
                stage: CompanionJourney.thresholds.count - 1
            )
        )
    }

    func testGrowthPlansAddSubjectsContinuouslyAcrossTheWholeJourney() {
        for plan in [CompanionAssetCatalog.forestGrowthPlan, CompanionAssetCatalog.villageGrowthPlan] {
            let stageTotal = plan.stageCounts.count
            XCTAssertEqual(stageTotal, CompanionJourney.thresholds.count)
            XCTAssertEqual(plan.population(stage: 0, fraction: 0), plan.stageCounts[0])
            XCTAssertEqual(plan.population(stage: stageTotal - 1, fraction: 1), plan.finalCount)

            var previous = 0
            for stage in 0..<stageTotal {
                for step in 0...10 {
                    let population = plan.population(stage: stage, fraction: Double(step) / 10)
                    XCTAssertGreaterThanOrEqual(population, previous, "population must never shrink")
                    previous = population
                }
            }
            // Every slot's appearance is consistent with the population curve:
            // at its appearance progress the slot is part of the population.
            for slot in 0..<plan.finalCount {
                let appearance = plan.appearance(of: slot)
                XCTAssertTrue((0...1).contains(appearance))
                let stage = min(stageTotal - 1, Int(appearance * Double(stageTotal)))
                let fraction = appearance * Double(stageTotal) - Double(stage)
                XCTAssertGreaterThanOrEqual(
                    plan.population(stage: stage, fraction: fraction),
                    slot + 1,
                    "slot \(slot) must be visible from its appearance onward"
                )
            }
        }
    }

    func testForestGrowsMoreTreesWithinAStageWithoutMovingExistingOnes() throws {
        let variant = try XCTUnwrap(CompanionCatalog.variants(for: .forest).first)
        for stage in 0..<CompanionJourney.thresholds.count {
            let early = try XCTUnwrap(CompanionAssetCatalog.scene(
                theme: .forest, variant: variant, stage: stage, fraction: 0.1, seed: 99
            ))
            let late = try XCTUnwrap(CompanionAssetCatalog.scene(
                theme: .forest, variant: variant, stage: stage, fraction: 0.9, seed: 99
            ))
            XCTAssertGreaterThan(
                late.layers.count, early.layers.count,
                "stage \(stage + 1) must keep planting trees as tokens accrue"
            )
            let earlyByID = Dictionary(uniqueKeysWithValues: early.layers.map { ($0.id, $0) })
            let lateByID = Dictionary(uniqueKeysWithValues: late.layers.map { ($0.id, $0) })
            for (id, layer) in earlyByID {
                let grown = try XCTUnwrap(lateByID[id], "tree \(id) must never disappear")
                XCTAssertEqual(grown.horizontalPosition, layer.horizontalPosition, "trees keep their spot")
                XCTAssertEqual(grown.bottomOffset, layer.bottomOffset)
                XCTAssertGreaterThanOrEqual(
                    grown.relativeHeight, layer.relativeHeight,
                    "a growing forest never shrinks a tree"
                )
            }
        }
    }

    func testForestJourneyOpensOnOneSaplingAndEndsInADenseForest() throws {
        let variant = try XCTUnwrap(CompanionCatalog.variants(for: .forest).first)
        let opening = try XCTUnwrap(CompanionAssetCatalog.scene(
            theme: .forest, variant: variant, stage: 0, fraction: 0, seed: 5
        ))
        XCTAssertEqual(opening.layers.count, 1)
        XCTAssertTrue(
            opening.layers[0].resource.contains("oak-0"),
            "the journey opens on a lone oak sapling"
        )
        XCTAssertEqual(opening.layers[0].horizontalPosition, 0.5, accuracy: 0.03)

        let finale = try XCTUnwrap(CompanionAssetCatalog.scene(
            theme: .forest, variant: variant, stage: CompanionJourney.thresholds.count - 1,
            fraction: 1, seed: 5
        ))
        XCTAssertEqual(finale.layers.count, CompanionAssetCatalog.forestGrowthPlan.finalCount)
        XCTAssertTrue(
            finale.layers.contains { $0.resource.contains("-3.png") },
            "the finished forest holds ancient trees"
        )
    }

    func testVillageRedevelopsIntoALitHighRiseSkyline() throws {
        let variant = try XCTUnwrap(CompanionCatalog.variants(for: .village).first)
        let hamlet = try XCTUnwrap(CompanionAssetCatalog.scene(
            theme: .village, variant: variant, stage: 0, fraction: 0, seed: 21
        ))
        XCTAssertEqual(hamlet.layers.count, 1)
        XCTAssertTrue(
            hamlet.layers[0].resource.contains("timber-0-day"),
            "the journey opens on a single daylight cottage"
        )

        let skyline = try XCTUnwrap(CompanionAssetCatalog.scene(
            theme: .village, variant: variant, stage: CompanionJourney.thresholds.count - 1,
            fraction: 1, seed: 21
        ))
        XCTAssertEqual(skyline.layers.count, CompanionAssetCatalog.villageGrowthPlan.finalCount)
        XCTAssertTrue(
            skyline.layers.allSatisfy { $0.resource.hasSuffix("-lit.png") },
            "the night city lights every window variant"
        )
        XCTAssertTrue(
            skyline.layers.contains { $0.resource.contains("-3-lit") },
            "the finished city raises high-rises"
        )
        let hamletTallest = try XCTUnwrap(hamlet.layers.map(\.relativeHeight).max())
        let skylineTallest = try XCTUnwrap(skyline.layers.map(\.relativeHeight).max())
        XCTAssertGreaterThan(skylineTallest, hamletTallest * 2, "the skyline must visibly rise")
    }

    func testGrowingScenesAreStablePerSeedAndDistinctAcrossSeeds() throws {
        for theme in [CompanionTheme.forest, .village] {
            let variant = try XCTUnwrap(CompanionCatalog.variants(for: theme).first)
            let first = try XCTUnwrap(CompanionAssetCatalog.scene(
                theme: theme, variant: variant, stage: 5, fraction: 0.6, seed: 1234
            ))
            let repeated = try XCTUnwrap(CompanionAssetCatalog.scene(
                theme: theme, variant: variant, stage: 5, fraction: 0.6, seed: 1234
            ))
            XCTAssertEqual(first, repeated, "\(theme.title) must be deterministic per seed")

            let other = try XCTUnwrap(CompanionAssetCatalog.scene(
                theme: theme, variant: variant, stage: 5, fraction: 0.6, seed: 4321
            ))
            XCTAssertNotEqual(
                first.layers.map(\.horizontalPosition),
                other.layers.map(\.horizontalPosition),
                "\(theme.title) must grow a distinct place per install"
            )
        }
    }

    func testEveryGrowingSpriteExistsAndMatchesItsCatalogCellHeight() throws {
        var sprites: [(resource: String, cells: Int)] = []
        for (species, heights) in CompanionAssetCatalog.forestSpriteCellHeights {
            for (level, cells) in heights.enumerated() {
                sprites.append(("Forest/sprites/\(species)-\(level).png", cells))
            }
        }
        for (style, heights) in CompanionAssetCatalog.villageSpriteCellHeights {
            for (level, cells) in heights.enumerated() {
                for light in ["day", "lit"] {
                    sprites.append(("Village/sprites/\(style)-\(level)-\(light).png", cells))
                }
            }
        }
        XCTAssertFalse(sprites.isEmpty)
        for sprite in sprites {
            let url = developmentCompanionResourceURL(sprite.resource)
            let size = try XCTUnwrap(
                pngPixelSize(at: url),
                "Missing or unreadable sprite: \(sprite.resource)"
            )
            XCTAssertEqual(
                size.height, sprite.cells * 8,
                "\(sprite.resource) is baked at a different height than the catalog places it"
            )
        }
    }

    func testOakCanopiesStayConnectedToTheirTrunks() throws {
        for level in CompanionAssetCatalog.forestSpriteCellHeights["oak"]!.indices {
            let resource = "Forest/sprites/oak-\(level).png"
            let data = try Data(contentsOf: developmentCompanionResourceURL(resource))
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
            let centerX = bitmap.pixelsWide / 2
            let opaqueRows = (0..<bitmap.pixelsHigh).filter { y in
                (bitmap.colorAt(x: centerX, y: y)?.alphaComponent ?? 0) > 0.5
            }
            let first = try XCTUnwrap(opaqueRows.first)
            let last = try XCTUnwrap(opaqueRows.last)

            for y in first...last {
                XCTAssertGreaterThan(
                    bitmap.colorAt(x: centerX, y: y)?.alphaComponent ?? 0,
                    0.5,
                    "\(resource) separates its canopy from its trunk at row \(y)"
                )
            }
        }
    }

    func testOldSchoolAdventurerWalksAcrossEachLocation() throws {
        for theme in [CompanionTheme.oldSchoolRuneScape, .minecraft] {
        let variant = try XCTUnwrap(CompanionCatalog.variants(for: theme).first)
        for stage in 0..<CompanionJourney.thresholds.count {
            let positions = try [0.0, 0.5, 1.0].map { fraction in
                try XCTUnwrap(CompanionAssetCatalog.scene(
                    theme: theme, variant: variant, stage: stage, fraction: fraction
                )?.layers.first?.horizontalPosition)
            }
            XCTAssertEqual(positions, positions.sorted(), "the walk only moves forward")
            XCTAssertGreaterThan(
                positions[2], positions[0],
                "stage \(stage + 1) must let the adventurer travel"
            )
            for position in positions {
                XCTAssertTrue((0.1...0.9).contains(position), "the adventurer stays in frame")
            }
        }
        }
    }

    func testPokemonPartnerGrowsTowardItsNextEvolution() throws {
        let variant = try XCTUnwrap(CompanionCatalog.variants(for: .pokemon).first)
        let fresh = try XCTUnwrap(CompanionAssetCatalog.scene(
            theme: .pokemon, variant: variant, stage: 2, fraction: 0
        ))
        let almost = try XCTUnwrap(CompanionAssetCatalog.scene(
            theme: .pokemon, variant: variant, stage: 2, fraction: 1
        ))
        XCTAssertGreaterThan(
            try XCTUnwrap(almost.layers.first?.relativeHeight),
            try XCTUnwrap(fresh.layers.first?.relativeHeight),
            "the partner grows as its evolution nears"
        )

        // The finale's gathered family keeps its fixed compositions.
        let finaleStage = CompanionJourney.thresholds.count - 1
        let finaleFresh = try XCTUnwrap(CompanionAssetCatalog.scene(
            theme: .pokemon, variant: variant, stage: finaleStage, fraction: 0
        ))
        let finaleDone = try XCTUnwrap(CompanionAssetCatalog.scene(
            theme: .pokemon, variant: variant, stage: finaleStage, fraction: 1
        ))
        XCTAssertEqual(finaleFresh.layers, finaleDone.layers)
    }

    func testAgeOfEmpiresScenesPushInAsAStageProgresses() throws {
        let variant = try XCTUnwrap(CompanionCatalog.variants(for: .ageOfEmpiresII).first)
        let start = try XCTUnwrap(CompanionAssetCatalog.scene(
            theme: .ageOfEmpiresII, variant: variant, stage: 3, fraction: 0
        ))
        let late = try XCTUnwrap(CompanionAssetCatalog.scene(
            theme: .ageOfEmpiresII, variant: variant, stage: 3, fraction: 0.8
        ))
        XCTAssertEqual(start.backgroundZoom, 1, accuracy: 0.0001)
        XCTAssertGreaterThan(late.backgroundZoom, 1.01)
        XCTAssertLessThan(late.backgroundZoom, 1.1, "the push-in stays subtle")

        // Layered themes carry their motion in the subjects, not the plate.
        let forestVariant = try XCTUnwrap(CompanionCatalog.variants(for: .forest).first)
        let forest = try XCTUnwrap(CompanionAssetCatalog.scene(
            theme: .forest, variant: forestVariant, stage: 3, fraction: 0.8
        ))
        XCTAssertEqual(forest.backgroundZoom, 1, accuracy: 0.0001)
    }

    func testPokemonJourneyKeepsTheDailyFamilyTogether() throws {
        for variant in CompanionCatalog.variants(for: .pokemon) {
            var members: Set<String> = []
            for stage in 0..<CompanionJourney.thresholds.count {
                let scene = try XCTUnwrap(
                    CompanionAssetCatalog.scene(theme: .pokemon, variant: variant, stage: stage)
                )
                XCTAssertFalse(scene.layers.isEmpty)
                for layer in scene.layers {
                    XCTAssertTrue(layer.castsGroundShadow, "subjects need grounding")
                    members.insert(layer.resource)
                }
            }
            XCTAssertEqual(
                members.count, 3,
                "\(variant.title) should show exactly its own three evolutions"
            )

            let finale = try XCTUnwrap(
                CompanionAssetCatalog.scene(
                    theme: .pokemon,
                    variant: variant,
                    stage: CompanionJourney.thresholds.count - 1
                )
            )
            XCTAssertEqual(finale.layers.count, 3, "the last stage gathers the family")
        }
    }

    func testOldSchoolCharactersStandInsideEveryScene() throws {
        let variant = try XCTUnwrap(
            CompanionCatalog.variants(for: .oldSchoolRuneScape).first
        )
        for stage in 0..<CompanionJourney.thresholds.count {
            let layer = try XCTUnwrap(
                CompanionAssetCatalog.scene(
                    theme: .oldSchoolRuneScape,
                    variant: variant,
                    stage: stage
                )?.layers.first
            )
            XCTAssertTrue(layer.castsGroundShadow)
            XCTAssertLessThanOrEqual(layer.relativeHeight, 0.8, "gear must stay in proportion")
            XCTAssertGreaterThanOrEqual(layer.relativeHeight, 0.6, "gear must stay readable")
            XCTAssertTrue((0.1...0.9).contains(layer.horizontalPosition))
            XCTAssertGreaterThanOrEqual(layer.bottomOffset, 0, "feet stay in frame")
        }
    }

    func testMenuIconResourcesResolveForEveryAlphaBackedTheme() throws {
        for theme in [CompanionTheme.pokemon, .forest, .village, .oldSchoolRuneScape, .minecraft] {
            for variant in CompanionCatalog.variants(for: theme) {
                for stage in 0..<CompanionJourney.thresholds.count {
                    let resource = try XCTUnwrap(
                        CompanionAssetCatalog.menuIconResource(
                            theme: theme,
                            variant: variant,
                            stage: stage
                        ),
                        "\(theme.title) stage \(stage + 1) has no icon source"
                    )
                    XCTAssertTrue(
                        FileManager.default.fileExists(
                            atPath: developmentCompanionResourceURL(resource).path
                        ),
                        "Missing icon asset: \(resource)"
                    )
                }
            }
        }
        // Age of Empires II scenes are opaque screenshots; its menu icon is
        // a drawn glyph instead of an asset silhouette.
        XCTAssertNil(
            CompanionAssetCatalog.menuIconResource(
                theme: .ageOfEmpiresII,
                variant: CompanionVariant(id: "town-center", title: "Town Center"),
                stage: 0
            )
        )
    }

    func testShelfPreviewStagesAreValidJourneyStages() {
        for theme in CompanionTheme.allCases {
            let stage = CompanionAssetCatalog.shelfPreviewStage(for: theme)
            XCTAssertTrue((0..<CompanionJourney.thresholds.count).contains(stage))
        }
    }

}
