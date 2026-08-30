import Foundation
import XCTest
@testable import TokenboardApp

/// As someone glancing at a branded companion scene, I want its inhabitants
/// to be the game's own recognizable artwork, so a pig, villager, player, or
/// bird cannot look like the same generic Tokenboard silhouette in every world.
final class CompanionSceneSpriteTests: XCTestCase {
    private let seed: UInt64 = 0x5EED_C0FF_EE12_3456

    func testEveryBrandedInhabitantUsesBundledThemeNativeSprites() throws {
        let brandedThemes: [(theme: CompanionTheme, resourcePrefix: String)] = [
            (.pokemon, "Pokemon/actors/"),
            (.oldSchoolRuneScape, "OldSchoolRuneScape/Actors/"),
            (.ageOfEmpiresII, "AgeOfEmpiresII/actors/"),
            (.minecraft, "Minecraft/actors/"),
            (.banished, "Banished/actors/"),
            (.frostpunk, "Frostpunk/actors/")
        ]

        for entry in brandedThemes {
            for stage in 0..<CompanionJourney.thresholds.count {
                for field in plan(for: entry.theme, stage: stage).actors {
                    XCTAssertFalse(field.sprites.isEmpty, "\(field.key) is still procedural")
                    for sprite in field.sprites {
                        XCTAssertTrue(
                            sprite.resource.hasPrefix(entry.resourcePrefix),
                            "\(field.key) borrows artwork from another world: \(sprite.resource)"
                        )
                        XCTAssertGreaterThan(sprite.frameCount, 0)
                        XCTAssertTrue(
                            FileManager.default.fileExists(
                                atPath: developmentCompanionResourceURL(sprite.resource).path
                            ),
                            "Missing bundled actor sprite: \(sprite.resource)"
                        )
                    }
                }
            }
        }
    }

    func testOriginalForestAndVillagePopulationsRemainOriginalProceduralArtwork() {
        for theme in [CompanionTheme.forest, .village] {
            for stage in 0..<CompanionJourney.thresholds.count {
                for field in plan(for: theme, stage: stage).actors {
                    XCTAssertTrue(
                        field.sprites.isEmpty,
                        "\(field.key) should stay in Tokenboard's original pixel-art system"
                    )
                }
            }
        }
    }

    func testRecognizableBrandedBirdsAreActorsInsteadOfChevronParticles() {
        for theme in [
            CompanionTheme.pokemon,
            .oldSchoolRuneScape,
            .ageOfEmpiresII,
            .minecraft,
            .banished,
            .frostpunk
        ] {
            for stage in 0..<CompanionJourney.thresholds.count {
                XCTAssertFalse(
                    plan(for: theme, stage: stage).fields.contains { $0.shape == .chevron },
                    "\(theme.title) stage \(stage + 1) still draws a generic chevron bird"
                )
            }
        }
    }

    func testAvailableSourceAnimationsAdvanceTheirBakedSpriteFrames() throws {
        let animatedFields: [(CompanionTheme, Int, String)] = [
            (.pokemon, 2, "pokemon/visitor"),
            (.ageOfEmpiresII, 6, "aoe/villagers"),
            (.ageOfEmpiresII, 6, "aoe/hawks-low"),
            (.minecraft, 3, "mc/bats"),
            (.minecraft, 9, "mc/silverfish")
        ]

        for (theme, stage, key) in animatedFields {
            let field = try XCTUnwrap(
                plan(for: theme, stage: stage).actors.first { $0.key == key },
                "Missing animated population \(key)"
            )
            XCTAssertTrue(
                field.sprites.contains { $0.frameCount > 1 },
                "\(key) does not use its available source animation"
            )

            let frames = Set((0...240).flatMap { step in
                field.actors(at: Double(step) * 0.05, seed: seed).compactMap(\.spriteFrame)
            })
            XCTAssertGreaterThan(frames.count, 1, "\(key) never advances its sprite frames")
        }
    }

    func testBakedSpriteStripsMatchTheirCatalogFrameCounts() throws {
        let sprites = Set(
            [CompanionTheme.pokemon, .oldSchoolRuneScape, .ageOfEmpiresII, .minecraft, .banished, .frostpunk]
                .flatMap { theme in
                    (0..<CompanionJourney.thresholds.count).flatMap { stage in
                        plan(for: theme, stage: stage).actors.flatMap(\.sprites)
                    }
                }
        )

        XCTAssertFalse(sprites.isEmpty)
        for sprite in sprites {
            let size = try XCTUnwrap(
                pngPixelSize(at: developmentCompanionResourceURL(sprite.resource)),
                "Missing or unreadable sprite strip: \(sprite.resource)"
            )
            XCTAssertGreaterThan(size.width, 0)
            XCTAssertGreaterThan(size.height, 0)
            XCTAssertLessThanOrEqual(
                size.height,
                96,
                "\(sprite.resource) exceeds the actor-strip decode budget"
            )
            XCTAssertEqual(
                size.width % sprite.frameCount,
                0,
                "\(sprite.resource) does not contain \(sprite.frameCount) equal-width frames"
            )
        }
    }

    private func plan(for theme: CompanionTheme, stage: Int) -> CompanionScenePlan {
        let variant = CompanionCatalog.variants(for: theme).first!
        let layers = CompanionAssetCatalog.scene(
            theme: theme,
            variant: variant,
            stage: stage,
            fraction: 0.5,
            seed: seed
        )?.layers ?? []
        return CompanionScenePlan.make(theme: theme, stage: stage, seed: seed, layers: layers)
    }

}
