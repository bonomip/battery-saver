import Foundation

/// Keeps an editable draft separate from the configuration awaiting helper acknowledgement.
public struct SettingsDraft {
    public private(set) var settings: Settings
    public private(set) var appliedSettings: Settings
    public private(set) var edited = false
    public private(set) var pendingSettings: Settings?
    private var revision = 0
    private var submittedRevision = 0
    private var acceptedAfter: Date?
    private var deadline: Date?

    public init(settings: Settings = Settings(enabled: false)) { self.settings = settings; self.appliedSettings = settings }

    public mutating func edit<Value>(_ keyPath: WritableKeyPath<Settings, Value>, to value: Value) {
        settings[keyPath: keyPath] = value
        revision += 1
        edited = true
    }

    public mutating func beginApply() throws -> Settings {
        try settings.validate()
        pendingSettings = settings
        submittedRevision = revision
        acceptedAfter = nil
        deadline = nil
        return settings
    }

    public mutating func authorizationFinished(succeeded: Bool, cancelled: Bool = false, now: Date = Date()) {
        guard pendingSettings != nil else { return }
        if succeeded {
            acceptedAfter = now
            deadline = now.addingTimeInterval(20)
        } else {
            pendingSettings = nil
            acceptedAfter = nil
            deadline = nil
            if cancelled {
                settings = appliedSettings
                edited = false
            } else { edited = true }
        }
    }

    /// Returns an actionable error when an authorized write was never confirmed by the daemon.
    public mutating func refresh(status: HelperStatus?, now: Date = Date()) -> String? {
        if let status = status, status.isCurrent { appliedSettings = status.settings }
        if let pending = pendingSettings {
            if let acceptedAfter = acceptedAfter, let status = status,
               status.isCurrent, status.date >= acceptedAfter, status.settings == pending {
                pendingSettings = nil
                self.acceptedAfter = nil
                deadline = nil
                if revision == submittedRevision { settings = status.settings; edited = false }
            } else if let deadline = deadline, now >= deadline {
                pendingSettings = nil
                acceptedAfter = nil
                self.deadline = nil
                edited = true
                return "The helper has not confirmed these settings. Your draft is preserved; check the helper status and apply again."
            }
        } else if !edited, let status = status, status.isCurrent {
            settings = status.settings
        }
        return nil
    }

    public mutating func helperUnavailable() {
        settings.enabled = false
        pendingSettings = nil
        acceptedAfter = nil
        deadline = nil
    }
}
