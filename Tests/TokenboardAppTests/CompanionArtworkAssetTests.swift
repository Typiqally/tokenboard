import Foundation
import XCTest
@testable import TokenboardApp

final class CompanionArtworkAssetTests: XCTestCase {
    func testEveryVisibleThemeAndStageResolvesToBundledArtwork() throws {
        for theme in CompanionTheme.allCases where theme != .none {
            let variant = try XCTUnwrap(
                CompanionCatalog.variants(for: theme).first,
                "\(theme.title) needs at least one built-in variant"
            )

            for stage in 0..<CompanionJourney.thresholds.count {
                let scene = try XCTUnwrap(
                    CompanionAssetCatalog.scene(
                        theme: theme,
                        variant: variant,
                        stage: stage
                    ),
                    "Missing \(theme.title) stage \(stage + 1)"
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

    private func developmentResourceURL(_ resource: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Resources/Companions")
            .appending(path: resource)
    }
}
