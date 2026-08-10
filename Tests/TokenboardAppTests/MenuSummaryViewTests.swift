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

    func testSummaryViewExpandsToKeepMaximumSupportedContentWithinItsBounds() {
        let view = MenuSummaryView(content: MenuSummaryContent(
            contextTitle: "Today",
            visualRecencyTitle: "Updated never",
            accessibilityRecencyTitle: "Updated never",
            tokenTitle: "1 token",
            apiValueTitle: "≈ $0.00 API equivalent"
        ))

        XCTAssertEqual(view.frame.size, NSSize(width: 280, height: 76))

        view.update(content: MenuSummaryContent(
            contextTitle: "An Exceptionally Long Reporting Period",
            visualRecencyTitle: "Updated recently",
            accessibilityRecencyTitle: "Updated recently",
            tokenTitle: "9,223,372,036,854,775,807 tokens",
            apiValueTitle: "≈ €9,223,372,036,854,775,807.00 API equivalent"
        ))
        view.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(view.frame.width, 280)
        let contentDrivenWidth = view.frame.width

        view.updateRecency(
            visualTitle: "Updated 9,223,372,036,854,775,807 min. ago",
            accessibilityTitle: "Updated 9,223,372,036,854,775,807 minutes ago"
        )
        view.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(view.frame.width, contentDrivenWidth)
        XCTAssertEqual(view.frame.height, 76)
        XCTAssertEqual(view.intrinsicContentSize.height, 76)

        let derivedWidth = view.frame.width
        let widerHost = NSView(frame: view.frame)
        widerHost.addSubview(view)
        widerHost.setFrameSize(NSSize(width: derivedWidth + 40, height: 76))
        view.layoutSubtreeIfNeeded()

        XCTAssertEqual(view.frame.width, derivedWidth + 40)

        let labels = visibleTextFields(in: view)
        XCTAssertEqual(labels.count, 4)
        for label in labels where !label.isHidden {
            let frameInSummary = label.convert(label.bounds, to: view)
            XCTAssertTrue(
                view.bounds.contains(frameInSummary),
                "\(label.stringValue) frame \(frameInSummary) exceeded \(view.bounds)"
            )
            XCTAssertGreaterThanOrEqual(
                label.bounds.width,
                label.intrinsicContentSize.width,
                "\(label.stringValue) was horizontally compressed"
            )
        }
    }

    private func visibleTextFields(in view: NSView) -> [NSTextField] {
        view.subviews.flatMap { subview in
            (subview as? NSTextField).map { [$0] }
                ?? visibleTextFields(in: subview)
        }
    }
}
