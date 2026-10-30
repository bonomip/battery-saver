# Verification record

Interactive acceptance progress is tracked in [MANUAL_TESTS.md](MANUAL_TESTS.md).
After the Test 1 notification/label change, all 85 debug tests, live sensor comparison,
permission rejection checks and release packaging/signature checks passed again.
Logs: `Verification/test1-regression.log` and `Verification/test1-build.log`.
Notification latency, interactive layout and energy impact still require a live retest.

Target: MacBookPro17,1 / Apple M1, macOS 12.6.5, firmware 8419.80.7.
Date: 2026-10-27. No claim of hardware acceptance is made.

## Executed

- 85 Swift tests passed in both debug and release builds with zero failures:
  threshold boundaries, charge and temperature hysteresis, restart
  defaults, stale/invalid readings, configuration validation, calibration phase
  transitions and one-hour hold with a simulated monotonic clock, cancellation, timeout,
  command expiry and replay prevention.
- Integration tests use the same ProtectionSession as the daemon with injected
  hardware. Check adapter/charging operation order, restoration after errors,
  unsupported calibration, sleep cancellation, disabled policy, restart, and
  thermal recovery. Fault-injected SMC transport tests also exercise actual
  paired-gate code, read/write failures and readback mismatches. These verify
  software decisions, not physical hardware.
- Lifecycle regressions cover known/unknown ownership, corrupt settings,
  sleep/shutdown rechecks, disabled operation, stopped status and restart recovery.
  Actual filesystem tests cover exclusive locking and atomic recovery records.
  UI draft tests cover edits during authorization, stale acknowledgement,
  authorization failure and timeout.
- C bridge rejects arbitrary keys, invalid charge/adapter values and malformed
  lengths before it attempts a hardware call.
- Real IOKit battery reader compared with a separate ioreg snapshot: charge,
  external power, temperature conversion, cycles and estimated capacity agree.
- Helper rejects non-admin configuration and unknown CLI commands.
- Installer/uninstaller reject non-admin invocation; shell syntax and both
  property lists validate. Root installation/removal have NOT run.
- Optimized arm64 release build and app/helper ad-hoc signature verification.
- Offscreen SwiftUI rendering of debug and optimized executables; preview
  inspected for clipping, legibility, inactive protection state and installation
  controls. No window was opened or remote session altered.

The check script is `Scripts/check.sh`; packaging is `Scripts/package.sh`.
Final run logs are retained in `Verification/`.

## Blocked or not executed

- AppleSMC open returns -536870174 in this restricted session. No charge-gate or
  adapter-gate write was performed. `--probe` returns failure on unavailable SMC.
- `sudo` execution is denied by this environment. No helper installation,
  activation, restoration, uninstallation or AlDente modification was performed.
- Launching the packaged app directly in this session aborted during Apple's
  `_RegisterApplication`, before our UI ran. The crash stack also reports
  LaunchServices database initialization errors. The review reproduced the same
  failure with a minimal native AppKit application: standalone initialization
  succeeds, but bundling that identical probe causes SIGABRT before application
  initialization completes. This isolates the failure from Battery Saver's
  charging/UI logic, but packaged interactive launch in a normal session remains
  unverified. Evidence: `Verification/registration-control.json`.
- No interactive admin-dialog/button testing, sleep/wake or reboot test, physical
  charging transition, complete physical calibration, or long-running CPU and
  wakeup measurement. Do not infer these from passing simulated tests.

## Remaining acceptance procedure

Use an unrestricted local administrator session and retain AlDente as fallback.
Do not run two controllers simultaneously.

1. Run `dist/Battery Saver.app/Contents/Helpers/battery-saver-helper --probe`
   (quote the path) and record battery readings and readable gate values.
2. Restore normal charging in AlDente and disable its helper. Install Battery
   Saver's helper while protection is OFF. Verify the app and admin dialogs.
3. Observe a real charging state/current, enable a limit below current charge,
   and independently confirm that current and charging state settle to paused
   while external power remains connected. Gate readback alone does not pass.
4. Raise the restart threshold above current charge (with a higher upper limit)
   and independently observe charging resume. Finally restore 75% / 80%.
5. Observe an actual threshold crossing and verify hysteresis rather than rapid
   toggling. Observe wall-power operation without deliberate discharge in normal
   protection mode.
6. Test UI quit, helper restart, sleep/wake, clamshell and reboot. On this legacy
   implementation, charging is intentionally paused during sleep while enabled.
   No protection during shutdown is promised.
7. Validate live temperature plausibility; test thermal thresholds by safely
   varying configured thresholds around ambient readings, never heating the
   battery intentionally. Restore the default 38°C / 35°C afterward.
8. Start calibration with explicit confirmation. Verify current flows out only
   in discharge, adapter restoration at 15%, recharge to full and one-hour hold,
   then ordinary limits. Test cancel/sleep/unplug and recovery separately. A
   complete physical cycle takes hours and has not been replaced by simulation.
9. Restore and uninstall; independently confirm normal charging. Verify no
   Battery Saver service remains. Reinstall only after this passes.
10. Measure actual helper/app idle CPU, timer wakeups and energy impact with
    Activity Monitor/Instruments. A small binary alone is not evidence of low
    energy use.

Until these pass, the result is a built, partially verified implementation,
not a tested AlDente replacement.

See REVIEW.md for the defects found and fixed during the independent review.
