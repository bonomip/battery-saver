#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
[[ $# == 0 ]] || { print -u2 "Usage: Scripts/development.sh"; exit 2; }
configuration=debug
for script in Scripts/*.sh Resources/Helper/*.sh; do
    /bin/zsh -n "$script"
done
/usr/bin/plutil -lint Resources/Info.plist Resources/local.paolo.battery-saver.plist
swift build --disable-sandbox -c debug
# Exact method names keep the fast gate small and reviewable.
tests=("${(@f)$(<Scripts/critical-tests.txt)}")
(( ${#tests} > 0 )) || { print -u2 'Critical test list is empty.'; exit 1; }
available=$(swift test --disable-sandbox -c debug --list-tests)
for test in "${tests[@]}"; do
    if ! /usr/bin/grep -Fxq "BatteryCoreTests.$test" <<< "$available"; then
        print -u2 "Critical test is missing or renamed: $test"
        exit 1
    fi
done
filter="^BatteryCoreTests\.(${(j:|:)tests})$"
swift test --disable-sandbox -c debug --skip-build --filter "$filter"
app="$PWD/dist/Battery Saver.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/Helper" "$app/Contents/Helpers"
/usr/bin/install -m 755 ".build/$configuration/BatterySaver" "$app/Contents/MacOS/BatterySaver"
/usr/bin/install -m 755 ".build/$configuration/battery-saver-helper" "$app/Contents/Helpers/battery-saver-helper"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/AppIcon.icns "$app/Contents/Resources/"
cp Resources/local.paolo.battery-saver.plist "$app/Contents/Resources/"
cp Scripts/helper.sh "$app/Contents/Resources/"
cp Resources/Helper/*.sh "$app/Contents/Resources/Helper/"
# Remove legacy entry points when repackaging an existing app bundle.
/bin/rm -f "$app/Contents/Resources/install-helper.sh" "$app/Contents/Resources/update-helper.sh" "$app/Contents/Resources/uninstall-helper.sh"
/usr/bin/codesign --force --sign - "$app/Contents/Helpers/battery-saver-helper"
/usr/bin/codesign --force --sign - "$app"
/usr/bin/codesign --verify --deep --strict "$app"
/usr/bin/plutil -lint "$app/Contents/Info.plist"
print "Built ($configuration): $app"
# Quit the previous UI so open cannot reuse an older running executable.
# An updated helper restores charging when this UI connection closes, then restarts on demand.
if /usr/bin/pgrep -x BatterySaver >/dev/null; then
    /usr/bin/pkill -x BatterySaver
    for attempt in {1..50}; do
        /usr/bin/pgrep -x BatterySaver >/dev/null || break
        /bin/sleep 0.1
    done
    if /usr/bin/pgrep -x BatterySaver >/dev/null; then
        print -u2 'Previous UI is still running; quit it before launching the new build.'
        exit 1
    fi
fi
/usr/bin/open "$PWD/dist/Battery Saver.app"
print 'Debug app launched. Validate the changed behavior manually.'
