import XCTest
@testable import TokenboardApp

/// Every per-stage table in the companion feature must span the whole journey
/// for every theme. Several tables are parallel arrays indexed by stage, so a
/// table that falls out of sync with `CompanionJourney.thresholds` would crash
/// at first render; this suite resolves every stage of every theme through
/// every stage-indexed surface, turning any future mismatch into a named
/// failure here instead.
@MainActor
final class CompanionStageCoverageTests: XCTestCase {
    private let seed: UInt64 = 0x5EED_C0FF_EE12_3456
    private let date = Date(timeIntervalSinceReferenceDate: 809_913_600)

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private var themes: [CompanionTheme] {
        CompanionTheme.allCases.filter { $0 != .none }
    }

    private var stageCount: Int { CompanionJourney.thresholds.count }

    func testEveryThemeResolvesEveryStageAcrossEverySurface() throws {
        for theme in themes {
            let variant = try XCTUnwrap(
                CompanionCatalog.variants(for: theme).first,
                "\(theme) has no variants"
            )
            for stage in 0..<stageCount {
                let label = "\(theme) stage \(stage)"

                for scenery in 0..<CompanionAssetCatalog.sceneryCount(for: theme) {
                    let scene = CompanionAssetCatalog.scene(
                        theme: theme,
                        variant: variant,
                        stage: stage,
                        scenery: scenery,
                        fraction: 0.5,
                        seed: seed
                    )
                    XCTAssertNotNil(scene, "\(label) scenery \(scenery) resolves no scene")
                    XCTAssertFalse(
                        scene?.backgroundResource.isEmpty ?? true,
                        "\(label) scenery \(scenery) has no background"
                    )
                }

                let presentation = CompanionPresentation.make(
                    state: CompanionState(theme: theme, showInMenuBar: false, seed: seed),
                    dailyTokenTotal: CompanionJourney.thresholds[stage],
                    date: date,
                    calendar: calendar
                )
                XCTAssertEqual(presentation?.stage, stage, label)
                XCTAssertFalse(
                    presentation?.stageTitle.isEmpty ?? true,
                    "\(label) has no stage title"
                )

                let layers = CompanionAssetCatalog.scene(
                    theme: theme,
                    variant: variant,
                    stage: stage,
                    fraction: 0.5,
                    seed: seed
                )?.layers ?? []
                _ = CompanionScenePlan.make(theme: theme, stage: stage, seed: seed, layers: layers)

                let iconResource = CompanionAssetCatalog.menuIconResource(
                    theme: theme,
                    variant: variant,
                    stage: stage
                )
                if [.ageOfEmpiresII, .banished, .frostpunk].contains(theme) {
                    XCTAssertNil(iconResource, "\(label) draws a glyph, not a resource")
                } else {
                    XCTAssertNotNil(iconResource, "\(label) has no menu icon resource")
                }
                _ = CompanionMenuIconRenderer.image(theme: theme, variant: variant, stage: stage)
            }
        }
    }

    func testStagesBeyondTheJourneyClampInsteadOfCrashing() throws {
        let beyond = stageCount + 1
        for theme in themes {
            let variant = try XCTUnwrap(CompanionCatalog.variants(for: theme).first)
            let clamped = CompanionAssetCatalog.scene(
                theme: theme,
                variant: variant,
                stage: beyond,
                fraction: 0.5,
                seed: seed
            )
            let final = CompanionAssetCatalog.scene(
                theme: theme,
                variant: variant,
                stage: stageCount - 1,
                fraction: 0.5,
                seed: seed
            )
            XCTAssertEqual(
                clamped?.backgroundResource,
                final?.backgroundResource,
                "\(theme) beyond-final stage must clamp to the summit"
            )
            _ = CompanionScenePlan.make(theme: theme, stage: beyond, seed: seed, layers: clamped?.layers ?? [])
            _ = CompanionAssetCatalog.menuIconResource(theme: theme, variant: variant, stage: beyond)
            _ = CompanionMenuIconRenderer.image(theme: theme, variant: variant, stage: beyond)
        }

        let summitPresentation = CompanionPresentation.make(
            state: CompanionState(theme: .forest, showInMenuBar: false, seed: seed),
            dailyTokenTotal: CompanionJourney.thresholds[stageCount - 1] * 2,
            date: date,
            calendar: calendar
        )
        XCTAssertEqual(summitPresentation?.stage, stageCount - 1)
        XCTAssertEqual(summitPresentation?.progressFraction, 1)
        XCTAssertNil(summitPresentation?.tokensUntilNextStage)
    }

    func testThemeNoneResolvesNothing() {
        XCTAssertNil(
            CompanionPresentation.make(
                state: CompanionState(theme: .none, showInMenuBar: false, seed: seed),
                dailyTokenTotal: 1_000_000,
                date: date,
                calendar: calendar
            )
        )
        XCTAssertNil(
            CompanionAssetCatalog.scene(
                theme: .none,
                variant: CompanionVariant(id: "none", title: "None"),
                stage: 0,
                fraction: 0,
                seed: seed
            )
        )
    }
}
