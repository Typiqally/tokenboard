import Foundation
import XCTest
@testable import TokenboardApp

final class CompanionArtworkAssetTests: XCTestCase {
    func testEveryVisibleThemeAndStageResolvesToBundledArtwork() throws {
        for theme in CompanionTheme.allCases where theme != .none {
            let variants = CompanionCatalog.variants(for: theme)
            XCTAssertFalse(variants.isEmpty, "\(theme.title) needs built-in artwork")

            for variant in variants {
                for stage in 0..<CompanionJourney.thresholds.count {
                    let scene = try XCTUnwrap(
                        CompanionAssetCatalog.scene(
                            theme: theme,
                            variant: variant,
                            stage: stage
                        ),
                        "Missing \(theme.title), \(variant.title), stage \(stage + 1)"
                    )

                    XCTAssertFalse(scene.backgroundResource.isEmpty)
                    XCTAssertFalse(scene.allResources.isEmpty)
                    for resource in scene.allResources {
                        XCTAssertFalse(resource.hasPrefix("/"), resource)
                        XCTAssertFalse(resource.contains("://"), resource)
                        XCTAssertTrue(
                            FileManager.default.fileExists(
                                atPath: developmentResourceURL(resource).path
                            ),
                            "Missing bundled companion asset: \(resource)"
                        )
                    }
                }
            }
        }
    }

    func testNoneNeverResolvesArtwork() {
        XCTAssertNil(
            CompanionAssetCatalog.scene(
                theme: .none,
                variant: CompanionVariant(id: "none", title: "None"),
                stage: 0
            )
        )
    }

    func testStageLookupClampsToTheEightStageJourney() throws {
        let variant = try XCTUnwrap(CompanionCatalog.variants(for: .tree).first)

        XCTAssertEqual(
            CompanionAssetCatalog.scene(theme: .tree, variant: variant, stage: -1),
            CompanionAssetCatalog.scene(theme: .tree, variant: variant, stage: 0)
        )
        XCTAssertEqual(
            CompanionAssetCatalog.scene(theme: .tree, variant: variant, stage: 99),
            CompanionAssetCatalog.scene(theme: .tree, variant: variant, stage: 7)
        )
    }

    func testTreeArtworkGrowsAcrossTheJourney() throws {
        let variant = try XCTUnwrap(CompanionCatalog.variants(for: .tree).first)
        let heights = try (0..<CompanionJourney.thresholds.count).map { stage in
            try XCTUnwrap(
                CompanionAssetCatalog.scene(theme: .tree, variant: variant, stage: stage)?
                    .layers.first?.relativeHeight
            )
        }

        XCTAssertEqual(heights, heights.sorted())
        XCTAssertLessThan(try XCTUnwrap(heights.first), try XCTUnwrap(heights.last))
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(heights.first), 0.18)
    }

    func testSourceArtworkCompositesWithoutObscuringTheSceneOrEquipment() throws {
        let tree = try XCTUnwrap(CompanionCatalog.variants(for: .tree).first)
        let treeLayer = try XCTUnwrap(
            CompanionAssetCatalog.scene(theme: .tree, variant: tree, stage: 7)?
                .layers.first
        )
        XCTAssertEqual(treeLayer.blendMode, .multiply)
        XCTAssertLessThan(try XCTUnwrap(treeLayer.crop).height, 0.95)

        let ranger = try XCTUnwrap(
            CompanionCatalog.variants(for: .oldSchoolRuneScape).first
        )
        let rangerLayer = try XCTUnwrap(
            CompanionAssetCatalog.scene(
                theme: .oldSchoolRuneScape,
                variant: ranger,
                stage: 7
            )?.layers.first
        )
        XCTAssertLessThanOrEqual(rangerLayer.relativeHeight, 1.15)
    }

    func testAgeOfEmpiresKeepsTheFullResolutionTownCenterArtwork() throws {
        let townCenter = try XCTUnwrap(
            CompanionCatalog.variants(for: .ageOfEmpiresII).first
        )
        for stage in 0..<CompanionJourney.thresholds.count {
            let scene = try XCTUnwrap(
                CompanionAssetCatalog.scene(
                    theme: .ageOfEmpiresII,
                    variant: townCenter,
                    stage: stage
                )
            )
            XCTAssertNil(scene.backgroundCrop)
        }
    }

    private func developmentResourceURL(_ resource: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Resources/Companions")
            .appending(path: resource)
    }
}
