# Avalanche Device Testing Guide

This document describes how to collect reproducible, read-only device
baselines for the Avalanche kernel on Xiaomi POCO X3 NFC (`surya`). The
included collector is intentionally passive: it never requests root, never
writes to sysfs or properties, never changes tracing state, and never
creates files on the device.

## Quick start

```bash
# Collect a baseline from the first attached ADB device.
tools/avalanche/collect-device-baseline.sh

# Collect from a specific device with a custom output directory.
tools/avalanche/collect-device-baseline.sh \
    -s <adb-serial> \
    -o ./my-baseline-run \
    -n 60
```

The output directory contains:

```text
identity/          # getprop, kernel version, cmdline, device-tree summary
devicetree/        # active /proc/device-tree snapshot
android_policy/    # SELinux mode, device-idle dumpsys
cpufreq/           # per-policy and per-CPU frequency state
gpu/               # KGSL clocks, governor, idle timer
thermal/           # thermal zones, cooling devices
power/             # battery capacity, current, voltage, temperature
memory/            # PSI, meminfo, zram, swaps
storage/           # df, mounts, diskstats
errors/            # dmesg err/warn, logcat crash/events, wakeup sources
samples/           # bounded periodic CSV of frequencies/thermal/PSI
diagnostics/       # directory listings for unavailable-node debugging
collector.log      # human-readable collection log
unavailable_nodes.txt  # list of nodes that could not be read
```

## What the collector does

`tools/avalanche/collect-device-baseline.sh` uses `adb shell` with purely
read-only commands:

* `cat` on `/proc`, `/sys`, and `/sys/fs/selinux` nodes.
* `getprop`, `getenforce`, `dumpsys`, `dmesg`, `logcat`.
* `ls`, `find`, `df`, `free`, `mount`, `awk` for presentation only.
* A bounded CSV sample loop that reads public frequency, thermal, and PSI
  nodes at a fixed interval.

The script does **not**:

* Request root (`adb shell` only, no `su`).
* Write any sysfs entry, property, or trace marker.
* Enable or disable tracing, ftrace, or perfetto.
* Install, push, or execute any file on the device.
* Collect IMEI, phone number, MAC address, or account identifiers.

## Privacy considerations

The collector captures system state that is normally visible to any app with
`DUMP` or `READ_PHONE_STATE` privileges and to any user running `adb shell`:

* Kernel version, device model, SoC revision.
* CPU/GPU frequency policy and current values.
* Thermal zone temperatures and battery voltage/current/temperature.
* Memory pressure, ZRAM, and storage usage.
* Kernel warnings and crash logs from the current boot.

It intentionally **does not** collect:

* IMSI, IMEI, serial number, Wi-Fi MAC, Bluetooth MAC.
* Location, contacts, messages, photos, or app-specific data.
* Network traffic or credentials.
* Advertising IDs.

Before sharing a baseline archive, review `identity/getprop.txt` and
`errors/logcat_*.txt` for any values you consider sensitive. The collector
writes everything to the host; nothing is uploaded automatically.

## Controlled randomized A/B protocol

A single benchmark run is not enough to conclude that one kernel is better
than another. Use the following protocol instead of chasing one-off scores.

### 1. Stabilize the device

* Charge to a fixed range (for example 40 % to 60 %) and keep the charger
  disconnected during the test.
* Use the same ambient temperature and avoid direct sunlight or fans aimed
  at the device.
* Close background apps and restart the device under test.
* Let the device idle for at least 10 minutes after boot so thermal
  throttling and app compilation settle.

### 2. Choose one repeatable workload

Examples:

* A fixed game scene with locked FPS and graphics settings.
* A local video loop.
* A build or compression task running in Termux.

Do **not** mix workloads. The comparison is only valid if the workload is
identical across kernels.

### 3. Randomize the order

For each kernel build, flip a coin to decide whether it runs first or
second. This prevents time-of-day, thermal history, or background update
bias from always favoring the same build.

### 4. Collect distributions, not averages

Run the workload for at least 20 to 30 minutes after warm-up. Record:

* FPS frametimes (1 % low, 95th percentile, average).
* CPU/GPU frequency traces via the CSV sample file.
* Thermal zone temperatures and battery temperature.
* Battery drop over the run.
* Number of thermal throttling events (`dmesg` warnings).
* PSI metrics (`some` and `full` averages for CPU, memory, and IO).

Report the full distribution (histogram or percentiles), not just the mean.

### 5. Repeat

Run the same workload at least three times per kernel build on different
days. If the confidence intervals overlap, the difference is not proven.

### 6. Change one variable at a time

Do not combine scheduler changes, GPU governor changes, thermal changes,
and memory changes into one experiment. The protocol above isolates one
kernel change per comparison so the cause of any shift can be identified.

## Interpreting the baseline

Key files to compare between two kernel builds:

| File | What to look for |
|------|------------------|
| `identity/proc_version.txt` | Confirm kernel release string and dirty/clean state. |
| `cpufreq/policy_state.txt` | Governor, min/max frequencies, current frequency under load. |
| `gpu/kgsl_*.txt` | GPU clock, governor, and idle timer. |
| `thermal/thermal_zones.txt` | Peak temperatures and which zone throttles first. |
| `power/battery_temp.txt` | Battery heating during the run. |
| `memory/psi_*.txt` | Pressure stall averages; higher values mean contention. |
| `errors/dmesg_err_warn.txt` | New warnings, panics, or driver errors. |
| `samples/periodic.csv` | Time-series of frequencies, thermal, and PSI. |

## Example: compare two builds

```bash
# Build A
BUILD_JOBS=16 ./build.sh KSU
mv artifacts/Avalanche-KSU-*.zip ./build-a.zip

# Build B (after code change)
BUILD_JOBS=16 ./build.sh KSU
mv artifacts/Avalanche-KSU-*.zip ./build-b.zip

# Flash build A, reboot, stabilize, collect baseline.
tools/avalanche/collect-device-baseline.sh -s <serial> -o baseline-a

# Flash build B, reboot, stabilize, collect baseline.
tools/avalanche/collect-device-baseline.sh -s <serial> -o baseline-b

# Compare manifests and samples.
diff baseline-a/identity/proc_version.txt baseline-b/identity/proc_version.txt
diff baseline-a/samples/periodic.csv baseline-b/samples/periodic.csv
```

## Reporting results

When sharing results with the Avalanche project, include:

* ROM name, Android version, and firmware build.
* Kernel release strings from both builds.
* Exact workload and test duration.
* Ambient temperature range and battery start/end percentages.
* The two baseline output directories (or a summary CSV).
* A concise statement of whether the difference is reproducible across
  multiple runs.

Do not claim battery, thermal, or performance improvements from a single
short run. The collector is designed to make reproducible comparisons
possible, not to produce marketing numbers.
