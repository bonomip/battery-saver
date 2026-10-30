#!/bin/zsh
set -euo pipefail
(( EUID == 0 )) || { print -u2 'Administrator authorization is required.'; exit 1; }

root="${0:A:h:h}"
dir='/Library/Application Support/BatterySaver'
helper="$dir/battery-saver-helper"
plist='/Library/LaunchDaemons/local.paolo.battery-saver.plist'
status_path="$dir/status.json"
candidate="$root/dist/Battery Saver.app/Contents/Helpers/battery-saver-helper"
work=''
stopped=0
committed=0

fail() { print -u2 -- "$1"; exit 1; }
protected() {
    local file_path="$1" owner mode
    [[ ! -L "$file_path" ]] || fail "Refusing symbolic link: $file_path"
    owner=$(/usr/bin/stat -f '%u' "$file_path")
    mode=$(/usr/bin/stat -f '%Lp' "$file_path")
    [[ "$owner" == 0 ]] && (( (8#$mode & 8#22) == 0 )) || fail "Insecure installed path: $file_path"
}
[[ -d "$dir" && -f "$helper" && -f "$plist" ]] || fail 'An existing helper installation is required.'
protected "$dir"
protected "$helper"
protected "$plist"
[[ -f "$candidate" && ! -L "$candidate" ]] || fail 'The packaged replacement helper is missing or is a symbolic link.'
/usr/bin/codesign --verify --strict "$candidate"
"$candidate" --probe

# All temporary files remain inside the validated, root-owned installation directory.
work=$(/usr/bin/mktemp -d "$dir/.update.XXXXXXXX")
cleanup() {
    local result=$?
    local preserve_work=0
    set +e
    trap - EXIT HUP INT TERM
    if (( stopped && ! committed )); then
        print -u2 'Update failed; restoring the previous helper.'
        /bin/launchctl bootout system "$plist" >/dev/null 2>&1 || true
        # A previous helper version may not understand a new sleep recovery record.
        # Clear our saved hold with the candidate before restoring that version.
        if [[ -f "$dir/sleep-recovery.json" ]]; then
            if ! "$candidate" --restore-sleep; then
                print -u2 'Sleep restoration failed; recovery record and update files are retained.'
                preserve_work=1
                result=1
            fi
        fi
        if [[ -f "$work/original" ]]; then
            if ! /bin/mv -f "$work/original" "$helper"; then
                result=1
                preserve_work=1
                print -u2 "Previous helper backup retained in $work."
            fi
        fi
        if ! /bin/launchctl bootstrap system "$plist"; then
            print -u2 'Rollback could not restart the previous helper. Administrator intervention is required.'
            result=1
        fi
    fi
    if [[ -n "$work" ]] && (( ! preserve_work )); then
        /bin/rm -f "$work/original" "$work/replacement" "$work/marker"
        /bin/rmdir "$work" || result=1
    fi
    exit "$result"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
/usr/bin/install -o root -g wheel -m 755 "$candidate" "$work/replacement"
/usr/bin/codesign --verify --strict "$work/replacement"
/bin/cp -p "$helper" "$work/original"

# Require a new, successful daemon status rather than accepting stale JSON.
wait_status() {
    local expected="$1" limit="$2" running
    local deadline=$(( SECONDS + limit ))
    while (( SECONDS < deadline )); do
        if [[ -f "$status_path" && ! -L "$status_path" && "$status_path" -nt "$work/marker" ]]; then
            running=$(/usr/bin/plutil -extract running raw -o - "$status_path" 2>/dev/null) || running=''
            if [[ "$running" == "$expected" ]]; then
                if /usr/bin/plutil -extract error raw -o - "$status_path" >/dev/null 2>&1; then
                    print -u2 'The helper reported an error; refusing to continue.'
                    return 1
                fi
                return 0
            fi
        fi
        /bin/sleep 0.2
    done
    print -u2 "Timed out waiting for helper running=$expected."
    return 1
}

/usr/bin/touch "$work/marker"
# Mark before bootout so a partially successful stop also triggers recovery.
stopped=1
/bin/launchctl bootout system "$plist"
wait_status false 5
/bin/mv -f "$work/replacement" "$helper"
/usr/bin/touch "$work/marker"
/bin/launchctl bootstrap system "$plist"
wait_status true 10
committed=1
print 'Helper updated. Existing settings and calibration recovery files were preserved.'
