import AppKit
import Foundation
import XCTest
@testable import TokenboardApp

/// The village's lights are read out of the artwork itself. If detection
/// drifts, the town either stops switching or starts repainting walls.
@MainActor
final class CompanionWindowMapTests: XCTestCase {
    func testTheBakedWindowPaletteIsWhatGetsClassified() {
        // The two colours `Scripts/generate-companion-artwork.swift` paints
        // windows with.
        XCTAssertEqual(tone(255, 217, 138), .lit)
        XCTAssertEqual(tone(236, 204, 136), .lit, "a shaded facade is still lit")
        XCTAssertEqual(tone(46, 58, 84), .dark)

        // Walls, roofs, sky, and the daylight window tint must never match.
        XCTAssertNil(tone(118, 123, 140), "high-rise wall")
        XCTAssertNil(tone(108, 68, 70), "brick wall")
        XCTAssertNil(tone(111, 60, 58), "timber roof")
        XCTAssertNil(tone(147, 143, 139), "timber wall")
        XCTAssertNil(tone(84, 113, 138), "a daylight window is not a light")
        XCTAssertNil(tone(15, 25, 33), "the sprite's own contact shadow")
    }

    func testEveryLitVillageSpriteReportsItsOwnWindows() throws {
        for style in CompanionAssetCatalog.villageStyles {
            for level in 0..<4 {
                let resource = "Village/sprites/\(style)-\(level)-lit.png"
                let windows = CompanionWindowMapStore.windows(resource: resource)
                XCTAssertFalse(windows.isEmpty, "\(resource) has no detectable windows")
                XCTAssertTrue(
                    windows.contains(where: \.bakedLit),
                    "\(resource) has no lit window to switch off"
                )
                for window in windows {
                    XCTAssertTrue((0...1).contains(window.x), resource)
                    XCTAssertTrue((0...1).contains(window.y), resource)
                    XCTAssertGreaterThan(window.width, 0)
                    XCTAssertGreaterThan(window.height, 0)
                    XCTAssertLessThanOrEqual(window.x + window.width, 1.0001, resource)
                    XCTAssertLessThanOrEqual(window.y + window.height, 1.0001, resource)
                }
            }
        }
    }

    func testWindowsAreFoundBelowTheRoofNotOnIt() {
        // A cottage is roof on top, facade underneath. If the bitmap's rows
        // were read upside down, every window would land in the roof.
        let windows = CompanionWindowMapStore.windows(
            resource: "Village/sprites/timber-1-lit.png"
        )
        XCTAssertFalse(windows.isEmpty)
        for window in windows {
            XCTAssertGreaterThan(
                window.y, 0.3,
                "a window was detected inside the roof — rows are flipped"
            )
        }
    }

    func testDaylightSpritesHaveNoLightsToSwitch() {
        for style in CompanionAssetCatalog.villageStyles {
            let windows = CompanionWindowMapStore.windows(
                resource: "Village/sprites/\(style)-2-day.png"
            )
            XCTAssertTrue(
                windows.allSatisfy { !$0.bakedLit },
                "\(style) is lit in broad daylight"
            )
        }
    }

    func testDetectionIsCachedAndStable() {
        let first = CompanionWindowMapStore.windows(
            resource: "Village/sprites/brick-3-lit.png"
        )
        let second = CompanionWindowMapStore.windows(
            resource: "Village/sprites/brick-3-lit.png"
        )
        XCTAssertEqual(first, second)
    }

    func testMissingArtworkYieldsNoWindowsInsteadOfFailing() {
        XCTAssertTrue(
            CompanionWindowMapStore.windows(resource: "Village/sprites/nope.png").isEmpty
        )
    }

    private func tone(_ red: Int, _ green: Int, _ blue: Int) -> CompanionWindowTone? {
        CompanionWindowMapStore.classify(
            red: Double(red) / 255,
            green: Double(green) / 255,
            blue: Double(blue) / 255
        )
    }
}

/// The chain from journey state to a drawable scene: layout, plate crop, and
/// which buildings hand the renderer real windows to switch.
@MainActor
final class CompanionSceneCompositionTests: XCTestCase {
    private let size = CGSize(width: 350, height: 84)

    func testANightTownHandsTheRendererRealWindowsToSwitch() throws {
        let composition = try make(theme: .village, stage: 10)
        XCTAssertFalse(composition.placements.isEmpty)
        let windows = composition.placements.reduce(0) { $0 + $1.windows.count }
        XCTAssertGreaterThan(windows, 40, "a lit city should have windows to switch")
        XCTAssertTrue(
            composition.placements.allSatisfy { $0.layer.role == .building }
        )
    }

    func testADaylightTownHasNoLightsToSwitch() throws {
        let composition = try make(theme: .village, stage: 3)
        XCTAssertFalse(composition.placements.isEmpty)
        XCTAssertTrue(
            composition.placements.allSatisfy(\.windows.isEmpty),
            "daylight buildings must not be repainted"
        )
    }

    func testNoOtherWorldEverRepaintsItsSubjects() throws {
        for theme in CompanionTheme.allCases where theme != .none && theme != .village {
            let composition = try make(theme: theme, stage: 10)
            XCTAssertTrue(
                composition.placements.allSatisfy(\.windows.isEmpty),
                "\(theme.title) is not a town"
            )
        }
    }

    func testThePlateFillsTheBandAndKeepsItsGroundLine() throws {
        let composition = try make(theme: .pokemon, stage: 4)
        let rect = composition.backgroundRect
        XCTAssertEqual(rect.maxY, size.height, accuracy: 0.001, "the ground line is the band's floor")
        XCTAssertGreaterThanOrEqual(rect.width, size.width - 0.001)
        XCTAssertGreaterThanOrEqual(rect.height, size.height - 0.001, "the plate must fill the band")
        XCTAssertLessThan(rect.minY, 0.001, "a wider band trims sky, never ground")
        XCTAssertGreaterThan(composition.artPixel, 0)
    }

    func testSubjectsStandOnTheGroundLineTheCatalogPlacedThem() throws {
        let composition = try make(theme: .minecraft, stage: 5)
        let placement = try XCTUnwrap(composition.placements.first)
        let expectedBottom = size.height - size.height * placement.layer.bottomOffset
        XCTAssertEqual(placement.rect.maxY, expectedBottom, accuracy: 0.001)
        XCTAssertEqual(
            placement.rect.midX,
            size.width * placement.layer.horizontalPosition,
            accuracy: 0.001
        )
        XCTAssertGreaterThan(placement.rect.width, 0)
    }

    func testNoneComposesNothingToDraw() throws {
        let composition = CompanionSceneComposition.make(
            presentation: presentation(theme: .none, variant: nil, stage: 0),
            size: size
        )
        XCTAssertNil(composition.asset)
        XCTAssertTrue(composition.placements.isEmpty)
        XCTAssertEqual(composition.plan, .inert)
    }

    private func make(theme: CompanionTheme, stage: Int) throws -> CompanionSceneComposition {
        let variant = try XCTUnwrap(CompanionCatalog.variants(for: theme).first)
        return CompanionSceneComposition.make(
            presentation: presentation(theme: theme, variant: variant, stage: stage),
            size: size
        )
    }

    private func presentation(
        theme: CompanionTheme,
        variant: CompanionVariant?,
        stage: Int
    ) -> CompanionPresentation {
        CompanionPresentation(
            theme: theme,
            variant: variant ?? CompanionVariant(id: "none", title: "None"),
            stage: stage,
            scenery: 0,
            seed: 0x1234_5678,
            stageTitle: "",
            progressFraction: 0.6,
            tokensUntilNextStage: 1,
            accessibilityLabel: ""
        )
    }
}
