"""Exercise the updater's status checks without privileges or installed-service writes."""
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile

if os.geteuid() == 0:
    raise SystemExit("Run updater checks as your normal user.")

source = Path("Resources/Helper/update.sh").read_text()
status_start = source.index("wait_status() {")
status_function = source[status_start:source.index('\n/usr/bin/touch "$work/marker"', status_start)]
Path("tmp").mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(prefix="battery-updater-check-", dir="tmp") as folder:
    script = """#!/bin/zsh
set -euo pipefail
work=FOLDER
status_path="$work/status.json"
for mode in 755 700 644; do (( (8#$mode & 8#22) == 0 )); done
for mode in 775 777 664; do (( (8#$mode & 8#22) != 0 )); done
""".replace("FOLDER", shlex.quote(str(Path(folder).resolve()))) + status_function + """
/usr/bin/touch "$work/marker"
/bin/sleep 0.05
print '{"running":true}' > "$status_path"
wait_status true 2
expected_revision=2
expected_protocol=1
expected_schema=1
# A fresh status from the wrong executable must not confirm an upgrade.
print '{"running":true,"helperVersion":{"revision":1,"protocolVersion":1,"settingsSchema":1}}' > "$status_path"
if wait_status true 1; then exit 1; fi
print '{"running":true,"helperVersion":{"revision":2,"protocolVersion":1,"settingsSchema":1}}' > "$status_path"
wait_status true 2
expected_revision=''
print '{"running":true,"error":"Injected failure"}'  > "$status_path"
if wait_status true 2; then exit 1; fi
print '{"running":false}' > "$status_path"
wait_status false 2
/bin/sleep 0.05
/usr/bin/touch "$work/marker"
if wait_status false 1; then exit 1; fi
/bin/sleep 0.05
print 'invalid json' > "$status_path"
if wait_status false 1; then exit 1; fi
print 'PASS: updater fresh true/false, error, stale and malformed status checks.'
"""
    fixture = Path(folder) / "check.zsh"
    fixture.write_text(script)
    result = subprocess.run(["/bin/zsh", str(fixture)], capture_output=True, text=True)
    if result.returncode:
        raise SystemExit(result.stdout + result.stderr)
    print(result.stdout.strip())

result = subprocess.run(["/bin/zsh", "Resources/Helper/update.sh"], capture_output=True, text=True)
assert result.returncode != 0 and "Administrator authorization is required" in result.stderr
print("PASS: updater rejects non-admin execution before installed-service access.")

# Verify the dispatcher independently: argument validation, all three actions,
# paths containing spaces, and propagation of operation exit status.
with tempfile.TemporaryDirectory(prefix="helper dispatcher ", dir="tmp") as folder:
    root = Path(folder).resolve()
    operations = root / "Helper"
    operations.mkdir()
    dispatcher = root / "helper.sh"
    dispatcher.write_text(Path("Scripts/helper.sh").read_text())
    for code, action in enumerate(("install", "update", "uninstall"), start=10):
        (operations / f"{action}.sh").write_text(f"#!/bin/zsh\nprint -- {action}\nexit {code}\n")
        result = subprocess.run(["/bin/zsh", str(dispatcher), action], capture_output=True, text=True, cwd="/")
        assert result.returncode == code and result.stdout.strip() == action, result
    for arguments in ([], ["invalid"], ["install", "update"]):
        result = subprocess.run(["/bin/zsh", str(dispatcher)] + arguments, capture_output=True, text=True)
        assert result.returncode == 2 and "Usage:" in result.stderr
print("PASS: helper dispatcher validates arguments, routes all operations, and propagates failures.")

# Exercise complete scripts from a downloaded bundle. Only version queries and
# settings migration use the real helper; privileged tools and hardware are fixtures.
actual_helper = Path(sys.argv[1] if len(sys.argv) > 1 else ".build/debug/battery-saver-helper").resolve()
version = json.loads(subprocess.check_output([str(actual_helper), "--version-json"], text=True))

def helper_fixture(metadata, installed):
    return ("#!/usr/bin/env python3\n" + f'''
from pathlib import Path
import json, subprocess, sys
metadata = {metadata!r}
command = sys.argv[1]
if command == "--version-json":
    if metadata is None: sys.exit(2)
    print(json.dumps(metadata))
elif command == "--migrate-settings":
    sys.exit(subprocess.run([{str(actual_helper)!r}] + sys.argv[1:]).returncode)
elif command == "--configure":
    settings = dict(enabled=sys.argv[2] == "1", lower=int(sys.argv[3]), upper=int(sys.argv[4]),
                    heatPause=float(sys.argv[5]), heatResume=float(sys.argv[6]),
                    keepAwakeUntilLimit=True, schemaVersion={version['settingsSchema']})
    Path({str(installed / 'settings.json')!r}).write_text(json.dumps(settings))
elif command not in ("--probe", "--restore-sleep", "--restore", "--check-stopped"):
    sys.exit(2)
''').encode()

for scenario in ("fresh", "legacy", "older", "same", "rollback", "newer", "future-settings", "invalid-settings", "shutdown-unconfirmed", "uninstall"):
    with tempfile.TemporaryDirectory(prefix="battery-upgrade-", dir="tmp") as folder:
        root = Path(folder).resolve()
        contents = root / "downloaded" / "Battery Saver.app" / "Contents"
        resources = contents / "Resources"
        helpers = contents / "Helpers"
        installed = root / "installed"
        for directory in (resources, helpers):
            directory.mkdir(parents=True)
        if scenario != "fresh": installed.mkdir()
        old_version = None
        if scenario == "older": old_version = dict(version, revision=version["revision"] - 1, settingsSchema=0)
        if scenario == "same": old_version = version
        if scenario == "newer": old_version = dict(version, revision=version["revision"] + 1, settingsSchema=version["settingsSchema"] + 1)
        old = helper_fixture(old_version, installed)
        new = helper_fixture(version, installed)
        helper = installed / "battery-saver-helper"
        candidate = helpers / "battery-saver-helper"
        candidate.write_bytes(new); candidate.chmod(0o755)
        plist = root / "daemon.plist"
        (resources / "local.paolo.battery-saver.plist").write_text("fixture")
        settings = dict(enabled=True, lower=70, upper=85, heatPause=40, heatResume=36, customNote="preserve")
        if scenario == "future-settings": settings["schemaVersion"] = version["settingsSchema"] + 1
        if scenario == "invalid-settings": settings["lower"] = 99
        preserved = {
            "settings.json": json.dumps(settings).encode(),
            "adapter-recovery.json": b'true',
            "sleep-recovery.json": b'true',
        }
        if scenario != "fresh":
            helper.write_bytes(old); helper.chmod(0o755)
            plist.write_text("fixture")
            for name, data in preserved.items(): (installed / name).write_bytes(data)
            if scenario == "same":
                (installed / "status.json").write_text(json.dumps(dict(running=True, helperVersion=version)))
        launchctl = root / "launchctl.py"
        launchctl.write_text("#!/usr/bin/env python3\n" + f'''
from pathlib import Path
import json, sys, time
installed = Path({str(installed)!r})
action = sys.argv[1]
if action == "print": sys.exit(0 if {scenario == "shutdown-unconfirmed"!r} else 1)
replacement = (installed / "battery-saver-helper").read_bytes() == {new!r}
if action == "bootstrap" and replacement and {scenario == 'rollback'!r}:
    sys.exit(1)
time.sleep(0.05)
status = dict(running=action == "bootstrap")
if replacement: status["helperVersion"] = {version!r}
(installed / "status.json").write_text(json.dumps(status))
with (installed / "launches.log").open("a") as log:
    log.write(action + (" new" if replacement else " old") + "\\n")
''')
        launchctl.chmod(0o755)
        action = "install" if scenario == "fresh" else "uninstall" if scenario == "uninstall" else "update"
        script_name = action + ".sh"
        fixture = Path("Resources/Helper", script_name).read_text().replace(
            "(( EUID == 0 )) || { print -u2 'Administrator authorization is required.'; exit 1; }",
            "# Administrator check exercised separately above.",
        ).replace(
            "dir='/Library/Application Support/BatterySaver'", "dir=" + shlex.quote(str(installed))
        ).replace(
            "plist='/Library/LaunchDaemons/local.paolo.battery-saver.plist'", "plist=" + shlex.quote(str(plist))
        ).replace(
            '[[ "$owner" == 0 ]]', f'[[ "$owner" == {os.geteuid()} ]]'
        ).replace('/usr/bin/codesign', '/usr/bin/true').replace(
            '/bin/launchctl', shlex.quote(str(launchctl))
        ).replace(' -o root -g wheel', '').replace('"/Library/LaunchDaemons/$label.plist"', shlex.quote(str(plist)))
        operation_folder = resources / "Helper"
        operation_folder.mkdir()
        executable = operation_folder / script_name
        executable.write_text(fixture)
        dispatcher = resources / "helper.sh"
        dispatcher.write_text(Path("Scripts/helper.sh").read_text())
        result = subprocess.run(["/bin/zsh", str(dispatcher), action], capture_output=True, text=True)
        failed = scenario in ("rollback", "newer", "future-settings", "invalid-settings", "shutdown-unconfirmed")
        assert (result.returncode != 0) == failed, scenario + result.stdout + result.stderr
        if scenario == "uninstall":
            assert not installed.exists() and not plist.exists()
            print("PASS: bundled helper lifecycle: uninstall.")
            continue
        if scenario in ("newer", "same", "future-settings", "invalid-settings"):
            assert not (installed / "launches.log").exists(), scenario
            assert helper.read_bytes() == old
            assert (installed / "settings.json").read_bytes() == preserved["settings.json"]
        elif scenario == "shutdown-unconfirmed":
            assert helper.read_bytes() == old
            assert (installed / "settings.json").read_bytes() == preserved["settings.json"]
            assert "bootstrap" not in (installed / "launches.log").read_text()
            assert list(installed.glob(".update.*")), "Rollback backups must be retained"
        elif scenario == "rollback":
            assert helper.read_bytes() == old
            assert (installed / "settings.json").read_bytes() == preserved["settings.json"]
            assert "bootstrap old" in (installed / "launches.log").read_text()
        else:
            assert helper.read_bytes() == new
            migrated = json.loads((installed / "settings.json").read_text())
            assert migrated["schemaVersion"] == version["settingsSchema"]
            if scenario == "fresh":
                assert migrated["enabled"] is False
            else:
                for key, value in settings.items(): assert migrated[key] == value, key
                assert migrated["keepAwakeUntilLimit"] is True
        if scenario != "fresh":
            for name in ("adapter-recovery.json", "sleep-recovery.json"):
                assert (installed / name).read_bytes() == preserved[name], name
        if scenario in ("fresh", "legacy", "older", "rollback", "same"):
            assert json.loads((installed / "status.json").read_text())["running"] is True
        if scenario != "shutdown-unconfirmed":
            assert not list(installed.glob(".update.*")), "Update staging files leaked"
        assert not (installed / ".update-lock").exists(), "Update lock leaked"
        print(f"PASS: bundled helper lifecycle: {scenario}.")
