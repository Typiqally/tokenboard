import Foundation
import XCTest
@testable import TokenboardCore

final class AppBundleConfigurationTests: XCTestCase {
    func testBuildInfoPinsBundleAndDeploymentTarget() {
        XCTAssertEqual(BuildInfo.bundleIdentifier, "com.tokenboard.Tokenboard")
        XCTAssertEqual(BuildInfo.minimumMacOS, "14.0")
    }

    func testEntitlementsAreSandboxedReadOnlyAndOffline() throws {
        let url = TestRepository.root.appending(path: "Resources/Tokenboard.entitlements")
        let data = try Data(contentsOf: url)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        XCTAssertEqual(plist["com.apple.security.app-sandbox"] as? Bool, true)
        XCTAssertEqual(plist["com.apple.security.files.user-selected.read-only"] as? Bool, true)
        XCTAssertEqual(plist["com.apple.security.files.bookmarks.app-scope"] as? Bool, true)
        XCTAssertNil(plist["com.apple.security.network.client"])
        XCTAssertNil(plist["com.apple.security.network.server"])
    }

    func testInfoPlistDefinesAnAgentOnlyApplication() throws {
        let url = TestRepository.root.appending(path: "Resources/Info.plist")
        let data = try Data(contentsOf: url)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        XCTAssertEqual(plist["LSUIElement"] as? Bool, true)
        XCTAssertEqual(plist["LSMinimumSystemVersion"] as? String, "14.0")
        XCTAssertEqual(plist["CFBundleIdentifier"] as? String, BuildInfo.bundleIdentifier)
    }
}
