#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
for script in Scripts/package.sh Scripts/install.sh Scripts/uninstall.sh Scripts/update-helper.sh Scripts/check.sh Resources/install-helper.sh; do
    /bin/zsh -n "$script"
done
/usr/bin/plutil -lint Resources/Info.plist Resources/local.paolo.battery-saver.plist
swift test --disable-sandbox --scratch-path "$PWD/.build/check"
python3 Scripts/verify_readings.py "$PWD/.build/check/debug/battery-saver-helper"
python3 Scripts/verify_update_helper.py
