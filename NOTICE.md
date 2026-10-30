# Protocol references

This project implements its own small AppleSMC bridge. Wire layout and operation
numbers were checked against the public smcFanControl header; charging-gate
values were checked against actuallymentor/battery. No third-party executable,
library, installer, or charging daemon is bundled.

- https://github.com/hholtmann/smcFanControl/blob/master/smc-command/smc.h
- https://github.com/actuallymentor/battery/blob/main/battery.sh
- https://github.com/charlie0129/batt

These interfaces are undocumented by Apple. Readback verifies a gate setting,
not physical charging behavior. Firmware compatibility requires live testing.
