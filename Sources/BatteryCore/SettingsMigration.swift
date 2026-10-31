import Foundation

public enum SettingsMigration {
    /// Preserve unknown keys and user choices; never guess how to read a future schema.
    public static func migrate(_ data: Data) throws -> Data {
        let settings = try JSONDecoder().decode(Settings.self, from: data)
        try settings.validate()
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SaverError("Settings must be a JSON object.")
        }
        if object["schemaVersion"] as? Int == HelperVersion.current.settingsSchema { return data }
        object["schemaVersion"] = HelperVersion.current.settingsSchema
        object["keepAwakeUntilLimit"] = settings.keepAwakeUntilLimit
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
