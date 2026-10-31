import XCTest
@testable import BatteryCore

final class AppIdentityTests: XCTestCase {
    func testBundleAndLaunchdConfigurationMatchSharedIdentity() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        func plist(_ name: String) throws -> [String: Any] {
            try XCTUnwrap(PropertyListSerialization.propertyList(
                from: Data(contentsOf: root.appendingPathComponent("Resources/" + name)), format: nil) as? [String: Any])
        }
        let info = try plist("Info.plist")
        XCTAssertEqual(info["CFBundleIdentifier"] as? String, AppIdentity.bundle)
        let service = try plist(AppIdentity.service + ".plist")
        XCTAssertEqual(service["Label"] as? String, AppIdentity.service)
        XCTAssertEqual(service["MachServices"] as? [String: Bool], [HelperSessionService.name: true])
        XCTAssertEqual(service["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(service["KeepAlive"] as? [String: Bool], ["SuccessfulExit": false])
        XCTAssertEqual(LoginStartup.label, AppIdentity.login)
    }
}
