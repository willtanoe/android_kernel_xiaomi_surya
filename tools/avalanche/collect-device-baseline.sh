#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Avalanche device baseline collector.
#
# This script performs read-only ADB operations to capture a structured
# snapshot of a Surya device. It never requests root, never writes to sysfs or
# properties, never changes tracing state, and never creates files on the
# device. All data is pulled to the host output directory.
#
# Usage:
#   ./collect-device-baseline.sh [-s <serial>] [-o <output-dir>] [-n <samples>]
#
# Defaults:
#   serial:     first available ADB device (adb devices)
#   output-dir: ./avalanche-baseline-<timestamp>
#   samples:    30 (one sample every 2 seconds -> ~60 seconds)

set -euo pipefail

SAMPLES=30
INTERVAL_SECONDS=2
OUTPUT_DIR=""
SERIAL=""

usage() {
	cat <<EOF
Usage: $0 [-s <serial>] [-o <output-dir>] [-n <samples>]

  -s  ADB device serial (default: first available device)
  -o  Host output directory (default: ./avalanche-baseline-<timestamp>)
  -n  Number of periodic samples (default: ${SAMPLES})
  -h  Show this help message
EOF
}

while getopts "s:o:n:h" opt; do
	case "${opt}" in
		s) SERIAL="${OPTARG}" ;;
		o) OUTPUT_DIR="${OPTARG}" ;;
		n) SAMPLES="${OPTARG}" ;;
		h) usage; exit 0 ;;
		*) usage; exit 2 ;;
	esac
done

TIMESTAMP="$(date -u +%Y%m%d%H%M%S)"
readonly TIMESTAMP
if [[ -z "${OUTPUT_DIR}" ]]; then
	OUTPUT_DIR="avalanche-baseline-${TIMESTAMP}"
fi
mkdir -p "${OUTPUT_DIR}"
OUTPUT_DIR="$(realpath "${OUTPUT_DIR}")"
readonly OUTPUT_DIR

# ADB invocation helper. Uses -s only when a serial is provided.
adb_cmd() {
	if [[ -n "${SERIAL}" ]]; then
		adb -s "${SERIAL}" "$@"
	else
		adb "$@"
	fi
}

log() {
	echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" | tee -a "${OUTPUT_DIR}/collector.log"
}

# Read a remote file via shell cat; does not require root.
adb_read_file() {
	local src="${1}"
	local dst="${2}"
	if ! adb_cmd shell "cat '${src}' 2>/dev/null" >"${dst}" 2>/dev/null; then
		echo "UNAVAILABLE: ${src}" >"${dst}"
	fi
}

# Read a directory listing without creating files on the device.
adb_list_dir() {
	local src="${1}"
	local dst="${2}"
	if ! adb_cmd shell "ls -la '${src}' 2>/dev/null" >"${dst}" 2>/dev/null; then
		echo "UNAVAILABLE: ${src}" >"${dst}"
	fi
}

log "Starting Avalanche baseline collection"
log "Output directory: ${OUTPUT_DIR}"
log "Samples: ${SAMPLES} at ${INTERVAL_SECONDS}s interval"
log "ADB serial: ${SERIAL:-<default>}"

# Verify adb is available.
if ! command -v adb >/dev/null 2>&1; then
	log "ERROR: adb not found in PATH"
	exit 1
fi

# Verify device is reachable.
if ! adb_cmd shell "echo ping" >/dev/null 2>&1; then
	log "ERROR: cannot reach device via ADB"
	exit 1
fi

# ---------------------------------------------------------------------------
# 1. Static identity and build provenance
# ---------------------------------------------------------------------------
log "Collecting device identity and kernel identity"
mkdir -p "${OUTPUT_DIR}/identity"

adb_cmd shell getprop >"${OUTPUT_DIR}/identity/getprop.txt" 2>/dev/null || echo "UNAVAILABLE: getprop" >"${OUTPUT_DIR}/identity/getprop.txt"
adb_cmd shell "cat /proc/version" >"${OUTPUT_DIR}/identity/proc_version.txt" 2>/dev/null || echo "UNAVAILABLE: /proc/version" >"${OUTPUT_DIR}/identity/proc_version.txt"
adb_cmd shell "uname -a" >"${OUTPUT_DIR}/identity/uname.txt" 2>/dev/null || echo "UNAVAILABLE: uname" >"${OUTPUT_DIR}/identity/uname.txt"
adb_read_file /proc/cmdline "${OUTPUT_DIR}/identity/cmdline.txt"
adb_read_file /sys/devices/soc0/machine "${OUTPUT_DIR}/identity/soc0_machine.txt"
adb_read_file /sys/devices/soc0/revision "${OUTPUT_DIR}/identity/soc0_revision.txt"
adb_read_file /sys/devices/soc0/platform_version "${OUTPUT_DIR}/identity/soc0_platform_version.txt"
adb_read_file /sys/firmware/devicetree/base/model "${OUTPUT_DIR}/identity/dt_model.txt"
adb_list_dir /sys/firmware/devicetree/base "${OUTPUT_DIR}/identity/dt_base_ls.txt"

# Kernel release and manifest, if present in /proc or /sys.
adb_read_file /proc/sys/kernel/osrelease "${OUTPUT_DIR}/identity/kernel_release.txt"
adb_cmd shell "ls -la /proc/config.gz /sys/kernel/config 2>/dev/null || true" >"${OUTPUT_DIR}/identity/config_availability.txt" 2>/dev/null || true

# ---------------------------------------------------------------------------
# 2. Active device tree summary (read-only via /proc/device-tree)
# ---------------------------------------------------------------------------
log "Collecting active device tree summary"
mkdir -p "${OUTPUT_DIR}/devicetree"
adb_cmd shell "find /proc/device-tree -maxdepth 2 -type f -exec echo {} \; -exec head -c 256 {} \; -echo 2>/dev/null" >"${OUTPUT_DIR}/devicetree/nodes_summary.txt" 2>/dev/null || echo "UNAVAILABLE: /proc/device-tree" >"${OUTPUT_DIR}/devicetree/nodes_summary.txt"

# ---------------------------------------------------------------------------
# 3. Android policy state
# ---------------------------------------------------------------------------
log "Collecting Android policy state"
mkdir -p "${OUTPUT_DIR}/android_policy"
adb_cmd shell "getenforce" >"${OUTPUT_DIR}/android_policy/selinux_mode.txt" 2>/dev/null || echo "UNAVAILABLE: getenforce" >"${OUTPUT_DIR}/android_policy/selinux_mode.txt"
adb_read_file /sys/fs/selinux/enforce "${OUTPUT_DIR}/android_policy/selinux_enforce.txt"
adb_read_file /sys/fs/selinux/policyvers "${OUTPUT_DIR}/android_policy/selinux_policyvers.txt"
adb_cmd shell "dumpsys activity policy" >"${OUTPUT_DIR}/android_policy/dumpsys_activity_policy.txt" 2>/dev/null || echo "UNAVAILABLE: dumpsys activity policy" >"${OUTPUT_DIR}/android_policy/dumpsys_activity_policy.txt"
adb_cmd shell "dumpsys deviceidle" >"${OUTPUT_DIR}/android_policy/dumpsys_deviceidle.txt" 2>/dev/null || echo "UNAVAILABLE: dumpsys deviceidle" >"${OUTPUT_DIR}/android_policy/dumpsys_deviceidle.txt"

# ---------------------------------------------------------------------------
# 4. CPU and GPU frequencies and governors
# ---------------------------------------------------------------------------
log "Collecting CPU/GPU frequency policy"
mkdir -p "${OUTPUT_DIR}/cpufreq"
adb_cmd shell "ls -la /sys/devices/system/cpu/cpufreq 2>/dev/null" >"${OUTPUT_DIR}/cpufreq/cpufreq_dirs.txt" 2>/dev/null || echo "UNAVAILABLE: cpufreq dirs" >"${OUTPUT_DIR}/cpufreq/cpufreq_dirs.txt"
adb_cmd shell "for p in /sys/devices/system/cpu/cpufreq/policy*; do echo \"=== \$p ===\"; cat \$p/scaling_governor 2>/dev/null; cat \$p/scaling_cur_freq 2>/dev/null; cat \$p/scaling_min_freq 2>/dev/null; cat \$p/scaling_max_freq 2>/dev/null; done" >"${OUTPUT_DIR}/cpufreq/policy_state.txt" 2>/dev/null || echo "UNAVAILABLE: cpufreq policy state" >"${OUTPUT_DIR}/cpufreq/policy_state.txt"
adb_cmd shell "for cpu in /sys/devices/system/cpu/cpu[0-9]*; do echo \"=== \$cpu ===\"; cat \$cpu/online 2>/dev/null; cat \$cpu/cpufreq/scaling_cur_freq 2>/dev/null; done" >"${OUTPUT_DIR}/cpufreq/per_cpu_state.txt" 2>/dev/null || echo "UNAVAILABLE: per-cpu state" >"${OUTPUT_DIR}/cpufreq/per_cpu_state.txt"

mkdir -p "${OUTPUT_DIR}/gpu"
adb_cmd shell "ls -la /sys/class/kgsl/kgsl-3d0 2>/dev/null || ls -la /sys/class/misc/mali0 2>/dev/null || true" >"${OUTPUT_DIR}/gpu/gpu_dirs.txt" 2>/dev/null || true
adb_read_file /sys/class/kgsl/kgsl-3d0/gpuclk "${OUTPUT_DIR}/gpu/kgsl_gpuclk.txt"
adb_read_file /sys/class/kgsl/kgsl-3d0/devfreq/cur_freq "${OUTPUT_DIR}/gpu/kgsl_cur_freq.txt"
adb_read_file /sys/class/kgsl/kgsl-3d0/devfreq/governor "${OUTPUT_DIR}/gpu/kgsl_governor.txt"
adb_read_file /sys/class/kgsl/kgsl-3d0/idle_timer "${OUTPUT_DIR}/gpu/kgsl_idle_timer.txt"

# ---------------------------------------------------------------------------
# 5. Thermal and battery state
# ---------------------------------------------------------------------------
log "Collecting thermal and battery state"
mkdir -p "${OUTPUT_DIR}/thermal"
adb_cmd shell "dumpsys thermalservice" >"${OUTPUT_DIR}/thermal/dumpsys_thermalservice.txt" 2>/dev/null || echo "UNAVAILABLE: dumpsys thermalservice" >"${OUTPUT_DIR}/thermal/dumpsys_thermalservice.txt"
adb_cmd shell "for z in /sys/class/thermal/thermal_zone*; do echo \"=== \$z ===\"; cat \$z/type 2>/dev/null; cat \$z/temp 2>/dev/null; done" >"${OUTPUT_DIR}/thermal/thermal_zones.txt" 2>/dev/null || echo "UNAVAILABLE: thermal zones" >"${OUTPUT_DIR}/thermal/thermal_zones.txt"
adb_cmd shell "for c in /sys/class/thermal/cooling_device*; do echo \"=== \$c ===\"; cat \$c/type 2>/dev/null; cat \$c/cur_state 2>/dev/null; done" >"${OUTPUT_DIR}/thermal/cooling_devices.txt" 2>/dev/null || echo "UNAVAILABLE: cooling devices" >"${OUTPUT_DIR}/thermal/cooling_devices.txt"

mkdir -p "${OUTPUT_DIR}/power"
adb_cmd shell "dumpsys battery" >"${OUTPUT_DIR}/power/dumpsys_battery.txt" 2>/dev/null || echo "UNAVAILABLE: dumpsys battery" >"${OUTPUT_DIR}/power/dumpsys_battery.txt"
adb_read_file /sys/class/power_supply/battery/capacity "${OUTPUT_DIR}/power/battery_capacity.txt"
adb_read_file /sys/class/power_supply/battery/status "${OUTPUT_DIR}/power/battery_status.txt"
adb_read_file /sys/class/power_supply/battery/current_now "${OUTPUT_DIR}/power/battery_current_now.txt"
adb_read_file /sys/class/power_supply/battery/voltage_now "${OUTPUT_DIR}/power/battery_voltage_now.txt"
adb_read_file /sys/class/power_supply/battery/temp "${OUTPUT_DIR}/power/battery_temp.txt"

# ---------------------------------------------------------------------------
# 6. PSI, ZRAM, memory, and storage
# ---------------------------------------------------------------------------
log "Collecting PSI, ZRAM, memory, and storage state"
mkdir -p "${OUTPUT_DIR}/memory"
adb_read_file /proc/pressure/cpu "${OUTPUT_DIR}/memory/psi_cpu.txt"
adb_read_file /proc/pressure/memory "${OUTPUT_DIR}/memory/psi_memory.txt"
adb_read_file /proc/pressure/io "${OUTPUT_DIR}/memory/psi_io.txt"
adb_cmd shell "free -h" >"${OUTPUT_DIR}/memory/free.txt" 2>/dev/null || echo "UNAVAILABLE: free" >"${OUTPUT_DIR}/memory/free.txt"
adb_cmd shell "cat /proc/meminfo" >"${OUTPUT_DIR}/memory/meminfo.txt" 2>/dev/null || echo "UNAVAILABLE: /proc/meminfo" >"${OUTPUT_DIR}/memory/meminfo.txt"
adb_cmd shell "zramctl 2>/dev/null || cat /sys/block/zram0/mm_stat 2>/dev/null || true" >"${OUTPUT_DIR}/memory/zram.txt" 2>/dev/null || true
adb_cmd shell "swapon -s 2>/dev/null || cat /proc/swaps 2>/dev/null || true" >"${OUTPUT_DIR}/memory/swaps.txt" 2>/dev/null || true

mkdir -p "${OUTPUT_DIR}/storage"
adb_cmd shell "df -h" >"${OUTPUT_DIR}/storage/df.txt" 2>/dev/null || echo "UNAVAILABLE: df" >"${OUTPUT_DIR}/storage/df.txt"
adb_cmd shell "mount | grep -E 'f2fs|ext4'" >"${OUTPUT_DIR}/storage/mounts.txt" 2>/dev/null || echo "UNAVAILABLE: mount" >"${OUTPUT_DIR}/storage/mounts.txt"
adb_cmd shell "cat /proc/diskstats" >"${OUTPUT_DIR}/storage/diskstats.txt" 2>/dev/null || echo "UNAVAILABLE: /proc/diskstats" >"${OUTPUT_DIR}/storage/diskstats.txt"

# ---------------------------------------------------------------------------
# 7. Suspend and error evidence
# ---------------------------------------------------------------------------
log "Collecting suspend and kernel error evidence"
mkdir -p "${OUTPUT_DIR}/errors"
adb_read_file /sys/power/wakeup_count "${OUTPUT_DIR}/errors/wakeup_count.txt"
adb_read_file /sys/power/suspend_stats "${OUTPUT_DIR}/errors/suspend_stats.txt"
adb_read_file /sys/kernel/debug/wakeup_sources "${OUTPUT_DIR}/errors/wakeup_sources.txt"
adb_cmd shell "dmesg -T -l err,warn 2>/dev/null | tail -n 200" >"${OUTPUT_DIR}/errors/dmesg_err_warn.txt" 2>/dev/null || echo "UNAVAILABLE: dmesg" >"${OUTPUT_DIR}/errors/dmesg_err_warn.txt"
adb_cmd shell "logcat -d -b crash 2>/dev/null | tail -n 200" >"${OUTPUT_DIR}/errors/logcat_crash.txt" 2>/dev/null || echo "UNAVAILABLE: logcat crash" >"${OUTPUT_DIR}/errors/logcat_crash.txt"
adb_cmd shell "logcat -d -b events 2>/dev/null | tail -n 200" >"${OUTPUT_DIR}/errors/logcat_events.txt" 2>/dev/null || echo "UNAVAILABLE: logcat events" >"${OUTPUT_DIR}/errors/logcat_events.txt"

# ---------------------------------------------------------------------------
# 8. Bounded periodic sampling
# ---------------------------------------------------------------------------
log "Starting bounded periodic sampling (${SAMPLES} samples)"
mkdir -p "${OUTPUT_DIR}/samples"

sample_file="${OUTPUT_DIR}/samples/periodic.csv"
echo "index,utc_timestamp,cpu0_freq,cpu4_freq,cpu7_freq,gpu_freq,kgsl_idle_ms,battery_temp_c,thermal_soc,psi_cpu_some_avg60" >"${sample_file}"

for i in $(seq 1 "${SAMPLES}"); do
	utc_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	cpu0_freq="$(adb_cmd shell "cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null" 2>/dev/null || echo NA)"
	cpu4_freq="$(adb_cmd shell "cat /sys/devices/system/cpu/cpu4/cpufreq/scaling_cur_freq 2>/dev/null" 2>/dev/null || echo NA)"
	cpu7_freq="$(adb_cmd shell "cat /sys/devices/system/cpu/cpu7/cpufreq/scaling_cur_freq 2>/dev/null" 2>/dev/null || echo NA)"
	gpu_freq="$(adb_cmd shell "cat /sys/class/kgsl/kgsl-3d0/devfreq/cur_freq 2>/dev/null" 2>/dev/null || echo NA)"
	kgsl_idle_ms="$(adb_cmd shell "cat /sys/class/kgsl/kgsl-3d0/idle_timer 2>/dev/null" 2>/dev/null || echo NA)"
	battery_temp="$(adb_cmd shell "cat /sys/class/power_supply/battery/temp 2>/dev/null" 2>/dev/null || echo NA)"
	thermal_soc="$(adb_cmd shell "cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null" 2>/dev/null || echo NA)"
	psi_cpu_some_avg60="$(adb_cmd shell "awk '/some/{print \$4}' /proc/pressure/cpu 2>/dev/null" 2>/dev/null || echo NA)"

	# Strip trailing carriage returns from adb shell output.
	cpu0_freq="${cpu0_freq%$'\r'}"
	cpu4_freq="${cpu4_freq%$'\r'}"
	cpu7_freq="${cpu7_freq%$'\r'}"
	gpu_freq="${gpu_freq%$'\r'}"
	kgsl_idle_ms="${kgsl_idle_ms%$'\r'}"
	battery_temp="${battery_temp%$'\r'}"
	thermal_soc="${thermal_soc%$'\r'}"
	psi_cpu_some_avg60="${psi_cpu_some_avg60%$'\r'}"

	echo "${i},${utc_ts},${cpu0_freq},${cpu4_freq},${cpu7_freq},${gpu_freq},${kgsl_idle_ms},${battery_temp},${thermal_soc},${psi_cpu_some_avg60}" >>"${sample_file}"

	if [[ "${i}" -lt "${SAMPLES}" ]]; then
		sleep "${INTERVAL_SECONDS}"
	fi
done

# ---------------------------------------------------------------------------
# 9. Unavailable-node diagnostics
# ---------------------------------------------------------------------------
log "Collecting unavailable-node diagnostics"
mkdir -p "${OUTPUT_DIR}/diagnostics"
adb_cmd shell "ls -la /sys/class/ 2>/dev/null" >"${OUTPUT_DIR}/diagnostics/sys_class_ls.txt" 2>/dev/null || echo "UNAVAILABLE: /sys/class" >"${OUTPUT_DIR}/diagnostics/sys_class_ls.txt"
adb_cmd shell "ls -la /sys/devices/system/cpu 2>/dev/null" >"${OUTPUT_DIR}/diagnostics/cpu_dir_ls.txt" 2>/dev/null || echo "UNAVAILABLE: cpu dir" >"${OUTPUT_DIR}/diagnostics/cpu_dir_ls.txt"
adb_cmd shell "ls -la /sys/class/power_supply 2>/dev/null" >"${OUTPUT_DIR}/diagnostics/power_supply_ls.txt" 2>/dev/null || echo "UNAVAILABLE: power_supply" >"${OUTPUT_DIR}/diagnostics/power_supply_ls.txt"
adb_cmd shell "ls -la /sys/class/thermal 2>/dev/null" >"${OUTPUT_DIR}/diagnostics/thermal_ls.txt" 2>/dev/null || echo "UNAVAILABLE: thermal" >"${OUTPUT_DIR}/diagnostics/thermal_ls.txt"
adb_cmd shell "ls -la /sys/block 2>/dev/null" >"${OUTPUT_DIR}/diagnostics/block_ls.txt" 2>/dev/null || echo "UNAVAILABLE: block" >"${OUTPUT_DIR}/diagnostics/block_ls.txt"

# Mark any file that contains UNAVAILABLE for easy review.
find "${OUTPUT_DIR}" -type f -exec sh -c 'grep -q "^UNAVAILABLE:" "$1" && echo "$1" >> "${2}/unavailable_nodes.txt"' _ {} "${OUTPUT_DIR}" \; 2>/dev/null || true

log "Baseline collection complete: ${OUTPUT_DIR}"
