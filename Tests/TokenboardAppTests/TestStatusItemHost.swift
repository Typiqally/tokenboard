import AppKit
@testable import TokenboardApp

@MainActor
final class TestStatusItemHost: StatusItemHosting {
    var menu: NSMenu?
    private(set) var title = ""
    private(set) var systemImageName: String?
    private(set) var accessibilityLabel = ""

    func updateStatus(
        title: String,
        systemImageName: String?,
        accessibilityLabel: String
    ) {
        self.title = title
        self.systemImageName = systemImageName
        self.accessibilityLabel = accessibilityLabel
    }
}
