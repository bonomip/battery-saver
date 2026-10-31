#!/bin/zsh
set -euo pipefail
(( EUID == 0 )) || { print -u2 'Administrator authorization is required.'; exit 1; }
dir='/Library/Application Support/BatterySaver'
label='local.paolo.battery-saver'
helper="$dir/battery-saver-helper"
[[ -f "$helper" && ! -L "$dir" && ! -L "$helper" ]] || { print -u2 'No valid helper installation found.'; exit 1; }
# Disable the policy without a second process writing hardware. Stop the daemon
# before acquiring its exclusive lock for restoration. Preserve files on errors.
"$helper" --configure 0 75 80 38 35
if /bin/launchctl print "system/$label" >/dev/null 2>&1; then
    /bin/launchctl bootout "system/$label"
fi
"$helper" --restore
/bin/rm -f "/Library/LaunchDaemons/$label.plist"
# Only known files are removed; preserve unexpected contents for inspection.
/bin/rm -f "$dir/settings.json" "$dir/status.json" "$dir/calibration-request.json" "$dir/adapter-recovery.json" "$dir/sleep-recovery.json" "$dir/daemon.lock" "$helper"
/bin/rmdir "$dir"
print 'Helper removed; normal macOS charging restored.'
