import AppKit
import XCTest
@testable import TokenboardApp

/// The companion feature degrades gracefully on purpose — a missing plate is
/// a nil, not a crash — but silence made every degrade invisible. These tests
/// pin that each failure path records why it degraded, exactly once, while
/// still returning the same graceful nothing it always did.
@MainActor
final class CompanionDiagnosticsTests: XCTestCase, CompanionSceneFixtures {
    func testRecordingDeduplicatesRepeatedIssues() {
        let diagnostics = CompanionDiagnostics()
        diagnostics.record(.missingAsset(resource: "a.png"))
        diagnostics.record(.missingAsset(resource: "a.png"))
        diagnostics.record(.missingAsset(resource: "b.png"))
        XCTAssertEqual(diagnostics.issues, [
            .missingAsset(resource: "a.png"),
            .missingAsset(resource: "b.png")
        ])
    }

    func testSummaryStaysQuietUntilSomethingDegrades() {
        let diagnostics = CompanionDiagnostics()
        XCTAssertEqual(diagnostics.summary, "All assets resolved")
        diagnostics.record(.missingAsset(resource: "a.png"))
        XCTAssertEqual(diagnostics.summary, "1 issue")
        diagnostics.record(.unreadableWindowMap(resource: "b.png"))
        XCTAssertEqual(diagnostics.summary, "2 issues")
    }

    func testAMissingImageRecordsTheAssetAndStillReturnsNil() {
        let diagnostics = CompanionDiagnostics()
        let image = CompanionAssetImageStore.image(
            resource: "Nowhere/not-a-real-plate.png",
            diagnostics: diagnostics
        )
        XCTAssertNil(image)
        XCTAssertEqual(
            diagnostics.issues,
            [.missingAsset(resource: "Nowhere/not-a-real-plate.png")]
        )
    }

    func testAnUnresolvableSceneRecordsThemeAndStage() {
        let diagnostics = CompanionDiagnostics()
        // A Pokémon variant outside the catalog resolves no evolution line,
        // so the catalog returns no scene for it.
        let presentation = CompanionPresentation(
            theme: .pokemon,
            variant: CompanionVariant(id: "missingno", title: "MissingNo"),
            stage: 3,
            scenery: 0,
            seed: seed,
            stageTitle: "Stage 4",
            progressFraction: 0.5,
            tokensUntilNextStage: 1,
            accessibilityLabel: ""
        )
        let composition = CompanionSceneComposition.make(
            presentation: presentation,
            size: CGSize(width: 350, height: 84),
            diagnostics: diagnostics
        )
        XCTAssertNil(composition.asset)
        XCTAssertEqual(diagnostics.issues, [.unresolvedScene(theme: .pokemon, stage: 3)])
    }

    func testAnUnreadableSpriteBitmapIsDistinguishedFromAWindowlessOne() throws {
        // No representations at all: the detector cannot read this sprite.
        XCTAssertNil(CompanionWindowMapStore.detect(in: NSImage(size: .zero)))

        // A real forest sprite reads fine and genuinely has no windows.
        let sprite = try XCTUnwrap(
            CompanionAssetImageStore.image(resource: "Forest/sprites/oak-3.png")
        )
        XCTAssertEqual(CompanionWindowMapStore.detect(in: sprite), [])

        // Reading a windowless sprite's map is not a degrade and records
        // nothing.
        let diagnostics = CompanionDiagnostics()
        _ = CompanionWindowMapStore.windows(
            resource: "Forest/sprites/oak-3.png",
            diagnostics: diagnostics
        )
        XCTAssertEqual(diagnostics.issues, [])
    }

    func testAnUnsizableGrowthSpriteRecordsTheSpriteItSkipped() {
        let spec = CompanionGrowthSceneSpec(
            plan: CompanionAssetCatalog.forestGrowthPlan,
            slotKey: "forest/slots",
            frontBottom: 0.11,
            backBottom: 0.175,
            maturityAges: [0.1, 0.3, 0.5],
            layerIDPrefix: "broken-",
            role: .tree,
            style: { _ in "ghost" },
            cap: { _ in 3 },
            // The style every slot builds is missing from the table.
            cellHeights: [:],
            relativeHeight: { cells, _ in Double(cells) },
            resource: { style, level in "Forest/sprites/\(style)-\(level).png" },
            backgroundResource: "Forest/scenes/01-a.png"
        )
        let issuesBefore = CompanionDiagnostics.shared.issues.count
        let asset = CompanionGrowthScene.make(spec: spec, stage: 5, fraction: 0.5, seed: seed)
        XCTAssertTrue(asset.layers.isEmpty, "unsizable sprites are skipped, not crashed on")
        XCTAssertGreaterThan(CompanionDiagnostics.shared.issues.count, issuesBefore)
        XCTAssertTrue(
            CompanionDiagnostics.shared.issues
                .contains(.missingAsset(resource: "Forest/sprites/ghost-0.png"))
        )
    }
}
