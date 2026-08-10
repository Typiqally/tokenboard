import AppKit
import XCTest
@testable import TokenboardApp

@MainActor
final class MenuSummaryViewTests: XCTestCase {
    func testSummaryViewPublishesExactContentAsANoninteractiveAccessibilityGroup() {
        let content = MenuSummaryContent(
            contextTitle: "This Month",
            visualRecencyTitle: "Updated 1 min. ago",
            accessibilityRecencyTitle: "Updated 1 minute ago",
            tokenTitle: "101,831,896 tokens",
            apiValueTitle: "≈ €105.44 API equivalent"
        )

        let view = MenuSummaryView(content: content)

        XCTAssertEqual(view.content, content)
        XCTAssertEqual(view.intrinsicContentSize, NSSize(width: 280, height: 76))
        XCTAssertFalse(view.acceptsFirstResponder)
        XCTAssertTrue(view.isAccessibilityElement())
        XCTAssertEqual(view.accessibilityRole(), .group)
        XCTAssertEqual(
            view.accessibilityLabel(),
            "This Month. 101,831,896 tokens. ≈ €105.44 API equivalent. Updated 1 minute ago."
        )
    }

    func testSummaryViewUpdatesRecencyWithoutChangingUsageValues() {
        let view = MenuSummaryView(content: MenuSummaryContent(
            contextTitle: "Today",
            visualRecencyTitle: "Updated never",
            accessibilityRecencyTitle: "Updated never",
            tokenTitle: "842,198 tokens",
            apiValueTitle: "≈ €7.42 API equivalent"
        ))

        view.updateRecency(
            visualTitle: "Updated 2 min. ago",
            accessibilityTitle: "Updated 2 minutes ago"
        )

        XCTAssertEqual(view.content.contextTitle, "Today")
        XCTAssertEqual(view.content.visualRecencyTitle, "Updated 2 min. ago")
        XCTAssertEqual(view.content.accessibilityRecencyTitle, "Updated 2 minutes ago")
        XCTAssertEqual(view.content.tokenTitle, "842,198 tokens")
        XCTAssertEqual(view.content.apiValueTitle, "≈ €7.42 API equivalent")
        XCTAssertEqual(
            view.accessibilityLabel(),
            "Today. 842,198 tokens. ≈ €7.42 API equivalent. Updated 2 minutes ago."
        )
    }
}
