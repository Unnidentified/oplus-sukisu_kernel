# oplus-sukisu_kernel

[![Build and Release OnePlus Kernels](https://github.com/Unnidentified/oplus-sukisu_kernel/actions/workflows/build-kernel-release.yml/badge.svg)](https://github.com/Unnidentified/oplus-sukisu_kernel/actions/workflows/build-kernel-release.yml)
[![CI Checks](https://github.com/Unnidentified/oplus-sukisu_kernel/actions/workflows/ci-checks.yml/badge.svg)](https://github.com/Unnidentified/oplus-sukisu_kernel/actions/workflows/ci-checks.yml)

OnePlus GKI kernels built in CI with [SukiSU-Ultra](https://github.com/SukiSU-Ultra/SukiSU-Ultra) (SUSFS integrated) instead of KernelSU-Next. Fork of [sakfi/OP_KSUN_FS](https://github.com/sakfi/OP_KSUN_FS), kept in sync with upstream.

No local toolchain needed: pick your device in GitHub Actions, and the kernel is compiled, patched and packaged as a flashable AnyKernel3 zip.

---

### Table of Contents

- [Building the kernel](#building-the-kernel)
- [What's inside](#whats-inside)
- [Supported devices](#supported-devices)
- [Flashing](#flashing)
- [Notes](#notes)
- [Credits](#credits)

---

## Building the kernel

1. Open the [Actions tab](https://github.com/Unnidentified/oplus-sukisu_kernel/actions) and run the **Build Kernel** workflow.
2. Pick your device. For a OnePlus 15: `op_model: OP15`, `android_version_filter: A16`, `kernel_version_filter: android16-6.12`.
3. Leave the root options at their defaults unless you know what you are doing:

| Input | Default | Meaning |
|---|---|---|
| `ksu_options` | `[{"type":"ksun","hash":"builtin"}]` | SukiSU-Ultra `builtin` branch (the only line with in-kernel `KSU_SUSFS`; `main`/`dev` ship SUSFS as a userspace extension shim only) |
| `ksu_mode` | `builtin` | `builtin` compiles SukiSU into the kernel (recommended, full SUSFS support); `lkm` downloads a prebuilt `kernelsu.ko` and injects it into the ramdisk at flash time |

A device config can override the root branch per device with a `ksu_hash` field (default `builtin`, SukiSU-Ultra 34680 with in-kernel SUSFS; note that `main`/`dev` do NOT work — susfs's KSU-side patch rejects on their tree, so they were tried and reverted). Both OnePlus 15 profiles now enable `bore` (BORE scheduler, `CONFIG_SCHED_BORE=y`, runtime toggle `/proc/sys/kernel/sched_bore`), `adios` (ADIOS I/O scheduler, default iosched), `autofdo` and `damon`; `OP15-COS17` additionally enables `mlgo` (ML-guided register allocation via `-mllvm -regalloc-enable-advisor=release`; the r547379 prebuilt is `+mlgo`-enabled). IPv6 NAT comes with `ip_set` including the `/proc/config.gz` hiding patch, and WireGuard is already in the GKI defconfig.

4. When the run finishes, grab the `{MODEL}_*.zip` from [Releases](https://github.com/Unnidentified/oplus-sukisu_kernel/releases) or the run's artifacts.

Zip names follow `{MODEL}_{KERNEL_FULL_VER}-SuSFS_{SUSVER}.zip` (LKM builds add `_LKM`), e.g. `OP15-COS17_android16-6.12.69-SuSFS_v2.3.0.zip` for a builtin SukiSU-Ultra + SUSFS build.

---

## What's inside

| Area | Feature | Notes |
|---|---|---|
| Root | **SukiSU-Ultra** (`builtin` branch) | Fork of KernelSU-Next with SUSFS hooks already integrated — no extra KSU patching needed. Manager APK from [SukiSU-Ultra releases](https://github.com/SukiSU-Ultra/SukiSU-Ultra/releases). The build carries small compat patches (6.7+ `struct lsm_id` LSM registration, SUSFS priority-filter guards) under `.github/actions/build-kernel/patches/` |
| Stealth | **SUSFS** | Magic mount, `SUS_PATH` / `SUS_MOUNT` / `SUS_KSTAT` / `SUS_MAP`, uname & cmdline spoofing, open redirect. Branch auto-synced from [susfs4ksu](https://gitlab.com/simonpunk/susfs4ksu) |
| Gaming | **NTSync** | NT synchronization primitives for Windows emulators (Winlator, Box64) |
| Network | **BBR**, **WireGuard**, TTL / IP Set | Congestion control, in-kernel VPN, packet tools |
| Containers | **Droidspaces** | SYSVIPC support for portable Linux containers |
| Misc | HMBIRD SCX, LTO, TMPFS xattr, Unicode bypass fix | Toggled per device in `configs/` |
| Compiler | **AutoFDO** | Profile-guided optimisation using Google's `kernel.afdo` for `android16-6.12`. On for both OnePlus 15 profiles |
| Memory | **DAMON** | Data access monitor, as shipped by Android 17's GKI. Built in but dormant until a policy starts it |
| Scheduler | **BORE** | Burst-oriented scheduler on top of EEVDF. `CONFIG_SCHED_BORE=y`, runtime toggle `/proc/sys/kernel/sched_bore` |
| I/O | **ADIOS** | Adaptive deadline I/O scheduler, set as the default iosched |

The OnePlus 15 profile (`configs/a16/OP15.json`) is `android16` / `6.12` (`canoe`) on OnePlus's own `sm8850_b_16.0.0_oneplus_15` tree — the one that matches OxygenOS 16 / `6.12.23-android16-5`. SUSFS on, BBG off (this fork keeps Baseband Guard disabled on the OP15 so the EFS/bootloader mod keeps working). HMBIRD is off because no `fengchi_OP15_A16` patch exists upstream, so the build skipped it anyway.

`OP15-COS17` is the same device on AOSP GKI `6.12.69` for ColorOS 17. The two profiles differ in kernel source, not in features: both now carry BORE, ADIOS, AutoFDO and DAMON.

### BORE on 6.12.23

`bore_6.12.patch` is written against 6.12.44+, where `pick_eevdf()` tests a local `protect` flag. OnePlus's 6.12.23 tree still has the older `sched_feat(RUN_TO_PARITY) && curr && protect_slice(curr)` form, so that one hunk rejects. The build detects `kernel/sched/fair.c.rej`, drops it, and applies `patches/bore-fix-pick-eevdf-6.12.23.patch` — the same guard against the older form. `OP15-COS17` takes the clean path and never touches the fixup.

### AutoFDO

`"autofdo": true` builds with Google's kernel AutoFDO profile for `android16-6.12`. Google's published numbers for this profile are 2-3% boot, 3-4% cold app launch, 8-9% binder-rpc, 12-25% binder-addints, 12-18% hwbinder and 6% on `syscall_mmap`.

`gki_defconfig` already sets `CONFIG_AUTOFDO_CLANG=y`, but on its own that buys nothing: without `CLANG_AUTOFDO_PROFILE`, `scripts/Makefile.autofdo` only adds `-fdebug-info-for-profiling` and `-gmlt` — debug info nobody consumes, and no profile-guided optimisation. Every build before this one was paying that cost for zero benefit. The profile is the missing half.

It is not in the pinned kernel tree: `gki/aarch64/afdo/kernel.afdo` exists on the `android16-6.12` branch but not at the `242e1a07` commit the manifest pins. The build downloads it from a pinned commit and verifies its sha256; a failed download or a hash mismatch aborts the build rather than quietly producing a kernel without AutoFDO. It also re-checks that `CONFIG_AUTOFDO_CLANG=y` survived `olddefconfig`, so a base-tree change fails loudly instead of silently dropping the profile.

OnePlus's own `sm8850_b_16.0.0_oneplus_15` tree also ships `CONFIG_AUTOFDO_CLANG=y`, so the same profile applies to `OP15` on 6.12.23. The profile was generated on AOSP GKI, so function names that only exist in OnePlus's tree simply get no profile data — that costs the benefit on those functions, not correctness.

The profile was generated on a Pixel 10 with Google's app set, so it is not tuned to ColorOS or OxygenOS workloads. Kernel hot paths overlap heavily, but treat the numbers above as an upper bound. Set `"autofdo": false` to revert.

### DAMON

`"damon": true` builds `CONFIG_DAMON` plus `DAMON_RECLAIM` and `DAMON_LRU_SORT`, matching what Android 17's GKI ships. Nothing starts at boot: `kdamond` only runs when a userspace policy enables it, so the cost when unused is code size only.

### LTO

Eight of the nine `android16-6.12` profiles build with `"lto": "none"`; every older profile uses `thin`. The reason for the 6.12 exception is not recorded — the change landed as a web-UI edit on 2026-08-07 with the default commit message, in the same hour as two other trial-and-error edits. `OP-PAD-LITE` is the one 6.12 profile still on `thin`, so LTO is not fundamentally broken there.

To test it without editing a config, dispatch the workflow with `lto_override` set to `thin` or `full`. The override applies to that run only, warns in the log, and is recorded as `features.lto` in `build-info.json` so two builds of the same version stay distinguishable.

### Not implemented yet

Things a current Android kernel normally has that this one does not. Listed so the gap is visible rather than implied.

| Item | Why it matters | Blocker |
|---|---|---|
| **LTO thin on 6.12** | Typically 2-5% on kernel workloads | Unknown — needs one test build via `lto_override` |
| **`CONFIG_RANDOM_KMALLOC_CACHES`** | Randomises which kmalloc cache an allocation lands in, so a heap overflow has to guess. Upstream is renaming this to `KMALLOC_PARTITION_CACHES` | None; ~1% cost, needs measuring |
| **`CONFIG_LIST_HARDENED`** | Catches linked-list corruption at the point it happens instead of at the crash | None; near-zero cost |
| **`CONFIG_INIT_ON_FREE_DEFAULT_ON`** | Zeroes freed heap memory, kills use-after-free info leaks | Perf cost is real; `INIT_ON_ALLOC_DEFAULT_ON` is already on |
| **`CONFIG_ARM64_MTE`** | Memory tagging; GrapheneOS enables it for the kernel | Needs hardware support and a userspace that tolerates the tag checks |
| **16 KB page size** | Required for new Android 16+ devices | Not a toggle — changing it breaks every existing binary on the device |

Already on and easy to assume otherwise: `CONFIG_RANDOMIZE_KSTACK_OFFSET` defaults to `y` and both kernel trees select `HAVE_ARCH_RANDOMIZE_KSTACK_OFFSET`, so it is active without appearing in `gki_defconfig`.

### The `opt` patch set is unverified

`"opt": true` (currently only `OP15`) applies about thirty patches from `WildKernels/kernel_patches`, cloned from a moving branch at build time. None of them are in this repo, none are pinned, and nothing checks that they still apply — a break there surfaces as a failed build forty minutes in, not as a CI failure. `scripts/check-patches.sh` covers SUSFS, BORE and ADIOS only.

That set is the next thing worth auditing: it is the largest unverified surface in the build, and it includes patches that change global behaviour (`force_tcp_nodelay`, `add_timeout_wakelocks_globally`, `disable_cache_hot_buddy`, the two `silence_*_logspam` ones) alongside genuinely useful ones (`optimise_memcmp`, `clear_page_16bytes_align`, `int_sqrt`).

---

## Supported devices

Per-device configs live in [`configs/`](configs), kernel source manifests in [`manifests/`](manifests):

| OxygenOS | Kernel | Devices |
|---|---|---|
| OOS 14 | 5.10 / 5.15 / 6.1 | OnePlus 10 Pro, 10T, 11, 11R, 12, 12R, Pad, Ace series |
| OOS 15 | 5.15 / 6.1 / 6.6 | OnePlus 12, 12R, 13, 13S, Open, Ace 3/5, Nord 4/5 |
| OOS 16 | 6.1 / 6.6 / 6.12 | OnePlus 13, 13S, 15, 15R, 15T, Ace 6, Turbo 6, Pad 2/3/4 |

Everything is built from [OnePlus's official kernel sources](https://github.com/OnePlusOSS/), so the zips target stock ROMs. Don't flash a zip across a major OTA (e.g. A15 to A16) without checking — the KMI has to match.

### Known-unbuildable profiles

These configs are present but cannot currently be built: no commit on the matching `susfs4ksu` branch has a `50_add_susfs` patch that applies to their kernel base. The CI patch dry-run reports them as warnings rather than failures.

| Profile | KMI | Failing files |
|---|---|---|
| `OP-ACE-3-PRO` | android14-6.1 | `fs/namespace.c`, `fs/proc/base.c` |
| `OP-ACE-5-PRO-6.6.30` | android15-6.6 | `fs/namespace.c`, `fs/proc/base.c` |
| `OP11` (A16 / `oneplus_11_w.xml`) | android13-5.15 | `fs/namespace.c`, `fs/proc/task_mmu.c` |

The A14 and A15 `OP11` profiles are pinned to `8c4fa71` and do build. Fixing the rest needs either a SUSFS patch rebased onto those bases or version-specific fixups in the build — neither exists today.

For ColorOS 17 (Android 17) on the OnePlus 15, build with `op_model: OP15-COS17` (keep `android_version_filter: A16`, `kernel_version_filter: android16-6.12`). That profile (`configs/a16/OP15-COS17.json`) compiles the AOSP GKI `android16-6.12.69` common with OnePlus's sm8850 modules/devicetree, giving KMI `android16-6` — the same generation as ColorOS 17's stock `6.12.x-android16-6` kernel — so the zip boots on ColorOS 17. The `OP15` profile stays on OnePlus's 16.0.0 common (`6.12.23-android16-5`) and remains the one for ColorOS/OxygenOS 16.

The choice between them is about which OS you are on, not about features: both now carry BORE, ADIOS, AutoFDO and DAMON. If you are on OxygenOS 16 with a `6.12.23-android16-5` kernel, `OP15` is your profile.

---

## Flashing

1. Unlock the bootloader and back up your stock `boot` / `init_boot` image.
2. Flash the zip with [Kernel Flasher](https://github.com/fatalcoder524/KernelFlasher), [Horizon Kernel Flasher](https://github.com/libxzr/HorizonKernelFlasher), or a custom recovery. In `lkm` mode the installer patches the ramdisk on-device via `ksud boot-patch`.
3. Reboot, then install the SukiSU-Ultra manager APK.

### Verifying a build

Each release lists a `sha256` next to every zip. Check it before flashing:

```sh
sha256sum OP15-COS17_android16-6.12.69-SuSFS_v2.3.0.zip
```

Every zip also ships a `build-info.json` recording the exact kernel source commit, the SUSFS and SukiSU-Ultra revisions, the toolchain, the image/zip checksums, and which optimisation features were enabled (`features.lto`, `features.autofdo` with the profile hash, `features.damon`, `features.bore`, `features.adios`, `features.mlgo`) — so you can tell two builds of the same version apart.

---

## Notes

> [!WARNING]
> Flashing a custom kernel can brick your device or wipe data. Match the zip to your exact model and OxygenOS build, and keep a stock boot image around for recovery. The maintainers are not responsible for any damage.

On non-OnePlus devices, pick the config whose `androidXX-YY.ZZ` KMI matches yours (see the [KernelSU KMI guide](https://kernelsu.org/guide/installation.html#kmi)) and disable dm-verity first.

---

## Credits

| Project | Author | Link |
|---|---|---|
| Upstream pipeline (OP_KSUN_FS) | sakfi | [github.com/sakfi/OP_KSUN_FS](https://github.com/sakfi/OP_KSUN_FS) |
| Original OnePlus kernel CI | fatalcoder524 | [github.com/fatalcoder524](https://github.com/fatalcoder524) |
| SukiSU-Ultra (KernelSU-Next fork) | SukiSU-Ultra | [github.com/SukiSU-Ultra/SukiSU-Ultra](https://github.com/SukiSU-Ultra/SukiSU-Ultra) |
| KernelSU-Next | rifsxd | [github.com/KernelSU-Next/KernelSU-Next](https://github.com/KernelSU-Next/KernelSU-Next) |
| SUSFS | simonpunk | [gitlab.com/simonpunk/susfs4ksu](https://gitlab.com/simonpunk/susfs4ksu) |
| SUSFS module | sidex15 | [github.com/sidex15/ksu_module_susfs](https://github.com/sidex15/ksu_module_susfs) |
| AnyKernel3 | osm0sis | [github.com/osm0sis/AnyKernel3](https://github.com/osm0sis/AnyKernel3) |
