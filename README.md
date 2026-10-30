# Battery Saver

Native menu bar battery care for Paolo's M1 MacBook Pro on macOS 12. An
independent implementation: AlDente is not a dependency.

Click the menu bar percentage for quick readings. Choose **Settings & details…**
to open charge controls, calibration and helper management in a separate window.
Closing that window keeps the app and helper running. **Quit menu bar app** closes
the UI only; the installed helper continues its policy.

Both windows show the same observed battery activity: Charging, Plugged in · not
charging, or On battery. Protection is a separate setting; turning it off does
not stop macOS from charging. Green means charging, blue means plugged in without
charging, and yellow means running on battery. Unavailable readings use gray.

**Not yet accepted for replacing AlDente.** Live SMC access and administrator
operations are blocked in the development session. See [TESTING.md](TESTING.md).

## Implemented

- Adjustable upper/lower charge thresholds, default 80% / 75%.
- Natural drift between thresholds while continuing to use wall power.
- Charging pauses at 38°C; cooling threshold 35°C. These are conservative app
  policy values, not Apple-specified cell safety limits. Configurable via helper.
- Separate launch daemon maintains policy when the menu bar app closes.
- Exclusive helper ownership prevents a standalone restoration from racing the
  daemon. A recovery record is saved before calibration cuts adapter input and
  cleared only after restoration, so a restarted helper can restore wall power.
- Sleep notification handling pauses charging before sleep, reevaluates on wake,
  and never prevents system sleep. Sleep behavior still needs live verification.
- Live battery percentage, temperature, cycle count and capacity estimate.
- Optional manual calibration with confirmation and cancellation. It discharges
  to 15%, recharges to 100%, holds one hour, then restores the usual policy.
  It does not force-discharge back to 80% after completion.
- In-app helper installation and restoration/uninstallation, using macOS admin
  authorization. The helper installs with protection OFF.
- No networking, telemetry, dependencies on third-party controllers, fan control,
  or automatic calibration schedule.

## Build and check

From this directory:

```sh
/bin/zsh Scripts/check.sh
/bin/zsh Scripts/package.sh
```

The app is `dist/Battery Saver.app`. Builds use a local ad-hoc signature. This
is not a Developer ID signed or notarized distribution.

## Handover (administrator session, after hardware verification)

1. Keep AlDente active until the hardware checks in TESTING.md can be performed.
2. In AlDente, restore normal charging and remove/disable its helper, then quit
   AlDente and disable its automatic launch. Quitting its UI alone may leave its
   helper running. Keep AlDente installed as a fallback until acceptance passes.
3. Open Battery Saver and choose **Install helper…**. Alternatively run
   `sudo /bin/zsh Scripts/install.sh` from the project directory.
4. Enable battery protection and apply settings. macOS asks for administrator
   approval. Settings are applied within five seconds; check the displayed state.
5. Avoid another charging controller changing the same gates. While using this
   app, disable Optimized Battery Charging scheduling in macOS Battery settings;
   leave Apple's battery health and hardware safety mechanisms intact.

Restore normal charging and remove the service through the app, or run:

```sh
sudo /bin/zsh Scripts/uninstall.sh
```

The uninstaller stops on restoration errors and preserves the installation for
inspection. Removing only the app does not remove the background helper.

## Calibration behavior

Start only when readings appear inaccurate, with a cool Mac, charger connected
and lid open. Calibration adds a cycle and does not recover chemical capacity.
During deliberate discharge, the AC input may appear disconnected. A physical
disconnect can therefore be detected reliably only during recharge/holding;
once 15% is reached, the adapter gate is restored regardless. Keep the charger
attached throughout. Sleep cancels calibration instead of preventing sleep.
Restarted helpers restore normal policy and never replay an old start command.

The first supported controller requires readable legacy `CH0B`/`CH0C` charge
gates and `CH0I` adapter control. A failed adapter probe cannot silently disable
recovery. Other firmware is rejected. Known competing controllers are detected
before control, sleep and shutdown operations; this is not universal detection
of every possible third-party battery utility.
See [NOTICE.md](NOTICE.md) for protocol references.
