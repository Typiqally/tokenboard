import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import TokenboardApp

final class CompanionJourneyTests: XCTestCase {
    func testMilestoneThresholdsAndStageBoundsStayStable() {
        XCTAssertEqual(
            CompanionJourney.thresholds,
            [0, 1_000_000, 4_000_000, 16_000_000, 64_000_000,
             160_000_000, 400_000_000, 1_000_000_000]
        )
        XCTAssertEqual(CompanionJourney.stage(for: 0), 0)
        XCTAssertEqual(CompanionJourney.stage(for: 999_999), 0)
        XCTAssertEqual(CompanionJourney.stage(for: 1_000_000), 1)
        XCTAssertEqual(CompanionJourney.stage(for: 1_000_000_000), 7)
        XCTAssertEqual(CompanionJourney.stage(for: Int64.max), 7)
    }

    func testProgressFractionIsLocalToTheCurrentMilestone() {
        XCTAssertEqual(CompanionJourney.fraction(for: 0), 0, accuracy: 0.0001)
        XCTAssertEqual(CompanionJourney.fraction(for: 500_000), 0.5, accuracy: 0.0001)
        XCTAssertEqual(CompanionJourney.fraction(for: 2_500_000), 0.5, accuracy: 0.0001)
        XCTAssertEqual(CompanionJourney.fraction(for: 1_000_000_000), 1, accuracy: 0.0001)
    }

    func testActivationStartsAtZeroAndOnlyFuturePositiveDeltasAdvance() {
        let activated = CompanionProgress.activate(at: 500_000_000)
        XCTAssertEqual(activated.earnedTokens, 0)
        XCTAssertEqual(activated.lastObservedLifetimeTotal, 500_000_000)

        let advanced = activated.observing(lifetimeTotal: 504_000_000)
        XCTAssertEqual(advanced.earnedTokens, 4_000_000)
        XCTAssertEqual(advanced.lastObservedLifetimeTotal, 504_000_000)
        XCTAssertEqual(advanced.stage, 2)
    }

    func testLowerLifetimeTotalRebasesWithoutLosingEarnedProgress() {
        let progress = CompanionProgress(
            earnedTokens: 16_000_000,
            lastObservedLifetimeTotal: 900_000_000,
            lastAcknowledgedStage: 2
        )

        let rebased = progress.observing(lifetimeTotal: 20_000)
        XCTAssertEqual(rebased.earnedTokens, 16_000_000)
        XCTAssertEqual(rebased.lastObservedLifetimeTotal, 20_000)
        XCTAssertEqual(rebased.lastAcknowledgedStage, 2)

        let resumed = rebased.observing(lifetimeTotal: 30_000)
        XCTAssertEqual(resumed.earnedTokens, 16_010_000)
    }

    func testProgressSaturatesInsteadOfOverflowing() {
        let progress = CompanionProgress(
            earnedTokens: Int64.max - 2,
            lastObservedLifetimeTotal: 5,
            lastAcknowledgedStage: 7
        )

        XCTAssertEqual(
            progress.observing(lifetimeTotal: Int64.max).earnedTokens,
            Int64.max
        )
    }

    func testThemeCatalogIncludesCleanDefaultAndApprovedVariantCounts() {
        XCTAssertEqual(CompanionTheme.allCases, [.none, .pokemon, .tree, .tower, .oldSchoolRuneScape, .ageOfEmpiresII])
        XCTAssertEqual(CompanionCatalog.variants(for: .none).count, 0)
        XCTAssertEqual(CompanionCatalog.variants(for: .pokemon).count, 12)
        XCTAssertEqual(CompanionCatalog.variants(for: .tree).count, 1)
        XCTAssertEqual(CompanionCatalog.variants(for: .tower).count, 1)
        XCTAssertEqual(CompanionCatalog.variants(for: .oldSchoolRuneScape).count, 1)
        XCTAssertEqual(CompanionCatalog.variants(for: .ageOfEmpiresII).count, 1)
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
            progress: CompanionProgress(
                earnedTokens: 4_000_000,
                lastObservedLifetimeTotal: 20_000_000,
                lastAcknowledgedStage: 1
            ),
            seed: 19
        )

        let presentation = try XCTUnwrap(CompanionPresentation.make(
            state: state,
            date: date,
            calendar: calendar
        ))

        XCTAssertEqual(presentation.stage, 2)
        XCTAssertEqual(presentation.stageTitle, "Green d’hide")
        XCTAssertEqual(presentation.progressFraction, 0)
        XCTAssertEqual(presentation.tokensUntilNextStage, 12_000_000)
        XCTAssertTrue(presentation.showsMilestone)
        XCTAssertTrue(presentation.accessibilityLabel.contains("Old School RuneScape"))
        XCTAssertFalse(presentation.variant.title.isEmpty)
    }

    @MainActor
    func testMenuIconIsTemplateSizedAndChangesWithTheJourneyStage() {
        let sapling = CompanionMenuIconRenderer.image(
            theme: .tree,
            variant: CompanionVariant(id: "oak", title: "Oak"),
            stage: 2
        )
        let landmark = CompanionMenuIconRenderer.image(
            theme: .tree,
            variant: CompanionVariant(id: "oak", title: "Oak"),
            stage: 7
        )

        XCTAssertEqual(sapling.size, NSSize(width: 18, height: 18))
        XCTAssertTrue(sapling.isTemplate)
        XCTAssertNotEqual(sapling.tiffRepresentation, landmark.tiffRepresentation)
    }

    @MainActor
    func testEveryCompanionStageRendersAtItsApprovedSize() throws {
        for theme in CompanionTheme.allCases where theme != .none {
            let variant = try XCTUnwrap(CompanionCatalog.variants(for: theme).first)
            for stage in 0..<CompanionJourney.thresholds.count {
                let presentation = CompanionPresentation(
                    theme: theme,
                    variant: variant,
                    stage: stage,
                    stageTitle: "Stage \(stage + 1)",
                    progressFraction: 0.42,
                    tokensUntilNextStage: 190_000_000,
                    showsMilestone: true,
                    accessibilityLabel: "\(theme.title), stage \(stage + 1) of 8"
                )
                let renderer = ImageRenderer(
                    content: CompanionStrip(presentation: presentation)
                )
                renderer.scale = 2
                let image = try XCTUnwrap(
                    renderer.nsImage,
                    "Failed to render \(theme.title), stage \(stage + 1)"
                )
                XCTAssertEqual(image.size, NSSize(width: 310, height: 84))
                XCTAssertNotNil(image.tiffRepresentation)
                try writeSnapshotIfRequested(
                    image,
                    name: "\(theme.rawValue)-stage-\(stage + 1)"
                )
            }
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
}
