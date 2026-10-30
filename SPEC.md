# Battery Saver — proposed scope

Status: production implementation in progress; live hardware acceptance pending.

## Goal

Fully replace AlDente on Paolo's M1 MacBook Pro with only controls useful
for preserving battery lifespan. AlDente must not be a runtime dependency.
First target: macOS 12.6.5, MacBookPro17,1, firmware 8419.80.7.

## Proposed behavior

- Stop charging at 80% by default; make the upper limit adjustable.
- Resume below a lower threshold (proposed default 75%). Between thresholds,
  retain the previous charging decision to avoid rapid toggling.
- Keep wall power available while charging is paused. Do not deliberately
  cycle the battery to maintain the range; let it discharge naturally.
- Pause charging above a configurable battery-temperature threshold and resume
  only after cooling. Initial values require sensor validation; they are an
  app policy, not Apple-specified battery safety limits.
- Show charge, temperature, and why charging is allowed or paused.
- Maintain protection independently of the menu bar window and after login.
- Handle sleep and wake without keeping the Mac awake. Legacy hardware may
  need charging paused before sleep and the policy reevaluated on wake.
- Include an explicit restore-normal-charging and uninstall path.
- Reject activation while another charging controller owns control.
- Validate missing/stale sensor data and unsupported controls; show an error
  instead of claiming protection. Leave Apple's battery safeguards intact.

Include manual, explicitly confirmed calibration at Paolo's request: discharge
to 15%, charge to 100%, hold for one hour, then restore ordinary limits. Only
this mode may disable adapter input. Heat, sleep, failed readings, a recharge
disconnect, a helper restart, or a 24-hour timeout cancels the cycle. Do not
schedule it automatically. The cycle is intended to help gauge accuracy;
it does not restore chemical battery capacity.

Exclude routine full-charge cycles, MagSafe customization, and unrelated
automation. A temporary full-charge
override is deferred because it serves runtime convenience, not preservation.

## Architecture decision

Option A: native Swift interface plus an existing open-source controller.
Less new hardware-control code, but adds a dependency and requires checking
its compatibility, installation privileges, and recovery behavior.

Option B: native Swift interface plus our own narrowly scoped privileged helper.
More control and fewer runtime dependencies, but more hardware verification and
helper installation work, especially on macOS 12.

Paolo approved Option B. First prove
read-only compatibility, then verify a reversible charging toggle before
implementing unattended control. This supersedes the earlier general-purpose
recommendation to wrap an existing controller; existing projects remain useful
technical references.

## Acceptance gate (before replacing AlDente)

1. Deterministic policy checks cover threshold boundaries, retained state,
   thermal pause/resume, disconnected AC, invalid/stale readings, and restart.
2. On this Mac, independently observe charging current/state before and after
   a pause and restore operation. A successful write alone is insufficient.
3. Observe a real upper/lower threshold transition while plugged in, without
   disconnecting wall power or deliberately draining the battery.
4. Simulate thermal boundaries in policy checks; validate live temperature
   units without intentionally heating the battery.
5. Execute sleep/wake, UI quit, helper restart, and reboot checks; document
   exactly what protection is possible during sleep and shutdown.
6. Execute restore/uninstall and verify normal charging can resume.
7. Measure idle CPU usage and wakeups; resolve repeated polling or sleep issues.
8. Require exclusive hardware ownership for daemon/restoration commands and
   persist adapter recovery intent before calibration disconnects wall power.

No hardware writes, AlDente changes, helper installation, or live charging-control
tests have been performed. Automated policy/integration tests, live battery reads,
independent ioreg comparisons, release builds, signature checks, and offscreen
rendering have run. See TESTING.md for the exact limits of verification.

## References

- AlDente features: https://apphousekitchen.com/aldente-overview/features/
- Apple lifespan advice: https://www.apple.com/batteries/maximizing-performance/
- Existing Apple Silicon controller and compatibility notes:
  https://github.com/charlie0129/batt
