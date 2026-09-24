import Foundation
import XCTest
@testable import TokenboardApp

final class DiscordCompanionArtworkTests: XCTestCase {
    func testCatalogCoversEveryThemeVariantAndStageWithinDiscordLimit() throws {
        let artwork = DiscordCompanionArtwork.all
        XCTAssertEqual(artwork.count, 228)
        XCTAssertEqual(Set(artwork.map(\.key)).count, artwork.count)
        XCTAssertLessThanOrEqual(artwork.count + 1, 300)
        for entry in artwork {
            XCTAssertNotNil(entry.key.range(of: "^[a-z0-9_]+$", options: .regularExpression))
            XCTAssertEqual(DiscordCompanionArtwork(companion: entry.presentation), entry)
            XCTAssertEqual(entry.presentation.scenery, 0)
            XCTAssertEqual(entry.presentation.seed, 0)
            XCTAssertTrue(entry.tooltip.contains(entry.presentation.stageTitle))
            XCTAssertNotNil(CompanionAssetCatalog.scene(
                theme: entry.theme, variant: entry.variant, stage: entry.stage
            ))
        }
    }

    func testEveryMilestoneMatchesTheCompanionAndOnlyPublishedKeysAreShared() throws {
        let calendar = Calendar(identifier: .gregorian)
        let date = Date(timeIntervalSince1970: 1_775_000_000)
        let keys = Set(DiscordCompanionArtwork.all.map(\.key))
        for theme in CompanionTheme.allCases where theme != .none {
            for threshold in CompanionJourney.thresholds {
                for tokens in [max(0, threshold - 1), threshold, threshold + 1] {
                    let companion = try XCTUnwrap(CompanionPresentation.make(
                        state: CompanionState(theme: theme, showInMenuBar: false, seed: 123),
                        dailyTokenTotal: tokens, date: date, calendar: calendar
                    ))
                    let expected = try XCTUnwrap(DiscordCompanionArtwork(companion: companion))
                    let activity = DiscordPresencePresentation.activity(
                        tokenTotal: tokens, estimatedFocusMinutes: nil,
                        companion: companion, availableArtworkKeys: keys
                    )
                    XCTAssertEqual(expected.stage, CompanionJourney.stage(for: tokens))
                    XCTAssertEqual(activity.largeImageKey, expected.key)
                    XCTAssertEqual(activity.largeImageText, expected.tooltip)
                    XCTAssertTrue(DiscordPresencePresentation.accessibilityPreview(activity)
                        .contains(expected.tooltip))
                    let fallback = DiscordPresencePresentation.activity(
                        tokenTotal: tokens, estimatedFocusMinutes: nil, companion: companion
                    )
                    XCTAssertEqual(fallback.largeImageKey, "tokenboard")
                    XCTAssertEqual(fallback.largeImageText, "Tokenboard")
                }
            }
        }
        XCTAssertEqual(DiscordPresencePresentation.activity(
            tokenTotal: 1_000_000_000, estimatedFocusMinutes: nil,
            companion: nil, availableArtworkKeys: keys
        ).largeImageKey, "tokenboard")
    }

    func testArtworkIgnoresPrivateSeedSceneryAndBetweenStageGrowth() throws {
        let entry = try XCTUnwrap(DiscordCompanionArtwork.all.first { $0.theme == .forest })
        let live = CompanionPresentation(
            theme: entry.theme, variant: entry.variant, stage: entry.stage,
            scenery: 2, seed: 999, stageTitle: entry.presentation.stageTitle,
            progressFraction: 0.8, tokensUntilNextStage: 1,
            accessibilityLabel: "synthetic local companion"
        )
        XCTAssertEqual(DiscordCompanionArtwork(companion: live), entry)
    }

    func testAvailabilityIsBoundToItsApplicationAndRejectsUnknownKeys() throws {
        let key = try XCTUnwrap(DiscordCompanionArtwork.all.first?.key)
        let configuration = try XCTUnwrap(DiscordApplicationConfiguration(
            applicationID: "123456789012345678"
        ))
        let data = Data("""
        {"schemaVersion":1,"applicationID":"123456789012345678","assetKeys":["\(key)"]}
        """.utf8)
        let availability = try DiscordArtworkAvailability.decode(data)
        XCTAssertEqual(availability.keys(for: configuration), [key])
        XCTAssertEqual(availability.keys(for: nil), [])
        XCTAssertEqual(availability.keys(for: DiscordApplicationConfiguration(
            applicationID: "987654321098765432"
        )), [])
        for invalid in [
            "{\"schemaVersion\":2,\"applicationID\":\"123456789012345678\",\"assetKeys\":[]}",
            "{\"schemaVersion\":1,\"applicationID\":\"bad\",\"assetKeys\":[]}",
            "{\"schemaVersion\":1,\"applicationID\":\"123456789012345678\",\"assetKeys\":[\"https://example.invalid/image.png\"]}"
        ] {
            XCTAssertThrowsError(try DiscordArtworkAvailability.decode(Data(invalid.utf8)))
        }
    }
}
