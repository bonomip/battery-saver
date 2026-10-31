#!/bin/zsh
set -euo pipefail
(( EUID == 0 )) || { print -u2 'Administrator authorization is required.'; exit 1; }

contents="${0:A:h:h:h}"
dir='/Library/Application Support/BatterySaver'
helper="$dir/battery-saver-helper"
plist='/Library/LaunchDaemons/local.paolo.battery-saver.plist'
status_path="$dir/status.json"
settings_path="$dir/settings.json"
candidate="$contents/Helpers/battery-saver-helper"
work=''
stopped=0
committed=0
settings_changed=0
locked=0

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
expected_version=$("$candidate" --version-json)
version_field() { print -r -- "$1" | /usr/bin/plutil -extract "$2" raw -o - -; }
expected_revision=$(version_field "$expected_version" revision)
expected_protocol=$(version_field "$expected_version" protocolVersion)
expected_schema=$(version_field "$expected_version" settingsSchema)
for number in "$expected_revision" "$expected_protocol" "$expected_schema"; do
    [[ "$number" == <-> ]] || fail 'Invalid candidate helper version.'
done
(( expected_revision > 0 && expected_protocol > 0 )) || fail 'Invalid candidate helper version.'
installed_version=$("$helper" --version-json 2>/dev/null) || installed_version=''
if [[ -n "$installed_version" ]]; then
    installed_revision=$(version_field "$installed_version" revision)
    installed_protocol=$(version_field "$installed_version" protocolVersion)
    installed_schema=$(version_field "$installed_version" settingsSchema)
    for number in "$installed_revision" "$installed_protocol" "$installed_schema"; do
        [[ "$number" == <-> ]] || fail 'Invalid installed helper version.'
    done
    (( installed_revision > 0 && installed_protocol > 0 && installed_revision <= expected_revision && installed_protocol <= expected_protocol && installed_schema <= expected_schema )) || fail 'Helper downgrade refused; use a newer app.'
    if (( installed_revision == expected_revision && installed_protocol != expected_protocol )); then
        fail 'Helper protocol is incompatible; use its matching app.'
    fi
fi
[[ -f "$settings_path" ]] || fail 'Installed helper settings are missing.'
protected "$settings_path"
if [[ -n "$installed_version" && -f "$status_path" && ! -L "$status_path" ]] &&
   (( installed_revision == expected_revision && installed_protocol == expected_protocol && installed_schema == expected_schema )); then
    status_age=$(( $(/bin/date +%s) - $(/usr/bin/stat -f '%m' "$status_path") ))
    if (( status_age >= 0 && status_age <= 30 )) &&
       [[ $(/usr/bin/plutil -extract running raw -o - "$status_path" 2>/dev/null) == true &&
          $(/usr/bin/plutil -extract helperVersion.revision raw -o - "$status_path" 2>/dev/null) == "$expected_revision" &&
          $(/usr/bin/plutil -extract helperVersion.protocolVersion raw -o - "$status_path" 2>/dev/null) == "$expected_protocol" &&
          $(/usr/bin/plutil -extract helperVersion.settingsSchema raw -o - "$status_path" 2>/dev/null) == "$expected_schema" ]] &&
       ! /usr/bin/plutil -extract error raw -o - "$status_path" >/dev/null 2>&1; then
        print 'Helper is already up to date.'
        exit 0
    fi
fi
"$candidate" --probe

# All temporary files remain inside the validated, root-owned installation directory.
work=$(/usr/bin/mktemp -d "$dir/.update.XXXXXXXX")
cleanup() {
    local result=$?
    local preserve_work=0
    set +e
    trap - EXIT HUP INT TERM
    if (( stopped && ! committed )); then
        local restored=1
        print -u2 'Update failed; restoring the previous helper.'
        /bin/launchctl bootout system "$plist" >/dev/null 2>&1 || true
        if ! ensure_stopped; then
            print -u2 'Cannot confirm helper shutdown; rollback files retained without replacing live files.'
            result=1; preserve_work=1; restored=0
        fi
        # A previous helper version may not understand a new sleep recovery record.
        # Clear our saved hold with the candidate before restoring that version.
        if (( restored )) && [[ -f "$dir/sleep-recovery.json" ]]; then
            if ! "$candidate" --restore-sleep; then
                print -u2 'Sleep restoration failed; recovery record and update files are retained.'
                preserve_work=1
                result=1
                restored=0
            fi
        fi
        if (( restored && settings_changed )); then
            if ! /bin/cp -p "$work/settings-original" "$work/settings-rollback" ||
               ! /bin/mv -f "$work/settings-rollback" "$settings_path"; then
                print -u2 'Original settings could not be restored; backup retained.'
                preserve_work=1; result=1; restored=0
            fi
        fi
        if (( restored )) && [[ -f "$work/original" ]]; then
            if ! /bin/mv -f "$work/original" "$helper"; then
                result=1
                preserve_work=1
                print -u2 "Previous helper backup retained in $work."
                restored=0
            fi
        fi
        if (( restored )) && [[ -f "$work/plist-original" ]]; then
            /bin/cp -p "$work/plist-original" "$plist" || { result=1; preserve_work=1; restored=0; }
        fi
        # Verify the previous version is running, including legacy versions without metadata.
        expected_revision=''
        /usr/bin/touch "$work/marker"
        if (( ! restored )) || ! /bin/launchctl bootstrap system "$plist" || ! confirm_started; then
            print -u2 'Rollback could not restart the previous helper. Administrator intervention is required.'
            result=1; preserve_work=1
        fi
    fi
    if [[ -n "$work" ]] && (( ! preserve_work )); then
        /bin/rm -f "$work/original" "$work/replacement" "$work/marker" "$work/settings-original" "$work/settings-rollback" "$work/migrated-settings" "$work/plist-original"
        /bin/rmdir "$work" || result=1
    fi
    if (( locked )); then /bin/rmdir "$dir/.update-lock" || result=1; fi
    exit "$result"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
/bin/mkdir -m 700 "$dir/.update-lock" || fail 'Another helper update is active, or a previous update lock needs inspection.'
locked=1
# Validate migration before stopping the daemon; repeat against its final settings below.
"$candidate" --migrate-settings "$settings_path" > "$work/migrated-settings"
/usr/bin/install -o root -g wheel -m 755 "$candidate" "$work/replacement"
/usr/bin/codesign --verify --strict "$work/replacement"
/bin/cp -p "$helper" "$work/original"
/bin/cp -p "$plist" "$work/plist-original"

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
                if [[ "$expected" == true && -n "${expected_revision:-}" ]]; then
                    [[ $(/usr/bin/plutil -extract helperVersion.revision raw -o - "$status_path" 2>/dev/null) == "$expected_revision" &&
                       $(/usr/bin/plutil -extract helperVersion.protocolVersion raw -o - "$status_path" 2>/dev/null) == "$expected_protocol" &&
                       $(/usr/bin/plutil -extract helperVersion.settingsSchema raw -o - "$status_path" 2>/dev/null) == "$expected_schema" ]] || { /bin/sleep 0.2; continue; }
                fi
                return 0
            fi
        fi
        /bin/sleep 0.2
    done
    print -u2 "Timed out waiting for helper running=$expected."
    return 1
}

ensure_stopped() {
    # launchd must have relinquished the service before we test the process lock.
    if /bin/launchctl print system/local.paolo.battery-saver >/dev/null 2>&1; then return 1; fi
    for attempt in {1..50}; do
        if "$candidate" --check-stopped >/dev/null 2>&1; then return 0; fi
        /bin/sleep 0.1
    done
    return 1
}

confirm_started() {
    local metadata protocol
    metadata=$("$helper" --version-json 2>/dev/null) || metadata=''
    protocol=$(version_field "$metadata" protocolVersion 2>/dev/null) || protocol=0
    if [[ "$protocol" == <-> ]] && (( protocol >= 2 )); then
        "$helper" --check-service
    else
        wait_status true 10
    fi
}

/usr/bin/touch "$work/marker"
# Mark before bootout so a partially successful stop also triggers recovery.
stopped=1
# An on-demand service may already have exited cleanly. Legacy daemons always
# need a new stopped status; active sessions do too.
already_stopped=0
if (( ${installed_protocol:-0} >= 2 )) &&
   [[ $(/usr/bin/plutil -extract running raw -o - "$status_path" 2>/dev/null) == false ]]; then
    already_stopped=1
fi
/bin/launchctl bootout system "$plist"
if (( ! already_stopped )); then wait_status false 5; fi
ensure_stopped || fail 'Helper did not release control; replacement refused.'
# Capture the last settings written by the old daemon. Rollback restores these exact bytes.
protected "$settings_path"
/bin/cp -p "$settings_path" "$work/settings-original"
"$candidate" --migrate-settings "$settings_path" > "$work/migrated-settings"
/bin/chmod 644 "$work/migrated-settings"
settings_changed=1
/bin/mv -f "$work/migrated-settings" "$settings_path"
/bin/mv -f "$work/replacement" "$helper"
/usr/bin/install -o root -g wheel -m 644 "$contents/Resources/local.paolo.battery-saver.plist" "$plist"
/usr/bin/touch "$work/marker"
/bin/launchctl bootstrap system "$plist"
confirm_started
committed=1
print 'Helper updated. Saved settings were preserved; the helper now follows the app.'
