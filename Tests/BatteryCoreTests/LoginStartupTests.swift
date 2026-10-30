import XCTest
@testable import BatteryCore

final class LoginStartupTests: XCTestCase {
    func testLaunchesAtLoginWithoutRestartingAfterQuitOrShellInterpolation() throws {
        let app = URL(fileURLWithPath: "/Applications/Battery Saver 'test' $(literal).app")
        let data = try LoginStartup.configuration(app: app)
        let values = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(values["Label"] as? String, LoginStartup.label)
        XCTAssertEqual(values["ProgramArguments"] as? [String], ["/usr/bin/open", "-g", app.path])
        XCTAssertEqual(values["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(values["LimitLoadToSessionType"] as? String, "Aqua")
        XCTAssertNil(values["KeepAlive"])
    }
    func testEnableVerifyRelocateAndDisableInRealTemporaryDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Battery Saver.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try Data().write(to: app.appendingPathComponent("Contents/Info.plist"))
        let startup = LoginStartup(directory: root.appendingPathComponent("LaunchAgents"))
        XCTAssertFalse(startup.isEnabled(app: app))
        try startup.setEnabled(true, app: app)
        XCTAssertTrue(startup.isEnabled(app: app))
        try startup.setEnabled(true, app: app)
        let relocated = root.appendingPathComponent("Moved.app")
        try FileManager.default.moveItem(at: app, to: relocated)
        XCTAssertFalse(startup.isEnabled(app: relocated))
        try startup.setEnabled(true, app: relocated)
        XCTAssertTrue(startup.isEnabled(app: relocated))
        try startup.setEnabled(false, app: relocated)
        XCTAssertFalse(FileManager.default.fileExists(atPath: startup.file.path))
        try startup.setEnabled(false, app: relocated)
    }
    func testRejectsMissingAppAndPreservesUnrecognizedExistingEntry() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let startup = LoginStartup(directory: root)
        let missing = root.appendingPathComponent("Missing.app")
        XCTAssertThrowsError(try startup.setEnabled(true, app: missing))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: ["Label": "other"], format: .xml, options: 0)
        try data.write(to: startup.file)
        XCTAssertThrowsError(try startup.setEnabled(false, app: missing))
        XCTAssertEqual(try Data(contentsOf: startup.file), data)
        XCTAssertThrowsError(try LoginStartup.configuration(app: URL(fileURLWithPath: "/tmp/BatterySaver")))
    }
}
