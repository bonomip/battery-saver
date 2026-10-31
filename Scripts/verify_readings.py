"""Compare our IOKit reader against an independent ioreg snapshot; no writes."""
import json
import os
import re
import subprocess
import sys

if os.geteuid() == 0:
    raise SystemExit("Run verification as your normal user; permission-rejection checks must not run as root.")

helper = sys.argv[1]
result = subprocess.run([helper, "--battery-json"], check=True, capture_output=True, text=True)
sample = json.loads(result.stdout)
raw = subprocess.check_output(["/usr/sbin/ioreg", "-r", "-c", "AppleSmartBattery", "-l"], text=True)
registry = {}
for key, value in re.findall(r'^\s*"(CurrentCapacity|ExternalConnected|Temperature|CycleCount|AppleRawMaxCapacity|DesignCapacity)" = (Yes|No|\d+)\s*$', raw, re.MULTILINE):
    registry[key] = (value == "Yes") if value in ("Yes", "No") else int(value)
assert abs(sample["percent"] - registry["CurrentCapacity"]) <= 1, "Charge reading mismatch"
assert sample["externalPower"] == registry["ExternalConnected"], "AC status mismatch"
assert abs(sample["temperature"] - (registry["Temperature"] / 10 - 273.15)) < 2, "Temperature conversion mismatch"
assert sample["cycles"] == registry["CycleCount"], "Cycle count mismatch"
expected_health = registry["AppleRawMaxCapacity"] / registry["DesignCapacity"] * 100
assert abs(sample["healthPercent"] - expected_health) < 1, "Capacity estimate mismatch"
print("PASS: live charge, AC state, temperature, cycles and capacity agree with ioreg.")

for args in (["--configure", "1", "75", "80", "38", "35"], ["--restore-sleep"], ["--check-stopped"], ["--unknown"]):
    denied = subprocess.run([helper] + args, capture_output=True, text=True)
    assert denied.returncode != 0, f"Invalid/unprivileged operation was accepted: {args}"
print("PASS: unprivileged settings changes and unknown commands are rejected.")
