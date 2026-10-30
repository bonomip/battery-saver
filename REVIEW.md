# Independent review and final assessment

Review performed by the primary agent, with three GPT-6.1 Sol agents reviewing
charging logic, helper lifecycle and UI behavior. The primary agent reviewed the
changes, integrated them, and executed the full check script and release build.

The prior 33 passing tests did not establish correctness. This review found
concrete defects outside that coverage. The implementation is improved, but
hardware acceptance is still outstanding; it cannot be called bug-free.

## Confirmed defects corrected

| Defect | Correction and evidence |
| --- | --- |
| Heat cancellation resumed charging above the cooling threshold | Recovery now evaluates through the same policy and preserves its thermal latch. Reproduced before the fix; regression covers 40°C cancellation, 37°C pause and 35°C resume. |
| Adapter restoration failure skipped the charging pause before sleep | Both operations are attempted independently and all errors are reported. Reproduced before the fix; injected failures test both gates. |
| Failed charge pause wrote “enable charging” to both gates as rollback | Removed opposite-direction rollback; both requested gates are attempted independently. The real gate algorithm now runs against a scripted SMC transport in tests. |
| Failed adapter probe was silently treated as unsupported forever | Startup now requires valid readings from all three supported legacy gates. Failed probe/retry is tested; physical compatibility remains unverified. |
| Corrupt settings bypassed a known competing-controller check | Ownership is checked before settings/sensor reads. Reproduced on the original daemon; lifecycle regression asserts no charge writes. |
| Failed ownership check left cached permission for sleep/shutdown | Each lifecycle event checks ownership anew. Unknown/conflicting ownership permits only restoration of our recorded adapter cut. |
| Standalone restore could race a running calibration tick | Daemon and standalone restore share an exclusive file lock. Uninstall disables configuration, stops the daemon, then restores. File-lock behavior is tested; actual privileged launchd sequencing still needs live validation. |
| Duplicate helper startup could overwrite the live helper's status | Lock acquisition precedes hardware construction and status-publishing authority. A lock loser only reports its own CLI failure. |
| Stopped helper retained a fresh “protected” status | Status explicitly records whether the helper is running; stopped status is immediately ineligible for current protection. |
| Edits made during authorization were discarded | Versioned draft state preserves newer edits and accepts only a fresh healthy acknowledgement. Original model race reproduced; six state tests cover acknowledgement/failure/timeout. |
| Crash during discharge lost adapter ownership | Recovery intent is saved and synchronized before disconnecting input and cleared after confirmed restoration. Restart tests include a competing controller and failed ownership checks; filesystem tests verify the record. |
| Cancelling discharge could briefly enable charging above the cap | Policy accounts for restored adapter input instead of using the pre-restoration “on battery” flag. Regression cancels at 95% and verifies immediate charge pause. |
| Disabled helper kept issuing repeated hardware control operations | It restores once, then leaves gates alone while disabled. Lifecycle regression covers startup and enabled-to-disabled transition. |
| A wall-clock adjustment could shorten the calibration hold or trigger its timeout | Duration now uses monotonic elapsed time. Tests move wall time forward/backward while checking the one-hour hold and uptime-reset cancellation. |

Additional corrections: unknown sensor state no longer displays “On battery”;
calibration and protection indicators require current helper/sensor state; long
errors scroll; the verification script refuses root execution so its permission
rejection check cannot accidentally apply a configuration.

## Evidence and limitations

- `Verification/automated-tests.log`: the primary agent's complete debug test
  run and independent live IOKit/ioreg comparison.
- `Verification/release-build.log`: optimized build and bundle signature checks.
- `Verification/release-tests.log`: the same regression suite executed with release optimization.
- `Verification/runtime-checks.json`: final packaged signature, sensor comparison,
  read-only SMC failure, packaged launch failure and offscreen rendering results.
- `Verification/interface-preview.png`: inspected optimized interface render.
- `Verification/registration-control.json`: minimal native app control experiment
  reproducing the bundled launch failure independently of Battery Saver code.

No hardware write, helper installation, AlDente shutdown, physical charging
transition, physical calibration, reboot, sleep/wake or long-term energy test
was performed. Simulated hardware and real filesystem tests do not substitute
for those checks. TESTING.md retains the remaining acceptance procedure.

The recovery record covers process crashes/restarts. The filesystem test is not
a power-loss durability experiment, and no guarantee of control while macOS is
shut down is made.
