import XCTest
@testable import BatteryCore

final class SettingsMigrationTests: XCTestCase {
    private let legacy = Data(#"{"enabled":true,"lower":70,"upper":85,"heatPause":40,"heatResume":36,"customNote":"preserve"}"#.utf8)

    func testLegacyMigrationPreservesValuesAndUnknownKeys() throws {
        let migrated = try SettingsMigration.migrate(legacy)
        let settings = try JSONDecoder().decode(Settings.self, from: migrated)
        XCTAssertTrue(settings.enabled)
        XCTAssertEqual(settings.lower, 70)
        XCTAssertEqual(settings.upper, 85)
        XCTAssertEqual(settings.heatPause, 40)
        XCTAssertEqual(settings.heatResume, 36)
        XCTAssertTrue(settings.keepAwakeUntilLimit)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: migrated) as? [String: Any])
        XCTAssertEqual(object["customNote"] as? String, "preserve")
    }

    func testMigrationIsIdempotentAndPreservesExplicitFalse() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: legacy) as? [String: Any])
        object["keepAwakeUntilLimit"] = false
        let migrated = try SettingsMigration.migrate(JSONSerialization.data(withJSONObject: object))
        XCTAssertFalse(try JSONDecoder().decode(Settings.self, from: migrated).keepAwakeUntilLimit)
        XCTAssertEqual(try SettingsMigration.migrate(migrated), migrated)
    }

    func testInvalidSettingsCannotBeMigrated() {
        for data in [Data(), Data("null".utf8), Data(#"{"enabled":true}"#.utf8),
                     Data(#"{"enabled":true,"lower":90,"upper":85,"heatPause":40,"heatResume":36}"#.utf8)] {
            XCTAssertThrowsError(try SettingsMigration.migrate(data))
        }
    }
}

extension SettingsMigrationTests {
    func testFutureSchemaCannotBeReadOrMigrated() throws {
        let settings = try JSONEncoder().encode(Settings())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: settings) as? [String: Any])
        for schema: Any in [2, -1, true, "1", NSNull()] {
            object["schemaVersion"] = schema
            let data = try JSONSerialization.data(withJSONObject: object)
            XCTAssertThrowsError(try JSONDecoder().decode(Settings.self, from: data))
            XCTAssertThrowsError(try SettingsMigration.migrate(data))
        }
    }
}
