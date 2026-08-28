import XCTest
@testable import TokenboardApp

/// The milestone reveal is quiet on purpose: once per newly reached stage,
/// on the next popover open, from the last stage already shown today. These
/// tests pin the pure acknowledgment logic the reveal runs on.
final class CompanionMilestoneTests: XCTestCase {
    private let today = "2026-08-28"
    private let yesterday = "2026-08-27"

    func testReachingANewStageRevealsFromTheAcknowledgedOne() {
        let acknowledged = CompanionMilestoneAcknowledgement(day: today, stage: 2)
        XCTAssertEqual(
            CompanionMilestone.revealSourceStage(
                todayStage: 3, acknowledged: acknowledged, day: today
            ),
            2
        )
    }

    func testAnAlreadyAcknowledgedStageRevealsNothing() {
        let acknowledged = CompanionMilestoneAcknowledgement(day: today, stage: 3)
        XCTAssertNil(
            CompanionMilestone.revealSourceStage(
                todayStage: 3, acknowledged: acknowledged, day: today
            )
        )
        XCTAssertNil(
            CompanionMilestone.revealSourceStage(
                todayStage: 2, acknowledged: acknowledged, day: today
            ),
            "a stage below the high-water mark never re-reveals"
        )
    }

    func testStageZeroNeverReveals() {
        XCTAssertNil(
            CompanionMilestone.revealSourceStage(
                todayStage: 0, acknowledged: nil, day: today
            )
        )
    }

    func testAMultiStageJumpRevealsOnceFromTheLastAcknowledgedStage() {
        let acknowledged = CompanionMilestoneAcknowledgement(day: today, stage: 1)
        XCTAssertEqual(
            CompanionMilestone.revealSourceStage(
                todayStage: 5, acknowledged: acknowledged, day: today
            ),
            1,
            "one crossfade spans the whole jump"
        )
        let after = CompanionMilestone.acknowledging(
            todayStage: 5, acknowledged: acknowledged, day: today
        )
        XCTAssertNil(
            CompanionMilestone.revealSourceStage(
                todayStage: 5, acknowledged: after, day: today
            ),
            "acknowledging closes the reveal"
        )
    }

    func testANewLocalDayResetsTheAcknowledgmentImplicitly() {
        let acknowledged = CompanionMilestoneAcknowledgement(day: yesterday, stage: 9)
        XCTAssertEqual(
            CompanionMilestone.revealSourceStage(
                todayStage: 1, acknowledged: acknowledged, day: today
            ),
            0,
            "yesterday's high-water mark counts for nothing"
        )
        XCTAssertEqual(
            CompanionMilestone.acknowledging(
                todayStage: 1, acknowledged: acknowledged, day: today
            ),
            CompanionMilestoneAcknowledgement(day: today, stage: 1)
        )
    }

    func testAcknowledgingNeverLowersTodaysHighWaterMark() {
        let acknowledged = CompanionMilestoneAcknowledgement(day: today, stage: 4)
        XCTAssertEqual(
            CompanionMilestone.acknowledging(
                todayStage: 2, acknowledged: acknowledged, day: today
            ),
            acknowledged
        )
    }

    func testStorageRoundTripsAndRejectsMalformedValues() {
        let acknowledged = CompanionMilestoneAcknowledgement(day: today, stage: 4)
        XCTAssertEqual(acknowledged.storageValue, "2026-08-28:4")
        XCTAssertEqual(
            CompanionMilestoneAcknowledgement(storageValue: "2026-08-28:4"),
            acknowledged
        )
        for malformed in ["", "2026-08-28", ":4", "2026-08-28:", "2026-08-28:-1", "2026-08-28:four"] {
            XCTAssertNil(
                CompanionMilestoneAcknowledgement(storageValue: malformed),
                "\"\(malformed)\" must read as nothing acknowledged"
            )
        }
    }
}
