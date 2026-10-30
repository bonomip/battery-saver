import BatteryCore
import Foundation

/// Ignore heartbeat timestamps when deciding whether SwiftUI needs another render.
struct DisplaySnapshot: Equatable {
    let sample: BatterySample?
    let status: HelperStatus?
    let helperCurrent: Bool
    let helperInstalled: Bool
    let warning: String?
    let activity: String
    let estimate: String?

    init(sample: BatterySample?, status: HelperStatus?, helperInstalled: Bool, warning: String?, activity: String, estimate: String?) {
        var reading = sample
        reading?.date = .distantPast
        var helper = status
        helper?.date = .distantPast
        helper?.sample = nil
        self.sample = reading; self.status = helper
        self.helperCurrent = status?.isCurrent == true
        self.helperInstalled = helperInstalled; self.warning = warning
        self.activity = activity; self.estimate = estimate
    }
}
