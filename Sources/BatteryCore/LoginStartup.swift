import Foundation

/// A per-user LaunchAgent for the menu app on macOS 12. The system helper is separate.
public struct LoginStartup {
    public static let label = "local.paolo.battery-saver.login"
    public let directory: URL
    public var file: URL { directory.appendingPathComponent(Self.label + ".plist") }

    public init(directory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents")) {
        self.directory = directory
    }
    public static func configuration(app: URL) throws -> Data {
        guard app.isFileURL, app.pathExtension == "app", app.path.hasPrefix("/") else {
            throw SaverError("Start at login requires a packaged .app. Open Battery Saver.app first.")
        }
        let values: [String: Any] = ["Label": label, "ProgramArguments": ["/usr/bin/open", "-g", app.standardizedFileURL.path],
                                      "RunAtLoad": true, "LimitLoadToSessionType": "Aqua"]
        return try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
    }
    public func isEnabled(app: URL) -> Bool {
        guard let expected = try? Self.configuration(app: app), let actual = try? Data(contentsOf: file) else { return false }
        return actual == expected
    }
    public func setEnabled(_ enabled: Bool, app: URL) throws {
        let expected = try Self.configuration(app: app)
        let manager = FileManager.default
        if manager.fileExists(atPath: file.path) {
            let existing = try Data(contentsOf: file)
            let values = try PropertyListSerialization.propertyList(from: existing, format: nil) as? [String: Any]
            guard values?["Label"] as? String == Self.label else {
                throw SaverError("The login entry is not recognized. No file was changed.")
            }
        }
        if enabled {
            guard manager.fileExists(atPath: app.appendingPathComponent("Contents/Info.plist").path) else {
                throw SaverError("The app bundle is missing. Start at login was not enabled.")
            }
            if isEnabled(app: app) { return }
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            try expected.write(to: file, options: .atomic)
        } else if manager.fileExists(atPath: file.path) {
            try manager.removeItem(at: file)
        }
        guard isEnabled(app: app) == enabled else { throw SaverError("Could not verify the start-at-login entry.") }
    }
}
