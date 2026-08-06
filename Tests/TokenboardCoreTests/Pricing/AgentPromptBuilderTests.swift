import Foundation
import XCTest
@testable import TokenboardCore

final class AgentPromptBuilderTests: XCTestCase {
    private let paths = AgentPricingPaths(
        currentCatalog: URL(fileURLWithPath: "/private/example/Pricing/current-tokenboard-pricing.json"),
        temporaryCandidate: URL(fileURLWithPath: "/private/example/Pricing/Inbox/tokenboard-pricing.candidate.json.tmp"),
        finalCandidate: URL(fileURLWithPath: "/private/example/Pricing/Inbox/tokenboard-pricing.candidate.json")
    )

    func testOfficialResearchPromptContainsResolvedPathsAndProhibitsSQLiteWrites() {
        let prompt = AgentPromptBuilder().build(source: .officialResearch, paths: paths)

        XCTAssertTrue(prompt.contains(paths.currentCatalog.path))
        XCTAssertTrue(prompt.contains(paths.temporaryCandidate.path))
        XCTAssertTrue(prompt.contains(paths.finalCandidate.path))
        XCTAssertTrue(prompt.contains("Do not open or modify any SQLite file"))
        XCTAssertTrue(prompt.contains("If network or filesystem permission is unavailable, stop and ask me explicitly"))
        XCTAssertTrue(prompt.contains("Do not choose another source, destination, or update mechanism"))
        XCTAssertTrue(prompt.contains("atomically rename the temporary candidate to the final candidate path"))
        XCTAssertTrue(!prompt.contains("REPLACE_WITH"))
    }

    func testRepositoryPromptAllowsOnlyTheTokenboardRepositoryCatalog() {
        let prompt = AgentPromptBuilder().build(source: .tokenboardRepository, paths: paths)

        XCTAssertTrue(prompt.contains("https://raw.githubusercontent.com/Typiqally/tokenboard/main/Resources/tokenboard-pricing.json"))
        XCTAssertTrue(prompt.contains("Use only this source"))
        XCTAssertTrue(!prompt.contains("platform.openai.com"))
        XCTAssertTrue(!prompt.contains("platform.claude.com"))
    }

    func testOfficialResearchPromptNamesOnlyValidatorAllowedOfficialHosts() {
        let prompt = AgentPromptBuilder().build(source: .officialResearch, paths: paths)

        for host in [
            "anthropic.com", "www.anthropic.com", "platform.claude.com",
            "docs.anthropic.com", "www-cdn.anthropic.com", "openai.com",
            "www.openai.com", "platform.openai.com", "help.openai.com"
        ] {
            XCTAssertTrue(prompt.contains(host), "missing \(host)")
        }
        XCTAssertTrue(prompt.contains("Use only official pages on these exact hosts"))
        XCTAssertTrue(!prompt.contains("raw.githubusercontent.com"))
    }

    func testPromptDisclosesEachExactPathOnceAndNoAlternativeWriteLocation() {
        let prompt = AgentPromptBuilder().build(source: .officialResearch, paths: paths)

        XCTAssertEqual(prompt.components(separatedBy: paths.currentCatalog.path).count - 1, 1)
        XCTAssertEqual(prompt.components(separatedBy: paths.temporaryCandidate.path).count - 1, 1)
        XCTAssertEqual(prompt.components(separatedBy: paths.finalCandidate.path).count - 1, 1)
        XCTAssertTrue(prompt.contains("Do not write anywhere except the temporary candidate path below"))
    }
}
