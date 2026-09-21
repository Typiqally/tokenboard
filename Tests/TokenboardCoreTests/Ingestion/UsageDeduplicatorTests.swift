import XCTest
@testable import TokenboardCore

final class UsageDeduplicatorTests: XCTestCase {
    func testConsecutiveRepeatsOfAnIdentityAreDroppedButLaterReturnsAreNot() {
        var deduplicator = UsageDeduplicator()

        XCTAssertTrue(deduplicator.admit(identity: "a", cumulativeMetrics: [:]))
        XCTAssertFalse(deduplicator.admit(identity: "a", cumulativeMetrics: [:]))
        XCTAssertTrue(deduplicator.admit(identity: "b", cumulativeMetrics: [:]))
        XCTAssertTrue(deduplicator.admit(identity: "a", cumulativeMetrics: [:]))
        XCTAssertEqual(deduplicator.lastUsageIdentity, "a")
    }

    func testRecordsWithoutIdentityAreAlwaysNewAndKeepTheLastIdentity() {
        var deduplicator = UsageDeduplicator(lastUsageIdentity: "a")

        XCTAssertTrue(deduplicator.admit(identity: nil, cumulativeMetrics: [:]))
        XCTAssertTrue(deduplicator.admit(identity: nil, cumulativeMetrics: [:]))
        XCTAssertFalse(deduplicator.admit(identity: "a", cumulativeMetrics: [:]))
    }

    func testAnUnchangedCumulativeSnapshotIsARepeatEvenWithANewIdentity() {
        var deduplicator = UsageDeduplicator(cumulativeMetrics: [.output: 5])

        XCTAssertFalse(deduplicator.admit(identity: "new", cumulativeMetrics: [.output: 5]))
        XCTAssertTrue(deduplicator.admit(identity: "newer", cumulativeMetrics: [.output: 9]))
        XCTAssertTrue(deduplicator.admit(identity: "newest", cumulativeMetrics: [:]))
        XCTAssertEqual(deduplicator.cumulativeMetrics, [.output: 9])
    }
}
