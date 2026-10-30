"""Exercise the updater's status checks without privileges or installed-service writes."""
import os
from pathlib import Path
import shlex
import subprocess
import tempfile

if os.geteuid() == 0:
    raise SystemExit("Run updater checks as your normal user.")

source = Path("Scripts/update-helper.sh").read_text()
status_function = source[source.index("wait_status() {"):source.index('\n/usr/bin/touch "$work/marker"')]
with tempfile.TemporaryDirectory(prefix="battery-updater-check-") as folder:
    script = """#!/bin/zsh
set -euo pipefail
work=FOLDER
status_path="$work/status.json"
for mode in 755 700 644; do (( (8#$mode & 8#22) == 0 )); done
for mode in 775 777 664; do (( (8#$mode & 8#22) != 0 )); done
""".replace("FOLDER", shlex.quote(folder)) + status_function + """
/usr/bin/touch "$work/marker"
/bin/sleep 0.05
print '{"running":true}' > "$status_path"
wait_status true 2
print '{"running":true,"error":"Injected failure"}' > "$status_path"
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

result = subprocess.run(["/bin/zsh", "Scripts/update-helper.sh"], capture_output=True, text=True)
assert result.returncode != 0 and "Administrator authorization is required" in result.stderr
print("PASS: updater rejects non-admin execution before installed-service access.")
