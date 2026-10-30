# Battery information proposals

## Sleep capability investigation

Lid closed and system asleep are different conditions. A normal daemon can operate with the lid closed while the system is awake; it cannot be assumed to execute continuously through deep sleep. A firmware-enforced percentage limit would avoid that requirement.

Read-only hardware inventory reconfirmed MacBookPro17,1 / AppleM1 / macOS12.6.5 / firmware8419.80.7. Current upstream batt documents firmware-managed percentage ranges via bfF0/bfD0/bfE0 on newer20xxx firmware, including sleep enforcement; older legacy control uses sleep workarounds. This documents a possible capability in newer firmware, not support on this Mac. No read of those range keys has yet established availability here; permission denial would also not prove a key absent. No hardware writes, firmware/OS upgrades or sleep-prevention setting changes were performed.

Source: https://github.com/charlie0129/batt . Apple documents that ordinary idle-sleep assertions do not override lid-close/manual sleep: https://developer.apple.com/documentation/iokit/kiopmassertiontypepreventuseridlesystemsleep . Any keep-awake-with-lid-closed mode therefore needs explicit capability testing rather than assuming a normal idle assertion is sufficient. Sleep policy remains undecided; preserve the prepared wake-cycle fix separately.

The battery-shaped menu icon and low-battery color are implemented. Paolo subsequently approved net discharge detection and time estimates; those are now implemented and regression-tested. Per-app energy usage remains deferred. The sections below retain the design rationale and limits.

## Net discharge while plugged in

Current behavior uses ExternalConnected and IsCharging. A connected battery that is losing energy therefore appears blue, just like a battery deliberately paused at its limit. That distinction needs improvement.

Recommendation: show yellow/amber with "Plugged in · battery draining" when fresh signed battery-current readings confirm sustained net discharge. Red overrides noncharging colors at 15% or below. Keep blue for connected, not charging, without confirmed discharge; green for confirmed charging. Do not diagnose an insufficient adapter from wattage alone: demand, negotiation, cable, thermal limits and charging policy also matter.

Use a small current noise band and hysteresis, and verify genuine sensor updates rather than counting repeated cached values as independent samples. Reset confidence on power-source changes and reject stale/contradictory readings. Sensor telemetry on this Mac has sometimes refreshed about once per minute. Faster UI polling cannot make those readings fresh. Explain a discharge observation rather than claiming a specific cause. No adapter cut or forced discharge should be introduced for this display feature.

Acceptance: test sustained positive/negative/near-zero current, load spikes, cached data, reconnect, deliberate limit pause, unavailable readings and low-charge priority. Physical load tests require comparison against independent measurements; do not use heavy work solely to force a battery transition without coordinating it.

## Remaining time

Recommendation: one contextual estimate row in the status window. Show time remaining during discharge and time to the actual target while charging. If protection is off, target is 100%; if protection is on, target is its upper limit. Show "Estimating…" or unavailable instead of inventing a number when data is missing or unstable. Detailed readings belong in Settings & details, not the menu bar.

macOS IOPS exposes Time to Full Charge and Time to Empty in minutes. Read the former only while charging and the latter only in its documented battery-power context. IOPSGetTimeRemainingEstimate returns seconds, or unknown/unlimited sentinels. A live read returned151 minutes to full and unlimited remaining time while AC-powered. This establishes access to the full-charge estimate, not accuracy or an estimate to our custom limit.

An estimate to an arbitrary charge limit or to empty while AC is connected and the battery is draining requires a separate validated model when macOS does not supply a valid value. Recommend a smoothed estimate labeled approximate, guarded for stale/zero/noisy rates and charge taper. Never relabel the OS estimate to100% as time to80%, or assume a linear fraction is accurate. This is a consequential choice between OS-only estimates with gaps and an additional estimator; Paolo chooses.

Sources: https://developer.apple.com/documentation/iokit/kiopstimetofullchargekey ; https://developer.apple.com/documentation/iokit/kiopstimetoemptykey ; https://developer.apple.com/documentation/iokit/1523835-iopsgettimeremainingestimate

## Apps using energy

Recommendation for the first version: a Details action opening Activity Monitor, whose Energy tab provides Apple's Energy Impact view. Do not claim CPU usage is exact battery energy, watts, percentage of battery or minutes recoverable by quitting an app.

Alternative: an explicitly labeled CPU-activity approximation, sampled only while the relevant window is open, grouping helper processes under their app where ownership is known. This is not Apple's "Using Significant Energy" list. No supported third-party API for reproducing that exact list on macOS12 has been verified in this review. Private framework access or continuous privileged profiling would add compatibility/energy costs and is not recommended for this battery-care app.

Sources: https://support.apple.com/guide/activity-monitor/view-energy-consumption-actmntr43697/mac ; https://firefox-source-docs.mozilla.org/performance/activity_monitor_and_top.html (historical technical investigation, not proof of a current public API).
