<p align="center">
  <img src="docs/assets/avalanche-banner.png" alt="Avalanche Kernel banner" width="100%">
</p>

# Avalanche Kernel

Avalanche is a custom Android kernel for the **Xiaomi POCO X3 NFC (`surya`)**,
built on the OpenELA-maintained Linux 4.14.357 kernel. Avalanche originated from
the [Cilok-LAB POCO X3 NFC kernel](https://github.com/Cilok-LAB/android_kernel_xiaomi_surya)
and is now maintained independently.

## Philosophy

Avalanche prioritizes stability, reproducibility, and upstream correctness over
benchmark-oriented tuning.

The project intentionally avoids aggressive compiler flags, artificial CPU
boosting, overclocking, and other modifications that cannot be justified through
measurable improvements or long-term maintainability.

## Device

| Item | Value |
| --- | --- |
| Device | POCO X3 NFC |
| Codename | `surya` |
| Platform | Qualcomm Snapdragon 732G |
| Kernel | Linux 4.14.357 OpenELA |
| Compiler | AOSP Clang 21 |

Only `surya` is currently supported.

## Features

### Performance and Power

- Schedutil as the default CPU frequency governor.
- Qualcomm WALT load tracking for task placement and frequency demand.
- TEO CPU idle governor.
- Preemptible 250 Hz kernel.
- Android Power HAL, cpuset, schedtune, thermal, and IRQ policy support.
- Qualcomm Adreno, devfreq, bandwidth, and memory-latency drivers.
- Device-tree controlled GPU PM-QoS latency and writable GPU idle timeout.
- Consistent `-O2` compiler optimization and ARMv8.2-A baseline.
- No forced screen-on boost, custom input boost, overclock, or undervolt.

### Memory and Storage

- ZRAM with LZ4 compression.
- CFQ as the default I/O scheduler.
- ext4, F2FS, EROFS, exFAT, NTFS, FUSE, OverlayFS, and Incremental FS.
- UFS and block-layer inline encryption.
- Filesystem encryption, fs-verity, dm-crypt, and dm-verity.

### Networking

- WireGuard support.
- CUBIC as the default TCP congestion controller.
- BBR and Westwood available as optional congestion controllers.
- `fq_codel` as the default queueing discipline.
- Android tethering, filtering, tunneling, and VPN dependencies.

### Security and Reliability

- Strong kernel stack protector.
- Randomized and hardened SLUB freelists.
- Kernel address randomization and strict memory permissions.
- Hardened usercopy, seccomp, and SELinux.
- Kernel diagnostics, debugging safeguards, and stack-frame build warnings.
- Reproducible toolchain and AnyKernel checksums.

## Variants

| Variant | Description |
| --- | --- |
| `KSU` | Includes the embedded KernelSU integration. |
| `NoKSU` | KernelSU is disabled and excluded from the linked kernel. |

Use `NoKSU` if kernel-level root access is not needed.

## Installation

Choose the KSU or NoKSU ZIP, then flash it using a compatible custom recovery.
Back up the current boot image and keep a known-good kernel before flashing.

## Credits

- [Cilok-LAB/android_kernel_xiaomi_surya](https://github.com/Cilok-LAB/android_kernel_xiaomi_surya)
  for the original Surya kernel source from which Avalanche originated.
- Linux, OpenELA, Android, CodeLinaro/Qualcomm, Xiaomi, and POCO kernel
  contributors.
- [backslashxx/KernelSU](https://github.com/backslashxx/KernelSU) and the
  KernelSU community.
- [Cilok-LAB/AK3-Surya](https://github.com/Cilok-LAB/AK3-Surya) for the AnyKernel
  packaging base.
- [Impqxr/aosp_clang_ci](https://github.com/Impqxr/aosp_clang_ci) for the AOSP
  Clang distribution.

## License

This kernel is distributed under GPL-2.0-only unless an individual file states
otherwise. See [`COPYING`](COPYING).
