#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
source Scripts/lib/build.sh
[[ $# == 0 ]] || { print -u2 "Usage: Scripts/release.sh"; exit 2; }
configuration=release
prepare_build
swift build --disable-sandbox -c release
swift test --disable-sandbox -c release
python3 Scripts/verify_readings.py "$PWD/.build/release/battery-saver-helper"
python3 Scripts/verify_update_helper.py "$PWD/.build/release/battery-saver-helper"
package_app "$configuration"
