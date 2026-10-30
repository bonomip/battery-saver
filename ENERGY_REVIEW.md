# Energy investigation

Paolo reported Current Energy Impact higher than idle Chrome/Remote Desktop while both Battery Saver windows were closed. Energy Impact is a relative macOS measure, not watts or CPU percentage. CPU measurements below do not substitute for a repeat of that observation.

## Baseline

An executed 55.742-second pair of cumulative CPU readings measured:

- Menu app: 1.01 CPU seconds, averaging 1.812% of one core.
- Installed helper: 0.11 CPU seconds, averaging 0.197% of one core.

Window activity was not controlled during that baseline interval. No defensible before/after Energy Impact comparison is claimed. Nine atomic helper status-file replacements were independently observed over45.232 seconds, consistent with five-second publishing. Evidence: Verification/energy-cpu-baseline.json and energy-status-baseline.json.

Source inspection found repeated @Published sample/status assignments on every five-second refresh, even when only timestamps changed; settingsDraft refresh also published on every mutation. Hidden SwiftUI menu/settings content remained retained, and the status icon/title/tooltip were reassigned every refresh.

## Implemented changes

- Compare normalized display snapshots, preserving helper freshness/error/running-state changes while ignoring heartbeat timestamps.
- Publish one UI update only when visible content changes; reopening forces a refresh.
- Avoid reassigning an unchanged settings draft.
- Cache the status image by percentage, activity, tone and appearance; assign title/tooltip only if changed.
- Release menu hosting content when dismissed and settings hosting content when closed.
- Add0.5-second timer tolerance; preserve five-second polling and existing power notifications.
- Calculate predictions only from genuinely new sensor readings, without process profiling or additional timers.
- Preserve the installed helper and its five-second policy/ownership checks. The helper's reader does not request the new OS time-estimate snapshot.

An executed hidden-model check performs100 refreshes with zero UI publications, then verifies one publication on reopening. It measured about20ms of process CPU for those100 reads in its initial run. This verifies a specific unnecessary-work fix, not real-world idle energy. Evidence: Verification/idle-refresh-check.log.

## Remaining acceptance

A subsequent executed idle measurement, after Paolo confirmed reopening the optimized app and closing both windows, recorded64.746 seconds with stable PIDs:

- Menu app:0.03 CPU seconds, averaging0.0463% of one core.
- Installed helper:0.13 CPU seconds, averaging0.2008% of one core.

The app's measured CPU use was about97% lower than the earlier interval, while the helper was essentially unchanged. Because baseline window activity was uncontrolled, this is not a controlled causal comparison. Accounting resolution was0.01 CPU seconds. Evidence: Verification/energy-cpu-after.json. Current Energy Impact still needs a comparable user check; no claim of measured watts or superiority to Chrome is made.

After Paolo reopens the optimized app and closes both windows, record a new paired cumulative CPU measurement and inspect Current Energy Impact under comparable idle conditions. Confirm the process did not restart during measurement. Check status/details interaction and menu appearance after view-release changes. If Energy Impact remains high, profile the running menu app and helper before changing safety checks. No battery-discharge, unplug/replug or sleep test has been inferred from CPU results.
