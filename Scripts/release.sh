#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
[[ $# == 0 ]] || { print -u2 "Usage: Scripts/release.sh"; exit 2; }
configuration=release
for script in Scripts/*.sh Resources/Helper/*.sh; do
    /bin/zsh -n "$script"
done
/usr/bin/plutil -lint Resources/Info.plist Resources/local.paolo.battery-saver.plist
swift build --disable-sandbox -c release
swift test --disable-sandbox -c release
python3 Scripts/verify_readings.py "$PWD/.build/release/battery-saver-helper"
python3 Scripts/verify_update_helper.py "$PWD/.build/release/battery-saver-helper"
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
