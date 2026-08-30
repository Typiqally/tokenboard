import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import TokenboardApp
import TokenboardCore

final class CompanionJourneyTests: XCTestCase {
    func testMilestoneThresholdsAndStageBoundsStayStable() {
        XCTAssertEqual(
            CompanionJourney.thresholds,
            [0, 90_000_000, 180_000_000, 270_000_000, 360_000_000,
             450_000_000, 540_000_000, 630_000_000, 720_000_000,
             810_000_000, 900_000_000, 1_000_000_000]
        )
        XCTAssertEqual(CompanionJourney.stage(for: 0), 0)
        XCTAssertEqual(CompanionJourney.stage(for: 89_999_999), 0)
        XCTAssertEqual(CompanionJourney.stage(for: 90_000_000), 1)
        XCTAssertEqual(CompanionJourney.stage(for: 1_000_000_000), 11)
        XCTAssertEqual(CompanionJourney.stage(for: Int64.max), 11)
    }

    func testProgressFractionIsLocalToTheCurrentMilestone() {
        XCTAssertEqual(CompanionJourney.fraction(for: 0), 0, accuracy: 0.0001)
        XCTAssertEqual(CompanionJourney.fraction(for: 45_000_000), 0.5, accuracy: 0.0001)
        XCTAssertEqual(CompanionJourney.fraction(for: 135_000_000), 0.5, accuracy: 0.0001)
        XCTAssertEqual(CompanionJourney.fraction(for: 1_000_000_000), 1, accuracy: 0.0001)
    }

    func testDailyTokenSourceUsesOnlyTheCurrentTodaySnapshot() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        let date = calendar.date(from: DateComponents(year: 2026, month: 8, day: 26))!
        let today = try XCTUnwrap(calendar.dateInterval(of: .day, for: date))
        let yesterdayDate = try XCTUnwrap(
            calendar.date(byAdding: .day, value: -1, to: date)
        )
        let yesterday = try XCTUnwrap(calendar.dateInterval(of: .day, for: yesterdayDate))

        XCTAssertEqual(
            CompanionDailyTokenSource.total(
                from: historySnapshot(tokenTotal: 94_711_097, interval: today),
                at: date,
                calendar: calendar
            ),
            94_711_097
        )
        XCTAssertEqual(
            CompanionDailyTokenSource.total(
                from: historySnapshot(tokenTotal: 1_400_000_000, interval: yesterday),
                at: date,
                calendar: calendar
            ),
            0
        )
        XCTAssertEqual(
            CompanionDailyTokenSource.total(from: nil, at: date, calendar: calendar),
            0
        )
    }

    func testThemeCatalogIncludesCleanDefaultAndApprovedVariantCounts() {
        XCTAssertEqual(
            CompanionTheme.allCases,
            [.none, .pokemon, .forest, .village, .oldSchoolRuneScape, .ageOfEmpiresII, .minecraft, .banished, .frostpunk]
        )
        XCTAssertEqual(CompanionCatalog.variants(for: .none).count, 0)
        XCTAssertEqual(CompanionCatalog.variants(for: .pokemon).count, 12)
        XCTAssertEqual(CompanionCatalog.variants(for: .forest).count, 1)
        XCTAssertEqual(CompanionCatalog.variants(for: .village).count, 1)
        XCTAssertEqual(CompanionCatalog.variants(for: .oldSchoolRuneScape).count, 1)
        XCTAssertEqual(CompanionCatalog.variants(for: .ageOfEmpiresII).count, 1)
        XCTAssertEqual(CompanionCatalog.variants(for: .minecraft).count, 1)
        XCTAssertEqual(CompanionCatalog.variants(for: .banished).count, 1)
        XCTAssertEqual(CompanionCatalog.variants(for: .frostpunk).count, 1)
    }

    func testDailyVariantIsStableAndVisitsEveryVariantBeforeRepeating() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        let start = calendar.date(from: DateComponents(year: 2026, month: 8, day: 20))!
        let indices = (0..<12).map { offset in
            CompanionDailyVariantSelector.index(
                theme: .pokemon,
                seed: 42,
                date: calendar.date(byAdding: .day, value: offset, to: start)!,
                calendar: calendar,
                variantCount: 12
            )
        }

        XCTAssertEqual(Set(indices), Set(0..<12))
        XCTAssertEqual(
            CompanionDailyVariantSelector.index(
                theme: .pokemon,
                seed: 42,
                date: start,
                calendar: calendar,
                variantCount: 12
            ),
            indices[0]
        )
    }

    func testPresentationNamesDailyVariantStageAndRemainingProgress() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        let date = calendar.date(from: DateComponents(year: 2026, month: 8, day: 23))!
        let state = CompanionState(
            theme: .oldSchoolRuneScape,
            showInMenuBar: true,
            seed: 19
        )

        let presentation = try XCTUnwrap(CompanionPresentation.make(
            state: state,
            dailyTokenTotal: 275_000_000,
            date: date,
            calendar: calendar
        ))

        XCTAssertEqual(presentation.stage, 3)
        XCTAssertEqual(presentation.stageTitle, "Snakeskin")
        XCTAssertEqual(
            presentation.progressFraction, 5_000_000.0 / 90_000_000.0, accuracy: 0.0001
        )
        XCTAssertEqual(presentation.tokensUntilNextStage, 85_000_000)
        XCTAssertTrue(presentation.accessibilityLabel.contains("Old School RuneScape"))
        XCTAssertFalse(presentation.variant.title.isEmpty)
    }

    func testShelfPreviewUsesFixedRenderProgress() {
        let variant = CompanionVariant(id: "wildwood", title: "Wildwood")
        let live = CompanionPresentation(
            theme: .forest,
            variant: variant,
            stage: 7,
            scenery: 2,
            seed: 17,
            stageTitle: "Old growth",
            progressFraction: 0.93,
            tokensUntilNextStage: 1,
            accessibilityLabel: "Forest preview source"
        )

        let preview = CompanionPresentation.shelfPreview(from: live)

        XCTAssertEqual(preview.stage, CompanionAssetCatalog.shelfPreviewStage(for: .forest))
        XCTAssertEqual(preview.scenery, 0)
        XCTAssertEqual(preview.progressFraction, 0)
        XCTAssertNil(preview.tokensUntilNextStage)
    }

    @MainActor
    func testMenuIconIsTemplateSizedAndChangesWithTheJourneyStage() {
        let sapling = CompanionMenuIconRenderer.image(
            theme: .forest,
            variant: CompanionVariant(id: "wildwood", title: "Wildwood"),
            stage: 2
        )
        let landmark = CompanionMenuIconRenderer.image(
            theme: .forest,
            variant: CompanionVariant(id: "wildwood", title: "Wildwood"),
            stage: 7
        )

        XCTAssertEqual(sapling.size, NSSize(width: 18, height: 18))
        XCTAssertTrue(sapling.isTemplate)
        XCTAssertNotEqual(sapling.tiffRepresentation, landmark.tiffRepresentation)
    }

    @MainActor
    func testEveryMenuIconIsASilhouetteRatherThanARectangle() throws {
        for theme in CompanionTheme.allCases where theme != .none {
            let variant = try XCTUnwrap(CompanionCatalog.variants(for: theme).first)
            var renderedStages: Set<Data> = []
            for stage in 0..<CompanionJourney.thresholds.count {
                let icon = CompanionMenuIconRenderer.image(
                    theme: theme,
                    variant: variant,
                    stage: stage
                )
                XCTAssertEqual(icon.size, NSSize(width: 18, height: 18))
                XCTAssertTrue(icon.isTemplate, "\(theme.title) stage \(stage + 1)")

                var proposedRect = NSRect(origin: .zero, size: icon.size)
                let cgImage = try XCTUnwrap(
                    icon.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil)
                )
                let bitmap = NSBitmapImageRep(cgImage: cgImage)
                let width = bitmap.pixelsWide
                let height = bitmap.pixelsHigh
                var opaquePixels = 0
                for x in 0..<width {
                    for y in 0..<height
                    where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 {
                        opaquePixels += 1
                    }
                }
                let coverage = Double(opaquePixels) / Double(width * height)
                XCTAssertGreaterThan(
                    coverage, 0.05,
                    "\(theme.title) stage \(stage + 1) icon is nearly empty"
                )
                XCTAssertLessThan(
                    coverage, 0.92,
                    "\(theme.title) stage \(stage + 1) icon fills the frame like a photo"
                )
                for (x, y) in [(0, 0), (width - 1, 0), (0, height - 1), (width - 1, height - 1)] {
                    XCTAssertLessThan(
                        bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0,
                        0.5,
                        "\(theme.title) stage \(stage + 1) icon has an opaque corner"
                    )
                }
                if let tiff = icon.tiffRepresentation {
                    renderedStages.insert(tiff)
                }
                try writeSnapshotIfRequested(
                    silhouettePreview(of: icon),
                    name: "icon-\(theme.rawValue)-stage-\(stage + 1)"
                )
            }
            // A Pokémon's silhouette changes only when it evolves; every
            // other journey changes shape at each stage.
            let expectedDistinctIcons = theme == .pokemon ? 3 : 6
            XCTAssertGreaterThanOrEqual(
                renderedStages.count, expectedDistinctIcons,
                "\(theme.title) menu icons barely change across the journey"
            )
        }
    }

    @MainActor
    func testEveryCompanionStageRendersAtItsApprovedSize() throws {
        for theme in CompanionTheme.allCases where theme != .none {
            let variant = try XCTUnwrap(CompanionCatalog.variants(for: theme).first)
            for stage in 0..<CompanionJourney.thresholds.count {
                for scenery in 0..<CompanionAssetCatalog.sceneryCount(for: theme) {
                    let presentation = CompanionPresentation(
                        theme: theme,
                        variant: variant,
                        stage: stage,
                        scenery: scenery,
                        seed: 7,
                        stageTitle: "Stage \(stage + 1)",
                        progressFraction: 0.42,
                        tokensUntilNextStage: 190_000_000,
                        accessibilityLabel: "\(theme.title), stage \(stage + 1) of 8"
                    )
                    let renderer = ImageRenderer(
                        content: CompanionStrip(presentation: presentation)
                    )
                    renderer.scale = 2
                    let image = try XCTUnwrap(
                        renderer.nsImage,
                        "Failed to render \(theme.title), stage \(stage + 1), scenery \(scenery)"
                    )
                    XCTAssertEqual(image.size, NSSize(width: 350, height: 84))
                    XCTAssertNotNil(image.tiffRepresentation)
                    try writeSnapshotIfRequested(
                        image,
                        name: "\(theme.rawValue)-stage-\(stage + 1)-\(scenery)"
                    )
                }
            }
        }
    }

    @MainActor
    func testPanoramaGivesTheCompanionAnApprovedTopThirdStage() throws {
        let theme = CompanionTheme.oldSchoolRuneScape
        let variant = try XCTUnwrap(CompanionCatalog.variants(for: theme).first)
        let presentation = CompanionPresentation(
            theme: theme,
            variant: variant,
            stage: 0,
            scenery: 0,
            seed: 7,
            stageTitle: "Stage 1",
            progressFraction: 0.42,
            tokensUntilNextStage: 190_000_000,
            accessibilityLabel: "Old School RuneScape panorama"
        )
        let renderer = ImageRenderer(
            content: CompanionPanorama(presentation: presentation)
        )
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        XCTAssertEqual(image.size, NSSize(width: 350, height: 224))
        try writeSnapshotIfRequested(image, name: "panorama-osrs")

        let composition = CompanionSceneComposition.make(
            presentation: presentation,
            size: NSSize(width: 350, height: 224),
            layout: .panorama
        )
        let hero = try XCTUnwrap(composition.placements.first)
        XCTAssertGreaterThanOrEqual(hero.rect.height, 74)
        XCTAssertLessThanOrEqual(hero.rect.height, 84)
    }

    @MainActor
    func testCompanionStripDrawsTheJourneyProgressLineAlongItsBottomEdge() throws {
        for theme in CompanionTheme.allCases where theme != .none {
            let variant = try XCTUnwrap(CompanionCatalog.variants(for: theme).first)
            let presentation = CompanionPresentation(
                theme: theme,
                variant: variant,
                stage: 3,
                scenery: 0,
                seed: 7,
                stageTitle: "Stage 4",
                progressFraction: 0.42,
                tokensUntilNextStage: 1_000_000,
                accessibilityLabel: "\(theme.title) progress preview"
            )
            let renderer = ImageRenderer(
                content: CompanionStrip(presentation: presentation)
            )
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.nsImage)
            let data = try XCTUnwrap(image.tiffRepresentation)
            let rep = try XCTUnwrap(NSBitmapImageRep(data: data))
            // The 3-point line hugs the bottom edge, under the 1-point
            // hairline: sample inside the line, above the hairline.
            let y = rep.pixelsHigh - 4
            func luminance(atX x: Int) -> CGFloat {
                let color = rep.colorAt(x: x, y: y)?
                    .usingColorSpace(.deviceRGB) ?? .black
                return 0.299 * color.redComponent
                    + 0.587 * color.greenComponent
                    + 0.114 * color.blueComponent
            }
            let filled = luminance(atX: Int(Double(rep.pixelsWide) * 0.2))
            let track = luminance(atX: Int(Double(rep.pixelsWide) * 0.9))
            XCTAssertGreaterThan(
                filled,
                track + 0.1,
                "\(theme.title): the filled 42% must read brighter than the track"
            )
        }
    }

    func testDailySceneryRotationVisitsEveryPlateWithoutRepeating() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        let state = CompanionState(
            theme: .forest,
            showInMenuBar: false,
            seed: 11
        )
        let start = calendar.date(from: DateComponents(year: 2026, month: 8, day: 20))!
        let picks = try (0..<3).map { offset -> Int in
            let day = calendar.date(byAdding: .day, value: offset, to: start)!
            return try XCTUnwrap(
                CompanionPresentation.make(
                    state: state,
                    dailyTokenTotal: 0,
                    date: day,
                    calendar: calendar
                )
            ).scenery
        }
        XCTAssertEqual(
            Set(picks),
            Set(0..<CompanionAssetCatalog.sceneryCount(for: .forest)),
            "three consecutive days must visit all three plates"
        )
        let again = try XCTUnwrap(
            CompanionPresentation.make(
                state: state,
                dailyTokenTotal: 0,
                date: start,
                calendar: calendar
            )
        ).scenery
        XCTAssertEqual(again, picks[0], "the pick must be stable within a day")
    }

    @MainActor
    func testEveryPokemonFamilyRendersItsKeyStagesAtApprovedSize() throws {
        let variants = CompanionCatalog.variants(for: .pokemon)
        for variant in variants {
            for stage in [0, 4, 8, 11] {
                let presentation = CompanionPresentation(
                    theme: .pokemon,
                    variant: variant,
                    stage: stage,
                    scenery: 0,
                    seed: 7,
                    stageTitle: "Stage \(stage + 1)",
                    progressFraction: 0.5,
                    tokensUntilNextStage: nil,
                    accessibilityLabel: "Pokémon, \(variant.title), stage \(stage + 1) of 8"
                )
                let renderer = ImageRenderer(
                    content: CompanionStrip(presentation: presentation)
                )
                renderer.scale = 2
                let image = try XCTUnwrap(
                    renderer.nsImage,
                    "Failed to render \(variant.title), stage \(stage + 1)"
                )
                XCTAssertEqual(image.size, NSSize(width: 350, height: 84))
                try writeSnapshotIfRequested(
                    image,
                    name: "family-\(variant.id)-stage-\(stage + 1)"
                )
            }
        }
    }

    /// Renders the icon's alpha channel the way the menu bar would: as a
    /// solid silhouette, magnified for inspection.
    private func silhouettePreview(of icon: NSImage) -> NSImage {
        NSImage(size: NSSize(width: 72, height: 72), flipped: false) { destination in
            NSColor.white.setFill()
            destination.fill()
            guard let tinted = icon.copy() as? NSImage else { return false }
            NSGraphicsContext.current?.imageInterpolation = .none
            tinted.draw(
                in: destination,
                from: .zero,
                operation: .sourceOver,
                fraction: 1
            )
            return true
        }
    }

    @MainActor
    func testShelfThumbnailScenesRenderAtTileSize() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        let date = calendar.date(from: DateComponents(year: 2026, month: 8, day: 23))!
        for theme in CompanionTheme.allCases where theme != .none {
            let state = CompanionState(
                theme: theme,
                showInMenuBar: false,
                seed: 7
            )
            let live = try XCTUnwrap(
                CompanionPresentation.make(
                    state: state,
                    dailyTokenTotal: 0,
                    date: date,
                    calendar: calendar
                )
            )
            let shelf = live.preview(
                stage: CompanionAssetCatalog.shelfPreviewStage(for: theme),
                accessibilityLabel: "\(theme.title) preview"
            )
            let renderer = ImageRenderer(
                content: CompanionSceneView(presentation: shelf)
                    .frame(width: 116, height: 48)
            )
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.nsImage)
            XCTAssertEqual(image.size, NSSize(width: 116, height: 48))
            try writeSnapshotIfRequested(image, name: "shelf-\(theme.rawValue)")
        }
    }

    private func writeSnapshotIfRequested(_ image: NSImage, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment[
            "TOKENBOARD_COMPANION_SNAPSHOT_DIR"
        ] else { return }
        let directoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let representation = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: representation))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: directoryURL.appending(path: "\(name).png"))
    }

    private func historySnapshot(
        tokenTotal: Int64,
        interval: DateInterval
    ) -> UsageHistorySnapshot {
        UsageHistorySnapshot(
            range: .today,
            provider: nil,
            currentInterval: interval,
            previousInterval: interval,
            points: [],
            comparison: UsageComparison(
                currentTokenTotal: tokenTotal,
                previousTokenTotal: 0,
                tokenDelta: tokenTotal,
                percentChange: nil
            ),
            breakdown: UsageBreakdown(
                tokenTotal: tokenTotal,
                knownAPIEquivalentUSD: 0,
                unpricedTokens: 0,
                exchangeRates: nil,
                providers: [],
                models: [],
                tokenTypes: []
            )
        )
    }
}
