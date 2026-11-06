#!/system/bin/sh
# odin_mode: ignore MIUI thermal-engine CPU caps by default.
# mode 0 (balanced) = GPU unlocked (built-in) + CPU unlocked (this script).
# Reversible anytime: echo -1 > /sys/kernel/odin_mode/thermal_cpu_override
M=/sys/kernel/odin_mode
[ -d "$M" ] || exit 0
echo 1 > $M/thermal_cpu_override
echo 0 > $M/mode   # retrigger reset: drop any stale freq_qos caps
