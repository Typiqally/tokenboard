# Native Menu Polish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Tokenboard's muted disabled summary rows with a compact accessible AppKit summary header and add a restrained native SF Symbol rail to the menu actions.

**Architecture:** Add one presentation-only `MenuSummaryView` file containing display-ready summary content and an AppKit view composed from system labels and stacks. `NativeMenuBuilder` constructs and hosts that view in the existing `NSMenu`, while `MenuController` updates only its relative recency when the menu opens; all interactive rows remain ordinary `NSMenuItem`s with their existing targets, selectors, shortcuts, and enablement.

**Tech Stack:** Swift 6, AppKit, Combine, XCTest, Swift Package Manager, SF Symbols, macOS 14+

## Global Constraints

- Preserve one native macOS process and the existing real AppKit `NSMenu`; do not introduce a popover, web view, helper, daemon, XPC service, or SwiftUI menu replacement.
- Do not add network access, entitlements, analytics, telemetry, third-party runtime dependencies, persistence, polling, or timers.
- Keep the full-precision token total primary even when the menu-bar display metric is API Value; keep the API-equivalent estimate secondary.
- Use only system fonts, semantic AppKit colors, native menu material, and native template SF Symbols.
- Keep Period, Currency, Menu Bar, and Quit image-free; use `arrow.clockwise`, `banknote`, and `gearshape` for Refresh Now, Pricing, and Settings.
- Preserve existing targets, selectors, represented values, shortcuts, action enablement, startup diagnostics, recovery dispositions, and pricing disclosure.
- Develop behavior test-first and keep synthetic tests free of real source paths, prompts, responses, session identifiers, and user data.
- Agents must not open Tokenboard for the user or claim the manual native design check; provide the built app and exact review checklist for the user.

## File Map

- Create `Sources/TokenboardApp/MenuSummaryView.swift`: own the display-ready summary value and the noninteractive AppKit header layout/accessibility.
- Modify `Sources/TokenboardApp/MenuController.swift`: host the summary view, update recency on open, and attach optional system images to action items.
- Create `Tests/TokenboardAppTests/MenuSummaryViewTests.swift`: verify the isolated view's content, sizing, focus behavior, semantic presentation contract, and accessibility summary.
- Modify `Tests/TokenboardAppTests/NativePresentationTests.swift`: verify menu integration, state fallbacks, relative-recency updates, action images, and unchanged wiring.

---

### Task 1: Add the Focused Native Summary View

**Files:**
- Create: `Sources/TokenboardApp/MenuSummaryView.swift`
- Create: `Tests/TokenboardAppTests/MenuSummaryViewTests.swift`

**Interfaces:**
- Consumes: display-ready `String` values produced by the existing menu builder.
- Produces: `MenuSummaryContent`, including `contextTitle`, `visualRecencyTitle`, `accessibilityRecencyTitle`, `tokenTitle`, `apiValueTitle`, `accessibilitySummary`, and `updatingRecency(visualTitle:accessibilityTitle:)`.
- Produces: `@MainActor final class MenuSummaryView: NSView` with `private(set) var content`, `init(content:)`, `update(content:)`, `updateRecency(visualTitle:accessibilityTitle:)`, and a `280 × 76` intrinsic content size.

- [ ] **Step 1: Write the failing summary-view tests**

Create `Tests/TokenboardAppTests/MenuSummaryViewTests.swift` with:

```swift
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
```

- [ ] **Step 2: Run the focused tests and confirm the expected failure**

Run:

```zsh
swift test --filter MenuSummaryViewTests
```

Expected: compilation fails because `MenuSummaryContent` and `MenuSummaryView` do not exist.

- [ ] **Step 3: Implement the display value and AppKit view**

Create `Sources/TokenboardApp/MenuSummaryView.swift` with:

```swift
import AppKit

struct MenuSummaryContent: Equatable, Sendable {
    let contextTitle: String
    let visualRecencyTitle: String
    let accessibilityRecencyTitle: String
    let tokenTitle: String
    let apiValueTitle: String

    var accessibilitySummary: String {
        "\(contextTitle). \(tokenTitle). \(apiValueTitle). \(accessibilityRecencyTitle)."
    }

    func updatingRecency(
        visualTitle: String,
        accessibilityTitle: String
    ) -> MenuSummaryContent {
        MenuSummaryContent(
            contextTitle: contextTitle,
            visualRecencyTitle: visualTitle,
            accessibilityRecencyTitle: accessibilityTitle,
            tokenTitle: tokenTitle,
            apiValueTitle: apiValueTitle
        )
    }
}

@MainActor
final class MenuSummaryView: NSView {
    private enum Metrics {
        static let width: CGFloat = 280
        static let height: CGFloat = 76
        static let horizontalInset: CGFloat = 14
        static let verticalInset: CGFloat = 10
        static let contextSpacing: CGFloat = 8
        static let lineSpacing: CGFloat = 5
    }

    private let contextLabel = NSTextField(labelWithString: "")
    private let recencyLabel = NSTextField(labelWithString: "")
    private let tokenLabel = NSTextField(labelWithString: "")
    private let apiValueLabel = NSTextField(labelWithString: "")
    private(set) var content: MenuSummaryContent

    override var intrinsicContentSize: NSSize {
        NSSize(width: Metrics.width, height: Metrics.height)
    }

    init(content: MenuSummaryContent) {
        self.content = content
        super.init(frame: NSRect(
            x: 0,
            y: 0,
            width: Metrics.width,
            height: Metrics.height
        ))
        configureLayout()
        update(content: content)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func update(content: MenuSummaryContent) {
        self.content = content
        contextLabel.stringValue = content.contextTitle.uppercased()
        recencyLabel.stringValue = content.visualRecencyTitle.uppercased()
        tokenLabel.stringValue = content.tokenTitle
        apiValueLabel.stringValue = content.apiValueTitle
        setAccessibilityLabel(content.accessibilitySummary)
    }

    func updateRecency(visualTitle: String, accessibilityTitle: String) {
        update(content: content.updatingRecency(
            visualTitle: visualTitle,
            accessibilityTitle: accessibilityTitle
        ))
    }

    private func configureLayout() {
        setAccessibilityElement(true)
        setAccessibilityRole(.group)

        contextLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        recencyLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        tokenLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        apiValueLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        contextLabel.textColor = .tertiaryLabelColor
        recencyLabel.textColor = .tertiaryLabelColor
        tokenLabel.textColor = .labelColor
        apiValueLabel.textColor = .secondaryLabelColor

        for label in [contextLabel, recencyLabel, tokenLabel, apiValueLabel] {
            label.lineBreakMode = .byClipping
            label.maximumNumberOfLines = 1
            label.usesSingleLineMode = true
        }

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let contextRow = NSStackView(views: [contextLabel, spacer, recencyLabel])
        contextRow.orientation = .horizontal
        contextRow.alignment = .centerY
        contextRow.spacing = Metrics.contextSpacing

        let stack = NSStackView(views: [contextRow, tokenLabel, apiValueLabel])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Metrics.lineSpacing
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.horizontalInset),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.horizontalInset),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.verticalInset),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Metrics.verticalInset),
            contextRow.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }
}
```

- [ ] **Step 4: Run the focused tests and confirm they pass**

Run:

```zsh
swift test --filter MenuSummaryViewTests
```

Expected: both `MenuSummaryViewTests` pass.

- [ ] **Step 5: Run formatting checks and commit the isolated view**

Run:

```zsh
git diff --check
git add Sources/TokenboardApp/MenuSummaryView.swift Tests/TokenboardAppTests/MenuSummaryViewTests.swift
git commit -m "feat: add native menu summary view"
```

Expected: `git diff --check` emits no output and the commit succeeds.

---

### Task 2: Integrate the Summary Header and Relative Recency

**Files:**
- Modify: `Sources/TokenboardApp/MenuController.swift:5-120`
- Modify: `Sources/TokenboardApp/MenuController.swift:249-340`
- Modify: `Tests/TokenboardAppTests/NativePresentationTests.swift:9-74`
- Modify: `Tests/TokenboardAppTests/NativePresentationTests.swift:126-211`

**Interfaces:**
- Consumes: `MenuSummaryContent` and `MenuSummaryView` from Task 1.
- Produces: `BuiltNativeMenu.summaryView: MenuSummaryView`.
- Preserves: `NativeMenuBuilder.makeMenu(...) -> BuiltNativeMenu` and every existing submenu/action selector.
- Produces: `MenuController.menuWillOpen(_:)` updates `MenuSummaryView` with abbreviated visual recency and full accessibility recency.

- [ ] **Step 1: Rewrite the finalized-menu expectation around one summary item**

In `testMenuBuilderPublishesTheCompleteFinalizedStateInRequiredOrder`, replace the existing top-level and updated-item assertions with:

```swift
XCTAssertEqual(topLevelTitles(built.menu), [
    "Usage Summary",
    "—",
    "Period: This Month",
    "Currency: EUR",
    "Menu Bar: API Value",
    "—",
    "Refresh Now",
    "Pricing (84K unpriced)",
    "Settings",
    "—",
    "Quit Tokenboard"
])
XCTAssertEqual(built.statusTitle, "$7.42+")
XCTAssertIdentical(built.menu.items.first?.view, built.summaryView)
XCTAssertEqual(built.summaryView.content, MenuSummaryContent(
    contextTitle: "This Month",
    visualRecencyTitle: "Updated never",
    accessibilityRecencyTitle: "Updated never",
    tokenTitle: "842,198 tokens",
    apiValueTitle: "≈ $7.42 API equivalent"
))

let period = built.menu.items[2].submenu!.items
XCTAssertEqual(period.map(\.title), ["Today", "This Week", "This Month", "This Year", "All Time"])
XCTAssertEqual(period.map(\.state), [.off, .off, .on, .off, .off])
let currencies = built.menu.items[3].submenu!.items
XCTAssertEqual(currencies.map(\.title), ["USD", "EUR", "JPY", "GBP", "CNY"])
XCTAssertEqual(currencies.map(\.state), [.off, .on, .off, .off, .off])
XCTAssertEqual(currencies.map(\.isEnabled), [true, true, false, true, false])
let metrics = built.menu.items[4].submenu!.items
XCTAssertEqual(metrics.map(\.title), ["Tokens", "API Value"])
XCTAssertEqual(metrics.map(\.state), [.off, .on])
XCTAssertEqual(built.menu.items[6].keyEquivalent, "r")
XCTAssertEqual(built.menu.items[8].keyEquivalent, ",")
XCTAssertEqual(built.menu.items[10].keyEquivalent, "q")
```

This expectation proves the token total remains the primary header line even though the state selects API Value for the menu bar.

- [ ] **Step 2: Add explicit starting and startup-failure header tests**

Add these methods to `NativePresentationTests`:

```swift
func testMenuBuilderPublishesExplicitStartingAndFailureSummaries() {
    let starting = NativeMenuBuilder.makeMenu(
        state: nil,
        startupError: nil,
        target: nil
    )

    XCTAssertEqual(starting.statusTitle, "…")
    XCTAssertEqual(starting.summaryView.content, MenuSummaryContent(
        contextTitle: "Starting",
        visualRecencyTitle: "Updated never",
        accessibilityRecencyTitle: "Updated never",
        tokenTitle: "Token total unavailable",
        apiValueTitle: "API equivalent unavailable"
    ))
    XCTAssertNotNil(starting.menu.item(withTitle: "Sources unavailable"))

    let failed = NativeMenuBuilder.makeMenu(
        state: nil,
        startupError: "Startup paused: Synthetic failure",
        target: nil
    )

    XCTAssertEqual(failed.statusTitle, "Unavailable")
    XCTAssertEqual(failed.summaryView.content.contextTitle, "Unavailable")
    XCTAssertEqual(failed.summaryView.content.tokenTitle, "Token total unavailable")
    XCTAssertEqual(failed.summaryView.content.apiValueTitle, "API equivalent unavailable")
    XCTAssertNotNil(failed.menu.item(withTitle: "Startup paused: Synthetic failure"))
}
```

- [ ] **Step 3: Add controller coverage for recency-only updates**

Add this method to `NativePresentationTests`:

```swift
func testMenuOpenUpdatesVisualAndAccessibilityRecencyWithoutChangingSummaryValues() throws {
    let setup = try makeModel()
    defer { setup.cleanup() }
    var state = AppPublishedState.initial(period: .today, displayMetric: .tokens)
    state.lifecycle = .ready
    state.lastUpdated = Date().addingTimeInterval(-90)
    state.presentation = MenuPresentation(
        summary: UsageSummary(
            period: .today,
            tokenTotal: 456,
            knownAPIEquivalentUSD: Decimal(string: "1.25")!,
            unpricedTokens: 0
        ),
        displayMetric: .tokens
    )
    setup.model.commitState(state)
    let controller = MenuController(model: setup.model, statusItem: TestStatusItemHost())
    guard let menu = controller.renderedMenu,
          let summaryView = menu.items.first?.view as? MenuSummaryView else {
        return XCTFail("missing menu summary view")
    }

    XCTAssertEqual(summaryView.content.visualRecencyTitle, "Updated never")
    controller.menuWillOpen(menu)

    XCTAssertTrue(summaryView.content.visualRecencyTitle.hasPrefix("Updated "))
    XCTAssertNotEqual(summaryView.content.visualRecencyTitle, "Updated never")
    XCTAssertTrue(summaryView.content.accessibilityRecencyTitle.hasPrefix("Updated "))
    XCTAssertEqual(summaryView.content.tokenTitle, "456 tokens")
    XCTAssertEqual(summaryView.content.apiValueTitle, "≈ $1.25 API equivalent")
    XCTAssertEqual(summaryView.accessibilityLabel(), summaryView.content.accessibilitySummary)
}
```

In `testMenuControllerRendersEmittedSnapshotAndWiresRealSelectorsAndValues`, replace:

```swift
XCTAssertEqual(controller.renderedMenu?.items.first?.title, "456 tokens")
```

with:

```swift
let summaryView = controller.renderedMenu?.items.first?.view as? MenuSummaryView
XCTAssertEqual(summaryView?.content.tokenTitle, "456 tokens")
XCTAssertEqual(summaryView?.content.apiValueTitle, "≈ $0.00 API equivalent")
```

- [ ] **Step 4: Run the native-presentation tests and confirm the expected failures**

Run:

```zsh
swift test --filter NativePresentationTests
```

Expected: compilation or assertions fail because `BuiltNativeMenu` still exposes `updatedItem`, the builder still creates disabled value rows, and the controller does not update `MenuSummaryView`.

- [ ] **Step 5: Replace the built-menu updated item with the summary view**

In `BuiltNativeMenu`, replace `updatedItem` with:

```swift
let summaryView: MenuSummaryView
```

In `NativeMenuBuilder.makeMenu`, replace the current status-title/value-row branch with:

```swift
let statusTitle: String
let summaryContent: MenuSummaryContent

if let state, let presentation = state.presentation {
    statusTitle = presentation.statusTitle
    summaryContent = MenuSummaryContent(
        contextTitle: periodTitle(state.selectedPeriod),
        visualRecencyTitle: "Updated never",
        accessibilityRecencyTitle: "Updated never",
        tokenTitle: presentation.tokenTitle,
        apiValueTitle: presentation.apiValueTitle
    )
} else {
    statusTitle = startupError == nil ? "…" : "Unavailable"
    summaryContent = MenuSummaryContent(
        contextTitle: startupError == nil ? "Starting" : "Unavailable",
        visualRecencyTitle: "Updated never",
        accessibilityRecencyTitle: "Updated never",
        tokenTitle: "Token total unavailable",
        apiValueTitle: "API equivalent unavailable"
    )
}

let summaryView = MenuSummaryView(content: summaryContent)
let summaryItem = NSMenuItem(title: "Usage Summary", action: nil, keyEquivalent: "")
summaryItem.isEnabled = false
summaryItem.view = summaryView
menu.addItem(summaryItem)
```

Replace the current diagnostic/Updated/separator block with:

```swift
if state == nil {
    menu.addDisabledItem(startupError ?? "Sources unavailable")
    menu.addItem(.separator())
}
```

Return the new view reference:

```swift
return BuiltNativeMenu(
    menu: menu,
    statusTitle: statusTitle,
    summaryView: summaryView
)
```

- [ ] **Step 6: Update the controller to retain and refresh the summary view**

Replace the `updatedItem` property with:

```swift
private weak var summaryView: MenuSummaryView?
```

Replace `menuWillOpen(_:)` with:

```swift
func menuWillOpen(_ menu: NSMenu) {
    guard let summaryView else { return }
    let visualRelative: String
    let accessibilityRelative: String
    if let lastUpdated = model?.health.lastSuccessfulScan {
        let visualFormatter = RelativeDateTimeFormatter()
        visualFormatter.unitsStyle = .abbreviated
        visualRelative = visualFormatter.localizedString(
            for: lastUpdated,
            relativeTo: Date()
        )

        let accessibilityFormatter = RelativeDateTimeFormatter()
        accessibilityFormatter.unitsStyle = .full
        accessibilityRelative = accessibilityFormatter.localizedString(
            for: lastUpdated,
            relativeTo: Date()
        )
    } else {
        visualRelative = "never"
        accessibilityRelative = "never"
    }
    summaryView.updateRecency(
        visualTitle: "Updated \(visualRelative)",
        accessibilityTitle: "Updated \(accessibilityRelative)"
    )
}
```

In `rebuildMenu`, replace the assignment to `updatedItem` with:

```swift
summaryView = built.summaryView
```

- [ ] **Step 7: Run focused and full app tests**

Run:

```zsh
swift test --filter MenuSummaryViewTests
swift test --filter NativePresentationTests
swift test --filter TokenboardAppTests
```

Expected: all three commands pass. The app-test run confirms existing recovery enablement, selectors, onboarding, and settings behavior remain intact.

- [ ] **Step 8: Check the integration diff and commit**

Run:

```zsh
git diff --check
git add Sources/TokenboardApp/MenuController.swift Tests/TokenboardAppTests/NativePresentationTests.swift
git commit -m "feat: integrate native status summary"
```

Expected: `git diff --check` emits no output and the commit succeeds.

---

### Task 3: Add the Action Symbol Rail and Run the Release Gate

**Files:**
- Modify: `Sources/TokenboardApp/MenuController.swift:88-119`
- Modify: `Sources/TokenboardApp/MenuController.swift:218-229`
- Modify: `Tests/TokenboardAppTests/NativePresentationTests.swift:9-74`

**Interfaces:**
- Consumes: existing `NativeMenuBuilder.actionItem` calls and AppKit's `NSImage(systemSymbolName:accessibilityDescription:)`.
- Produces: optional `systemSymbolName: String?` support in `actionItem`.
- Preserves: all item titles as accessible action names; images have no separate accessibility description and are template-rendered.

- [ ] **Step 1: Add failing assertions for the selected SF Symbols**

Add this helper to `NativePresentationTests`:

```swift
private func assertSystemSymbol(
    _ symbolName: String,
    on item: NSMenuItem?,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    let expected = NSImage(
        systemSymbolName: symbolName,
        accessibilityDescription: nil
    )
    XCTAssertNotNil(item?.image, file: file, line: line)
    XCTAssertEqual(
        item?.image?.tiffRepresentation,
        expected?.tiffRepresentation,
        file: file,
        line: line
    )
    XCTAssertTrue(item?.image?.isTemplate == true, file: file, line: line)
}
```

In `testMenuBuilderPublishesTheCompleteFinalizedStateInRequiredOrder`, after the shortcut assertions, add:

```swift
assertSystemSymbol("arrow.clockwise", on: built.menu.item(withTitle: "Refresh Now"))
assertSystemSymbol("banknote", on: built.menu.item(withTitle: "Pricing (84K unpriced)"))
assertSystemSymbol("gearshape", on: built.menu.item(withTitle: "Settings"))
XCTAssertNil(built.menu.item(withTitle: "Period: This Month")?.image)
XCTAssertNil(built.menu.item(withTitle: "Currency: EUR")?.image)
XCTAssertNil(built.menu.item(withTitle: "Menu Bar: API Value")?.image)
XCTAssertNil(built.menu.item(withTitle: "Quit Tokenboard")?.image)
```

- [ ] **Step 2: Run the native-presentation test and confirm the expected failure**

Run:

```zsh
swift test --filter NativePresentationTests.testMenuBuilderPublishesTheCompleteFinalizedStateInRequiredOrder
```

Expected: the symbol assertions fail because the three action images are `nil`.

- [ ] **Step 3: Extend the action helper with optional system images**

Change `actionItem` to:

```swift
private static func actionItem(
    _ title: String,
    action: Selector,
    target: AnyObject?,
    keyEquivalent: String = "",
    systemSymbolName: String? = nil,
    isEnabled: Bool = true
) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
    item.target = target
    item.isEnabled = isEnabled
    if let systemSymbolName,
       let image = NSImage(
           systemSymbolName: systemSymbolName,
           accessibilityDescription: nil
       ) {
        image.isTemplate = true
        item.image = image
    }
    return item
}
```

Pass the selected symbols at the three top-level action call sites:

```swift
menu.addItem(actionItem(
    "Refresh Now",
    action: NSSelectorFromString("refresh"),
    target: target,
    keyEquivalent: "r",
    systemSymbolName: "arrow.clockwise",
    isEnabled: regularActionsEnabled
))
```

```swift
menu.addItem(actionItem(
    pricingTitle,
    action: NSSelectorFromString("openPricing"),
    target: target,
    systemSymbolName: "banknote",
    isEnabled: regularActionsEnabled
))
```

```swift
menu.addItem(actionItem(
    "Settings",
    action: NSSelectorFromString("openSettings"),
    target: target,
    keyEquivalent: ",",
    systemSymbolName: "gearshape",
    isEnabled: !isRestoringDatabase
))
```

Do not pass a symbol to submenu choices or Quit Tokenboard.

- [ ] **Step 4: Run the focused symbol and menu tests**

Run:

```zsh
swift test --filter NativePresentationTests.testMenuBuilderPublishesTheCompleteFinalizedStateInRequiredOrder
swift test --filter NativePresentationTests
```

Expected: both commands pass, including exact image comparison and unchanged menu wiring.

- [ ] **Step 5: Run the complete automated release gate**

Run:

```zsh
swift test
Scripts/build-app.sh release
Scripts/verify-entitlements.sh .build/release/Tokenboard.app
git diff --check
```

Expected:

- `swift test` passes every package test.
- `Scripts/build-app.sh release` produces `.build/release/Tokenboard.app`.
- The entitlement verifier succeeds without adding an entitlement.
- `git diff --check` emits no output.

- [ ] **Step 6: Commit the completed native menu polish**

Run:

```zsh
git add Sources/TokenboardApp/MenuController.swift Tests/TokenboardAppTests/NativePresentationTests.swift
git commit -m "feat: add native status menu action symbols"
git status --short --branch
```

Expected: the commit succeeds and the working tree is clean.

- [ ] **Step 7: Hand the built app to the user for the required visual check**

Do not open the app or claim this check. Ask the user to open `.build/release/Tokenboard.app` and confirm:

1. The header matches the approved B2 hierarchy in light and dark appearances.
2. The full token total fits without truncation for the user's current data.
3. Period and abbreviated recency remain legible with Increased Contrast enabled.
4. Arrow keys enter and leave all three configuration submenus normally.
5. Command-R, Command-comma, and Command-Q still invoke the expected actions.
6. VoiceOver announces period, full token total, API-equivalent estimate, and full update recency without presenting the header as a button.

Record the user's observations in the handoff. If any visual or accessibility item fails, add a focused regression test before changing the implementation, rerun the complete automated release gate, and produce a new build for review.
