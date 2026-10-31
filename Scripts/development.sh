#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
source Scripts/lib/build.sh
[[ $# == 0 ]] || { print -u2 "Usage: Scripts/development.sh"; exit 2; }
configuration=debug
prepare_build
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
package_app "$configuration"
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
