import Foundation

/// Increment revision for helper changes; change protocol/schema only when their contracts change.
public struct HelperVersion: Codable, Equatable {
    public let revision: Int
    public let protocolVersion: Int
    public let settingsSchema: Int
    public static let current = HelperVersion(revision: 3, protocolVersion: 2, settingsSchema: 1)
    public init(revision: Int, protocolVersion: Int, settingsSchema: Int) {
        self.revision = revision; self.protocolVersion = protocolVersion; self.settingsSchema = settingsSchema
    }
    public static func read(executable: String) throws -> HelperVersion {
        let output = try PMSetSleepSetting.run(executable, ["--version-json"], 2)
        return try JSONDecoder().decode(Self.self, from: Data(output.utf8))
    }
}

public enum HelperUpgrade: Equatable {
    case checking, missing, starting, ready, updateRequired, blocked(String)

    public static func assess(installed: Bool, version: HelperVersion?, runningVersion: HelperVersion?) -> Self {
        guard installed else { return .missing }
        guard let version = version else { return .updateRequired }
        let current = HelperVersion.current
        guard version.revision > 0, version.protocolVersion > 0, version.settingsSchema >= 0 else {
            return .blocked("Helper version is invalid. Update was blocked.")
        }
        if version.settingsSchema > current.settingsSchema || version.protocolVersion > current.protocolVersion ||
            (version.revision >= current.revision && version.protocolVersion != current.protocolVersion) {
            return .blocked("This helper requires a newer Battery Saver app. Downgrade was blocked.")
        }
        if version.revision < current.revision || version.protocolVersion != current.protocolVersion ||
            version.settingsSchema < current.settingsSchema { return .updateRequired }
        // A replaced file does not prove that launchd is running the replacement.
        if runningVersion == nil && version == current { return .starting }
        guard let runningVersion = runningVersion, runningVersion == version else {
            if version.revision > current.revision {
                return .blocked("The newer installed helper is not confirmed running. Use its matching app to repair it.")
            }
            return .updateRequired
        }
        return .ready
    }

    public var warning: String? {
        switch self {
        case .checking: return "Checking background helper compatibility…"
        case .starting: return "Starting the on-demand helper…"
        case .updateRequired: return "Background helper update required. Open Settings & details to update; settings will be preserved."
        case .blocked(let message): return message
        case .missing, .ready: return nil
        }
    }
}

public struct HelperUpdateAuthorization: Equatable {
    public private(set) var pending = false
    public init() {}
    public mutating func begin() -> Bool {
        guard !pending else { return false }; pending = true; return true
    }
    /// Cancellation leaves compatibility unchanged, so the update remains visible and retryable.
    public mutating func finish(succeeded: Bool, cancelled: Bool) -> Bool {
        pending = false
        return succeeded && !cancelled
    }
}
