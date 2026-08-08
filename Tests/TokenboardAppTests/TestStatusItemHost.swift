import AppKit
@testable import TokenboardApp

@MainActor
final class TestStatusItemHost: StatusItemHosting {
    var menu: NSMenu?
    var title = ""
}
