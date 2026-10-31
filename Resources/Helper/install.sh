#!/bin/zsh
set -euo pipefail
(( EUID == 0 )) || { print -u2 'Administrator authorization is required.'; exit 1; }
contents="${0:A:h:h:h}"
dir='/Library/Application Support/BatterySaver'
helper="$contents/Helpers/battery-saver-helper"
plist='/Library/LaunchDaemons/local.paolo.battery-saver.plist'
[[ -f "$helper" ]] || { print -u2 'The helper is missing from the app bundle.'; exit 1; }
[[ ! -e "$dir" && ! -L "$dir" && ! -e "$plist" && ! -L "$plist" ]] || {
    print -u2 'An installation or conflicting path already exists. Use the bundled updater for an existing helper; inspect conflicting paths.'; exit 1
}
/usr/bin/codesign --verify --strict "$helper"
version=$("$helper" --version-json)
revision=$(print -r -- "$version" | /usr/bin/plutil -extract revision raw -o - -)
protocol=$(print -r -- "$version" | /usr/bin/plutil -extract protocolVersion raw -o - -)
schema=$(print -r -- "$version" | /usr/bin/plutil -extract settingsSchema raw -o - -)
"$helper" --probe
/usr/bin/install -d -o root -g wheel -m 755 "$dir"
/usr/bin/install -o root -g wheel -m 755 "$helper" "$dir/battery-saver-helper"
# Start disabled; never take over charging implicitly during installation.
"$dir/battery-saver-helper" --configure 0 75 80 38 35
/usr/bin/install -o root -g wheel -m 644 "$contents/Resources/local.paolo.battery-saver.plist" "$plist"
/bin/launchctl bootstrap system "$plist"
if (( protocol >= 2 )); then
    "$dir/battery-saver-helper" --check-service
    print 'Helper installed on demand with protection OFF. It follows the app; settings remain saved on Quit.'
    exit 0
fi
# The directory was newly created, so any status file belongs to this install.
for attempt in {1..50}; do
    status_path="$dir/status.json"
    if [[ -f "$status_path" && ! -L "$status_path" &&
          $(/usr/bin/plutil -extract running raw -o - "$status_path" 2>/dev/null) == true &&
          $(/usr/bin/plutil -extract helperVersion.revision raw -o - "$status_path" 2>/dev/null) == "$revision" &&
          $(/usr/bin/plutil -extract helperVersion.protocolVersion raw -o - "$status_path" 2>/dev/null) == "$protocol" &&
          $(/usr/bin/plutil -extract helperVersion.settingsSchema raw -o - "$status_path" 2>/dev/null) == "$schema" ]] &&
       ! /usr/bin/plutil -extract error raw -o - "$status_path" >/dev/null 2>&1; then
        print 'Helper installed with protection OFF. Stop AlDente and its helper before enabling protection.'
        exit 0
    fi
    /bin/sleep 0.2
done
print -u2 'Helper startup was not confirmed. Installation retained for inspection or repair.'
exit 1
