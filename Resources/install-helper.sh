#!/bin/zsh
set -euo pipefail
(( EUID == 0 )) || { print -u2 'Administrator authorization is required.'; exit 1; }
contents="${0:A:h:h}"
dir='/Library/Application Support/BatterySaver'
helper="$contents/Helpers/battery-saver-helper"
plist='/Library/LaunchDaemons/local.paolo.battery-saver.plist'
[[ -f "$helper" ]] || { print -u2 'The helper is missing from the app bundle.'; exit 1; }
[[ ! -e "$dir" && ! -L "$dir" && ! -e "$plist" && ! -L "$plist" ]] || {
    print -u2 'An installation or conflicting path already exists. Restore and uninstall it before installing.'; exit 1
}
/usr/bin/codesign --verify --strict "$helper"
"$helper" --probe
/usr/bin/install -d -o root -g wheel -m 755 "$dir"
/usr/bin/install -o root -g wheel -m 755 "$helper" "$dir/battery-saver-helper"
# Start disabled; never take over charging implicitly during installation.
"$dir/battery-saver-helper" --configure 0 75 80 38 35
/usr/bin/install -o root -g wheel -m 644 "$contents/Resources/local.paolo.battery-saver.plist" "$plist"
/bin/launchctl bootstrap system "$plist"
print 'Helper installed with protection OFF. Stop AlDente and its helper before enabling protection.'
