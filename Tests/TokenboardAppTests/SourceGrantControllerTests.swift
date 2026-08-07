import Foundation
import XCTest
@testable import TokenboardApp
import TokenboardCore

@MainActor
final class SourceGrantControllerTests: XCTestCase {
    func testSuggestsProviderFoldersBeforeSandboxAccessIsGranted() {
        let home = URL(fileURLWithPath: "/Users/sandboxed-user", isDirectory: true)

        XCTAssertEqual(
            SourceGrantController.suggestedDirectory(
                for: .claudeCode,
                homeDirectory: home
            ),
            home.appending(path: ".claude/projects", directoryHint: .isDirectory)
        )
        XCTAssertEqual(
            SourceGrantController.suggestedDirectory(
                for: .codex,
                homeDirectory: home
            ),
            home.appending(path: ".codex/sessions", directoryHint: .isDirectory)
        )
    }
}
