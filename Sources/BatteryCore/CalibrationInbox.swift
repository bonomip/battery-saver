import Foundation

public struct CalibrationCommand: Codable {
    public let id: UUID
    public let start: Bool
    public let date: Date
    public init(id: UUID = UUID(), start: Bool, date: Date = Date()) { self.id = id; self.start = start; self.date = date }
}

/// A new daemon consumes the existing command without replaying it after a crash.
public struct CalibrationInbox {
    private var seen: UUID?
    public init(existing: CalibrationCommand? = nil) { seen = existing?.id }
    public mutating func consume(_ command: CalibrationCommand, now: Date = Date()) -> Bool? {
        guard command.id != seen else { return nil }
        seen = command.id
        if !command.start { return false }
        return (0...30).contains(now.timeIntervalSince(command.date))
    }
}
