# Avalanche Kernel

Avalanche is an Android kernel project for the **POCO X3 NFC (`surya`)**. It
uses the Linux 4.14.357 OpenELA tree and focuses on predictable performance,
power efficiency, stability, and maintainable changes rather than benchmark
flags or undocumented tuning.

This repository is a fork and continuation of the
[Cilok-LAB POCO X3 NFC kernel](https://github.com/Cilok-LAB/android_kernel_xiaomi_surya).
The Avalanche fork is maintained at
[willtanoe/android_kernel_xiaomi_surya](https://github.com/willtanoe/android_kernel_xiaomi_surya).
Cilok-LAB and all earlier contributors retain credit for the device support and
kernel work inherited by this fork.

## Project Principles

Avalanche follows a conservative engineering policy:

- Prefer measurable behavior and correctness over feature-count marketing.
- Use a consistent `-O2` compiler policy instead of forcing global `-O3`.
- Use the shared ARMv8.2-A baseline required by the configured ARM64 atomics,
  without globally tuning the kernel for only one CPU cluster.
- Avoid blind overclocking, undervolting, durability reductions, and copied
  governor values without device measurements.
- Keep performance, battery, thermal, scheduler, and memory-policy experiments
  separate so their effects can be measured and reverted independently.
- Build and inspect the KernelSU and NoKSU variants independently.
- Describe compile validation as compile validation, not as proof of runtime
  compatibility or battery-life improvement.

The objective is a fast and efficient daily-use kernel. Performance and battery
claims require repeatable physical-device measurements; they are not inferred
from compiler flags or the number of included patches.

## Target

| Item | Value |
| --- | --- |
| Device | POCO X3 NFC |
| Codename | `surya` |
| Platform | Qualcomm Snapdragon 732G (`SDMMAGPIE` in the source) |
| Architecture | ARM64 with ARM compatibility support |
| Kernel | Linux 4.14.357 OpenELA |
| Defconfig | `arch/arm64/configs/surya_defconfig` |
| Toolchain | AOSP Clang 21.0.0, build 13289611 |

Only `surya` is currently declared as a release target. Do not assume that a
build is compatible with `karna` or another device unless that target is
explicitly validated.

## Release Variants

| Variant | Description |
| --- | --- |
| `NoKSU` | KernelSU is disabled and the build fails if KernelSU symbols remain in the linked kernel. |
| `KSU` | Includes the embedded xxKernelSU-derived integration, reported as version 3.2.2 / 34795. |

KernelSU is privileged software, not a performance feature. The current KSU
variant includes its syscall-table implementation for compatibility with this
4.14 tree. Use only a manager and modules that you trust. Choose `NoKSU` when
kernel-level root functionality is not required.

## Included Capabilities

The following items are present in the current source configuration. This list
describes real compiled capabilities; it does not imply a benchmark result.

### Core and Power Management

- Preemptible 250 Hz kernel configuration.
- TEO CPU-idle governor.
- Schedutil as the default CPU-frequency policy, with performance, powersave,
  and userspace governors still available when explicitly requested.
- Android cpuset, schedtune, and Power HAL policy is honored instead of being
  silently replaced by fixed in-kernel masks or permanent screen-on boosts.
- Qualcomm devfreq, bandwidth, memory-latency, and Adreno power-management
  support inherited from the device tree.
- Kernel filesystem synchronization retained before suspend for a clear data
  durability boundary.
- Production thermal emulation disabled so userspace cannot substitute fake
  sensor temperatures.

### Storage and Filesystems

- ext4 and F2FS with Android security-label and ACL support.
- Compressed EROFS images with per-CPU decompression workers.
- exFAT, FAT/VFAT, NTFS, FUSE, OverlayFS, Incremental FS, and `sdcardfs`.
- Filesystem encryption, inline encryption, fs-verity, dm-crypt, and dm-verity
  with forward-error correction.
- UFS and block-layer inline-encryption support.
- ZRAM with LZ4 as the configured default compressor.

### Networking

- In-kernel WireGuard support.
- Westwood, BBR, and BBRplus TCP congestion-control implementations.
- BBRplus and `fq_codel` selected by the current defconfig.
- TCP SYN cookies for listen-queue overload protection.
- Android networking, tunneling, filtering, and tethering dependencies from the
  vendor kernel base.

### Security and Reliability

- Strong stack protector across the kernel, including the KernelSU unity
  object.
- Randomized and hardened SLUB freelists.
- Strict kernel read/write/execute permissions and kernel address randomization.
- Hardened usercopy, seccomp filtering, and SELinux as the primary LSM.
- KernelSU fixes for invalid failure-path object use, package-list open failure,
  high-UID allowlist revocation, partial persisted profiles, and concurrent SU
  log writes.
- NoKSU configuration and symbol checks before packaging.

### Packaging and Reproducibility

- Separate KSU and NoKSU AnyKernel ZIP files.
- Pinned Clang archive, archive checksum, and compiler-binary checksum.
- Pinned AnyKernel packaging commit fetched directly by object ID.
- Source-derived kernel timestamps and ccache support.
- Immutable GitHub Actions revisions and release checksum generation.

## Building

### Dependencies

A Debian or Ubuntu host can install the commonly required packages with:

```bash
sudo apt install build-essential bc bison ccache device-tree-compiler flex \
  git libelf-dev libssl-dev wget xz-utils zip
```

The build script downloads the pinned toolchain when `clang/` is absent. It
also verifies an existing compiler before use. Network access is required for
the first toolchain setup and for fetching the pinned AnyKernel commit.

### Commands

```bash
# KernelSU variant
./build.sh KSU

# Kernel without KernelSU
./build.sh NoKSU
```

Optional parameters are:

```text
./build.sh <KSU|NoKSU> [YYYYMMDDHHMM] [artifact-directory]
```

Useful environment variables:

| Variable | Purpose | Default |
| --- | --- | --- |
| `BUILD_JOBS` | Parallel compiler jobs | Number of host CPUs |
| `CCACHE_DIR` | ccache storage directory | `.ccache` in the source tree |
| `CCACHE_MAXSIZE` | Maximum ccache size | `10G` |

The script recreates `out/` for every build. Finished packages are written to
`artifacts/` unless another artifact directory is supplied.

### Reproducible Inputs

| Input | Pinned identity |
| --- | --- |
| AOSP Clang archive | build 13289611 |
| Clang archive SHA-256 | `0a1fbf7f990122a63a2f8b9d6ddce458bebfb1bbe1c9efe8f1b58a2a3814ae7c` |
| Clang binary SHA-256 | `2dc97e5225642abce70b8b077f7fae70b8006d53d9659008b5eb916814bf2ceb` |
| AnyKernel source | `kylieeXD/AK3-Surya` |
| AnyKernel commit | `b5ce992ec2e2f85eaa3b0724fd6b63d8e4dc1352` |

## Artifacts

Successful builds produce:

```text
Avalanche-KSU-<timestamp>.zip
Avalanche-NoKSU-<timestamp>.zip
```

Each flashable ZIP contains `Image.gz`, `dtb.img`, and `dtbo.img`. The local
script prints a SHA-256 digest after packaging. GitHub releases include a
`SHA256SUMS` file covering both variants.

Verify a downloaded release before flashing:

```bash
sha256sum -c SHA256SUMS
```

## Installation and Recovery

Kernel flashing can cause a boot failure, unavailable hardware, data loss, or a
weaker security boundary. Before flashing:

1. Confirm that the device is POCO X3 NFC (`surya`).
2. Use an unlocked bootloader and a recovery or fastboot path that you already
   know works.
3. Back up the current boot-related partitions and keep the matching restore
   image outside the phone.
4. Verify the release checksum.
5. Select the KSU or NoKSU artifact intentionally.
6. Keep a copy of the previous known-good kernel for recovery.

ROM and Android-version compatibility must be validated per release. A generic
claim such as “Android 11-16” is not a substitute for boot and hardware testing
on each userspace and firmware combination.

## Validation Status

The automated release process currently verifies:

- KSU and NoKSU configuration selection.
- Absence of KernelSU symbols from NoKSU builds.
- Full ARM64 kernel, DTB, and DTBO compilation.
- AnyKernel packaging and ZIP integrity.
- Source, toolchain, packaging commit, and artifact checksums.

A physical `surya` device is not currently attached to the build environment.
Therefore boot, display, touch, camera, audio, modem, Wi-Fi, Bluetooth, charging,
suspend, root-manager operation, thermals, performance, and battery endurance
remain runtime validation items. Releases should be treated as test builds until
those checks are completed on hardware.

## Reporting Problems

Include the following information in a useful report:

- Avalanche release name and source commit.
- KSU or NoKSU variant.
- ROM name, Android version, firmware, and previous kernel.
- Exact reproduction steps and whether the issue also occurs on the previous
  known-good kernel.
- Relevant `dmesg`, ramoops/pstore, logcat, or recovery logs.
- For battery or performance reports: workload, screen brightness, radios,
  thermal state, test duration, and a comparison run under the same conditions.

Reports without controlled comparison data are not used to justify scheduler,
frequency, charging, or memory-management tuning.

## Credits

- [Cilok-LAB/android_kernel_xiaomi_surya](https://github.com/Cilok-LAB/android_kernel_xiaomi_surya)
  for the source repository from which Avalanche was forked.
- Linux, OpenELA, Android, CodeLinaro/Qualcomm, Xiaomi, and POCO X3 NFC kernel
  contributors.
- [backslashxx/KernelSU](https://github.com/backslashxx/KernelSU) and the wider
  KernelSU community for the embedded root framework lineage.
- [kylieeXD/AK3-Surya](https://github.com/kylieeXD/AK3-Surya) for the AnyKernel
  packaging base.
- [Impqxr/aosp_clang_ci](https://github.com/Impqxr/aosp_clang_ci) for the pinned
  AOSP Clang distribution.

## License

The Linux kernel source is distributed under GPL-2.0-only unless an individual
file states otherwise. See [`COPYING`](COPYING) for the complete license text.
