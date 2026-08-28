import XCTest
@testable import TokenboardApp

/// The app's SplitMix64 and FNV-1a are duplicated in
/// `Scripts/generate-companion-artwork.swift` (a standalone interpreter file
/// that cannot import this module). Baked artwork and runtime layout agree
/// only while both copies produce identical streams, so the same literal
/// vectors pinned here are asserted by the script's
/// `verifyDeterminismContract()` at startup. Change one side and both
/// harnesses fail until the other follows.
final class CompanionRandomTests: XCTestCase {
    func testSplitMixStreamFromZeroStateMatchesThePinnedVector() {
        var generator = SplitMix64(state: 0)
        XCTAssertEqual(generator.next(), 16_294_208_416_658_607_535)
        XCTAssertEqual(generator.next(), 7_960_286_522_194_355_700)
        XCTAssertEqual(generator.next(), 487_617_019_471_545_679)
        XCTAssertEqual(generator.next(), 17_909_611_376_780_542_444)
    }

    func testSplitMixStreamFromTheSharedTestSeedMatchesThePinnedVector() {
        var generator = SplitMix64(state: 0x5EED_C0FF_EE12_3456)
        XCTAssertEqual(generator.next(), 18_353_202_869_249_109_356)
        XCTAssertEqual(generator.next(), 5_283_367_462_885_150_505)
    }

    func testUnitAndRangeDrawsMatchThePinnedVector() {
        var generator = SplitMix64(state: 1)
        XCTAssertEqual(generator.unit(), 0.5665615751722809)
        XCTAssertEqual(generator.range(-3, 7), 4.457817572627011)
    }

    func testHashMatchesThePinnedVector() {
        XCTAssertEqual(CompanionHash.fnv1a(""), 14_695_981_039_346_656_037)
        XCTAssertEqual(CompanionHash.fnv1a("forest/slots"), 16_912_484_999_438_345_198)
        XCTAssertEqual(CompanionHash.fnv1a("village/slots"), 9_601_084_288_157_441_201)
        XCTAssertEqual(CompanionHash.fnv1a("oak-3"), 15_916_341_269_509_778_426)
        XCTAssertEqual(CompanionHash.fnv1a("pokemon"), 9_996_402_097_866_326_110)
    }
}
