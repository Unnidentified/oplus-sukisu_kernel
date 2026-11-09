# oplus-sukisu_kernel

[![Build and Release OnePlus Kernels](https://github.com/Unnidentified/oplus-sukisu_kernel/actions/workflows/build-kernel-release.yml/badge.svg)](https://github.com/Unnidentified/oplus-sukisu_kernel/actions/workflows/build-kernel-release.yml)
[![CI Checks](https://github.com/Unnidentified/oplus-sukisu_kernel/actions/workflows/ci-checks.yml/badge.svg)](https://github.com/Unnidentified/oplus-sukisu_kernel/actions/workflows/ci-checks.yml)

OnePlus GKI kernels built in CI with [SukiSU-Ultra](https://github.com/SukiSU-Ultra/SukiSU-Ultra) (SUSFS integrated) instead of KernelSU-Next. Fork of [sakfi/OP_KSUN_FS](https://github.com/sakfi/OP_KSUN_FS), kept in sync with upstream.

No local toolchain needed: pick your device in GitHub Actions, and the kernel is compiled, patched and packaged as a flashable AnyKernel3 zip.

---

### Table of Contents

- [Building the kernel](#building-the-kernel)
- [What's inside](#whats-inside)
- [Kernel tuning](#kernel-tuning)
- [Supported devices](#supported-devices)
- [Flashing](#flashing)
- [Not implemented yet](#not-implemented-yet)
- [Roadmap](ROADMAP.md)
- [Notes](#notes)
- [Credits](#credits)

---

## Building the kernel

1. Open the [Actions tab](https://github.com/Unnidentified/oplus-sukisu_kernel/actions) and run the **Build Kernel** workflow.
2. Pick your device. For a OnePlus 15 on OxygenOS 16: `op_model: OP15`, `android_version_filter: A16`, `kernel_version_filter: android16-6.12`.
3. Leave the rest at their defaults unless you know what you are doing:

| Input | Default | Meaning |
|---|---|---|
| `ksu_options` | `[{"type":"ksun","hash":"builtin"}]` | SukiSU-Ultra `builtin` branch - the only line with in-kernel `KSU_SUSFS`. `main`/`dev` ship SUSFS as a userspace extension shim only |
| `ksu_mode` | `builtin` | `builtin` compiles SukiSU into the kernel (recommended, full SUSFS support); `lkm` downloads a prebuilt `kernelsu.ko` and injects it into the ramdisk at flash time |
| `optimize_level` | `O2` | `-O2` or `-O3`. See [O2 vs O3](#o2-vs-o3) |
| `lto_override` | `config` | Forces an LTO mode for one run. See [LTO](#lto) |

A device config can override the root branch per device with a `ksu_hash` field. The default is `builtin` (SukiSU-Ultra 34680 with in-kernel SUSFS); `main`/`dev` do **not** work - susfs's KSU-side patch rejects on their tree, so they were tried and reverted.

4. When the run finishes, grab the `{MODEL}_*.zip` from [Releases](https://github.com/Unnidentified/oplus-sukisu_kernel/releases) or the run's artifacts.

Zip names follow `{MODEL}_{KERNEL_FULL_VER}-SuSFS_{SUSVER}-r{REV}.zip` (LKM builds add `_LKM`), e.g. `OP15-COS17_android16-6.12.69-SuSFS_v2.3.0-r3.zip`.

The `-r{REV}` is the release revision. It is resolved once in `set-op-model`, before any build starts, and passed down to every build job. The SUSFS version comes from `susfs.h` at the resolved ref, and the revision is one past the highest existing `{version}-rN` tag. Every tag is listed and the maximum is taken, because the tags endpoint does not guarantee a sort order. So the artifact name and the release asset name are the same string, and `trigger-release` cannot pick a different tag than the one the zips were built under. A `custom_release_tag` overrides the derivation. If the SUSFS version cannot be resolved the suffix is dropped and the run warns.

---

## What's inside

| Area | Feature | Notes |
|---|---|---|
| Root | **SukiSU-Ultra** (`builtin`) | Fork of KernelSU-Next with SUSFS hooks already integrated. Manager APK from [SukiSU-Ultra releases](https://github.com/SukiSU-Ultra/SukiSU-Ultra/releases). Small compat patches (6.7+ `struct lsm_id` LSM registration, SUSFS priority-filter guards) live in `.github/actions/build-kernel/patches/` |
| Stealth | **SUSFS** | Magic mount, `SUS_PATH` / `SUS_MOUNT` / `SUS_KSTAT` / `SUS_MAP`, uname & cmdline spoofing, open redirect. Branch auto-synced from [susfs4ksu](https://gitlab.com/simonpunk/susfs4ksu) |
| Scheduler | **BORE** | Burst-oriented scheduler on top of EEVDF. `CONFIG_SCHED_BORE=y`, runtime toggle `/proc/sys/kernel/sched_bore` |
| I/O | **ADIOS** | Adaptive deadline I/O scheduler, set as the default iosched |
| Compiler | **AutoFDO** | Profile-guided optimisation using Google's `kernel.afdo` for `android16-6.12` |
| Memory | **DAMON** | Data access monitor, as shipped by Android 17's GKI. Built in but dormant until a policy starts it |
| Gaming | **NTSync** | NT synchronization primitives for Windows emulators (Winlator, Box64) |
| Network | **BBR**, **BBR3**, **WireGuard**, TTL / IP Set | Congestion control, in-kernel VPN, packet tools |
| Containers | **Droidspaces** | SYSVIPC support for portable Linux containers |
| Misc | HMBIRD SCX, TMPFS xattr, Unicode bypass fix | Toggled per device in `configs/` |
| Hardening | **LIST_HARDENED**, **RANDOM_KMALLOC_CACHES** | Baseline, on for every 6.6+ profile. See [Baseline hardening](#baseline-hardening) |
| Debug | **KASAN off**, **KFENCE on** | `gki_defconfig` ships KASAN on; the build turns it off. See [KASAN](#kasan) |

---

## Kernel tuning

Everything below is per-device, set in `configs/<os>/<MODEL>.json`. The schema is in [`configs/schema.json`](configs/schema.json) and `scripts/validate-configs.py` checks every profile against it.

### BORE

`"bore": true` applies `bore_6.12.patch` and sets `CONFIG_SCHED_BORE=y`. Runtime toggle: `/proc/sys/kernel/sched_bore`.

The patch is written against 6.12.44+. Two of its hunks do not match OnePlus's 6.12.23 tree: `__pick_eevdf()` still tests `sched_feat(RUN_TO_PARITY) && curr && protect_slice(curr)` instead of a local `protect` flag, and `update_curr()` calls `update_min_vruntime()` before the burst-accounting hunk's trailing context. Both reject.

The build applies the patch with `-F0`, so a hunk either matches its context exactly or rejects. It then checks that `kernel/sched/fair.c.rej` holds exactly those two hunks, applies `patches/bore-fix-6.12.23.patch` against the 6.12.23 shapes, and verifies the result with grep before continuing. `OP15-COS17` takes the clean path and never touches the fixup.

Fuzz is deliberately off. With `-F3` the `__pick_eevdf()` hunk does not reject on 6.12.23, it lands inside the heap-search loop instead, which changes the pick logic rather than guarding it.

### ADIOS

`"adios": true` applies `adios_ioscheduler_6.12.patch` and sets `CONFIG_MQ_IOSCHED_ADIOS=y` plus `CONFIG_MQ_IOSCHED_DEFAULT_ADIOS=y`. Applies cleanly to both 6.12.23 and 6.12.69.

### AutoFDO

`"autofdo": true` builds with Google's kernel AutoFDO profile for `android16-6.12`. Google's published numbers for this profile are 2-3% boot, 3-4% cold app launch, 8-9% binder-rpc, 12-25% binder-addints, 12-18% hwbinder and 6% on `syscall_mmap`.

`gki_defconfig` already sets `CONFIG_AUTOFDO_CLANG=y`, but on its own that buys nothing: without `CLANG_AUTOFDO_PROFILE`, `scripts/Makefile.autofdo` only adds `-fdebug-info-for-profiling` and `-gmlt` - debug info nobody consumes, and no profile-guided optimisation. Every build before this one paid that cost for zero benefit. The profile is the missing half.

It is not in the pinned kernel tree: `gki/aarch64/afdo/kernel.afdo` exists on the `android16-6.12` branch but not at the `242e1a07` commit the manifest pins. The build downloads it from a pinned commit and verifies its sha256; a failed download or a hash mismatch aborts the build rather than quietly producing a kernel without AutoFDO.

OnePlus's own `sm8850_b_16.0.0_oneplus_15` tree also ships `CONFIG_AUTOFDO_CLANG=y`, so the same profile applies to `OP15` on 6.12.23. The profile was generated on AOSP GKI, so functions that only exist in OnePlus's tree get no profile data - that costs the benefit on those functions, not correctness.

The profile was generated on a Pixel 10 with Google's app set, so it is not tuned to ColorOS or OxygenOS workloads. Treat the numbers above as an upper bound. Set `"autofdo": false` to revert.

### DAMON

`"damon": true` builds `CONFIG_DAMON` plus `DAMON_RECLAIM` and `DAMON_LRU_SORT`, matching what Android 17's GKI ships. Nothing starts at boot: `kdamond` only runs when a userspace policy enables it, so the cost when unused is code size only.

### LTO

**`"lto": "none"` on 6.12 is deliberate and correct.** Google's own Kleaf documentation says:

> **WARNING**: LTO is disabled by default on GKI (`gki_defconfig`) on android14-6.1 and above. This should only be modified when the trade-offs are fully understood.
>
> Building with link-time optimization (LTO) may take a very long time that brings little benefit during development.

`gki_defconfig` contains no LTO line at all, so the Kconfig choice default (`LTO_NONE`) applies. The 151 profiles in this repo that use `thin` are the ones deviating from GKI, not the 8 that use `none`.

To test it anyway, dispatch the workflow with `lto_override` set to `thin` or `full`. The override applies to that run only, warns in the log, and is recorded as `features.lto` in `build-info.json`.

Note that 6.12 spells the "no LTO" choice member `LTO_NONE`, not `LTO_CLANG_NONE`. The build used the wrong name until recently; it only worked because `LTO_NONE` happens to be the choice default.

### Optimisation patches (`opt`)

`"opt": true` applies a **reviewed allowlist** of ten patches from [WildKernels/kernel_patches](https://github.com/WildKernels/kernel_patches):

```
mem_opt_prefetch                 prefetch in arch/arm64/lib/copy_template.S
avoid_extra_s2idle_wake_attempts only call s2idle_wake() on the first abort
minimise_wakeup_time             shorter alarmtimer wakeup window
adjust_cpu_scan_order            start idle-CPU scan at target+1
reduce_cache_pressure            vfs_cache_pressure 100 -> 50
increase_sk_mem_packets          _SK_MEM_PACKETS 256 -> 1024
f2fs_reduce_congestion           DEFAULT_IO_TIMEOUT 20ms -> 6ms
f2fs_enlarge_min_fsync_blocks    DEF_MIN_FSYNC_BLOCKS 8 -> 20
reduce_pci_pme_wakeups           PME_TIMEOUT 1000 -> 4000
reduce_gc_thread_sleep_time      f2fs urgent GC sleep 500ms -> 50ms
```

The upstream set is larger. The rest is deliberately not applied:

| Patch | Why not |
|---|---|
| `optimized_mem_operations` | Patches `lib/string.c` inside `#ifndef __HAVE_ARCH_MEMCPY/MEMSET/MEMMOVE`. arm64 defines all three and uses `arch/arm64/lib/*.S`, so it compiles to nothing here |
| `silence_irq_cpu_logspam` | `pr_warn` → `pr_debug` on IRQ affinity failure. Hides a real error |
| `silence_system_logspam` | Drops `devkmsg` writes whose text contains `healthd`/`logd`/`dashd`. Breaks logging |
| `add_timeout_wakelocks_globally` | Turns indefinite wakelocks into 500 ms timeouts. Can cut short work that legitimately needs to stay awake |
| `increase_ext4_default_commit_age` | 5s → 30s commit interval. More data at risk on an unclean shutdown |
| `disable_cache_hot_buddy` | Turns off the EEVDF feature that keeps a task on its CPU. Costs cache locality |
| `file_struct_8bytes_align` | Changes `struct file` alignment for no stated benefit |
| `add_limitation_scaling_min_freq`, `re_write_…`, `use_unlikely_wrap_cpufreq` | A cpufreq sysfs feature, not an optimisation. The last depends on the first, so all three go together |
| `optimise_memcmp`, `int_sqrt` | Live, but replace already-optimised code in functions that are not hot |

Adding a name to the allowlist means reviewing the patch first. The external repo is cloned from a moving branch, so the commit it resolved to is recorded as `features.patchset_commit` in `build-info.json`.

### Baseline hardening

Two symbols are enabled on every profile from 6.6 up, with no config flag - they are cheap enough that "should this kernel be secure" is not a per-device question:

| Symbol | What it does | Cost |
|---|---|---|
| `CONFIG_LIST_HARDENED` | Integrity checks in `list_add`/`list_del`. Turns a silent corruption into an immediate, attributable crash | Near zero |
| `CONFIG_RANDOM_KMALLOC_CACHES` | Several copies of each kmalloc cache, picked by code address, so a heap overflow has to guess which one to spray | ~1% |

Neither symbol exists on 6.1 or 5.15, so the step skips those rather than writing a name `olddefconfig` would drop.

Two more are deliberately **not** enabled:

- **`CONFIG_INIT_ON_FREE_DEFAULT_ON`** zeroes every freed object. `INIT_ON_ALLOC_DEFAULT_ON` is already on and covers the main info-leak path; this doubles the zeroing for a smaller marginal gain.
- **`CONFIG_ARM64_MTE`** needs hardware support and a userspace that tolerates tag checks. Enabling it blind crashes things.

### KASAN

`gki_defconfig` ships `CONFIG_KASAN=y` and `CONFIG_KASAN_HW_TAGS=y`. arm64 selects `HAVE_ARCH_KASAN_HW_TAGS` whenever `ARM64_MTE` is on, and `ARM64_MTE` is `default y`, so a plain `make gki_defconfig` keeps both. The runtime default is `KASAN_MODE_SYNC`, the most expensive mode, and only `kasan=off` on the command line turns it off.

That is a debug configuration. Google keeps it out of production GKI through Kleaf's `--kasan` flag, which this build does not use. So `kasan` defaults to **false** and the build appends `# CONFIG_KASAN is not set` to the defconfig. Set `"kasan": true` in a device profile to build a KASAN kernel for debugging.

`CONFIG_KFENCE` stays on either way. It depends only on `HAVE_ARCH_KFENCE`, and its own Kconfig says: "If your kernel targets production use, and cannot enable KASAN due to its cost, consider using KFENCE."

Two checks guard it. After `olddefconfig` the resolved `.config` must not contain `CONFIG_KASAN=y`, `CONFIG_KASAN_HW_TAGS=y`, `CONFIG_KASAN_GENERIC=y` or `CONFIG_KASAN_SW_TAGS=y`. After the build, `build.log` must not contain any `mm/kasan/` object. Either one fails the job rather than shipping a kernel that silently kept the detector.

### O2 vs O3

`optimize_level: O3` works, but not the way the code implies. `CC_OPTIMIZE_FOR_PERFORMANCE_O3` was **removed in Linux 6.0** - it only ever applied to ARC, and Linus rejected re-adding it without substantial justification. On 6.1+ the symbol does not exist, so writing it is a no-op that `olddefconfig` drops. What actually reaches the compiler is `KCFLAGS_EXTRA="-O3"`, appended after the kernel's own `-O2`.

The build now only writes the Kconfig symbol on kernels that still have it (5.10, 5.15). O3 remains available; it is not the default because it is blind - it unrolls and inlines on heuristics, growing kernel text and hurting i-cache on a phone, while AutoFDO and LTO do the same transformations guided by real profile data.

---

## Supported devices

Per-device configs live in [`configs/`](configs), kernel source manifests in [`manifests/`](manifests):

| OxygenOS | Kernel | Devices |
|---|---|---|
| OOS 14 | 5.10 / 5.15 / 6.1 | OnePlus 10 Pro, 10T, 11, 11R, 12, 12R, Pad, Ace series |
| OOS 15 | 5.15 / 6.1 / 6.6 | OnePlus 12, 12R, 13, 13S, Open, Ace 3/5, Nord 4/5 |
| OOS 16 | 6.1 / 6.6 / 6.12 | OnePlus 13, 13S, 15, 15R, 15T, Ace 6, Turbo 6, Pad 2/3/4 |

Everything is built from [OnePlus's official kernel sources](https://github.com/OnePlusOSS/), so the zips target stock ROMs. Don't flash a zip across a major OTA (e.g. A15 to A16) without checking - the KMI has to match.

### OnePlus 15: which profile?

There are two, and the choice is about which OS you are on, not about features.

| | `OP15` | `OP15-COS17` |
|---|---|---|
| Kernel source | OnePlus `sm8850_b_16.0.0_oneplus_15` | AOSP GKI `android16-6.12.69` |
| Kernel version | `6.12.23-android16-5` | `6.12.69-android16-6` |
| For | OxygenOS / ColorOS 16 | ColorOS 17 |
| BORE, ADIOS, AutoFDO, DAMON | yes | yes |
| MLGO | no | yes |
| BBR3 | no | yes |
| NTSync | yes | no |
| Droidspaces | yes | no |
| `opt` patches | yes | no |

If you are on OxygenOS 16 with a `6.12.23-android16-5` kernel, `OP15` is your profile.

### Known-unbuildable profiles

72 of 159 profiles cannot be built today. The cause is the same for all of them: the `susfs4ksu` branch for that KMI has been rebased onto a newer kernel, so its `50_add_susfs` patch no longer matches the OnePlus tree the profile pins. The build aborts on the leftover `.rej` rather than shipping a kernel with SUSFS hooks missing.

| KMI | Blocked | Failing files |
|---|---|---|
| `android13-5.15` | 21 | `fs/namespace.c`, `fs/proc/task_mmu.c` |
| `android14-6.1` | 51 | `fs/namespace.c` |

Every other KMI builds. `android15-6.6` and `android16-6.12` were on this list until `scripts/check-patches.sh` was taught to reproduce the build's pre-patches: the dry-run was reporting rejects the build never sees, because the build edits a few vendor files before applying the SUSFS patch. Two profiles the old table named, `OP-ACE-5-PRO-6.6.30` and the A16 `OP11`, build fine and are no longer blocked.

Each blocked profile carries a `blocked` field with the reason. The build matrix drops them, so selecting a model family builds the siblings that work instead of failing the whole run; the skipped profiles are listed in the run summary. Selecting a model whose every profile is blocked fails immediately with the reason rather than 20 minutes into a patch step. `scripts/validate-configs.py` checks that this list and the `blocked` fields agree, and `scripts/sweep-patches.sh` re-derives the whole thing from scratch.

<details>
<summary>All 72 blocked profiles</summary>

**`android13-5.15`**

- `configs/a15/OP-ACE-2-PRO-5.15.149.json`
- `configs/a15/OP-ACE-2-PRO.json`
- `configs/a15/OP-ACE-3-5.15.149.json`
- `configs/a15/OP-ACE-3.json`
- `configs/a15/OP-NORD-4-CE-5.15.149.json`
- `configs/a15/OP-NORD-4-CE-5.15.167.json`
- `configs/a15/OP-NORD-4-CE.json`
- `configs/a15/OP-OPEN-5.15.149.json`
- `configs/a15/OP-OPEN.json`
- `configs/a15/OP11-5.15.149.json`
- `configs/a15/OP12r-5.15.149.json`
- `configs/a15/OP12r.json`
- `configs/a16/OP-ACE-2-PRO.json`
- `configs/a16/OP-ACE-3-5.15.167.json`
- `configs/a16/OP-ACE-3.json`
- `configs/a16/OP-N6.json`
- `configs/a16/OP-NORD-4-CE.json`
- `configs/a16/OP-OPEN-5.15.167.json`
- `configs/a16/OP-OPEN.json`
- `configs/a16/OP11-5.15.167.json`
- `configs/a16/OP12r-5.15.167.json`

**`android14-6.1`**

- `configs/a14/OP-ACE-3-PRO.json`
- `configs/a14/OP-PAD-PRO.json`
- `configs/a14/OP12.json`
- `configs/a15/OP-ACE-3-PRO-6.1.75.json`
- `configs/a15/OP-ACE-3-PRO.json`
- `configs/a15/OP-ACE-3V-6.1.75.json`
- `configs/a15/OP-ACE-3V.json`
- `configs/a15/OP-ACE-5-6.1.75.json`
- `configs/a15/OP-ACE-5-RACE.json`
- `configs/a15/OP-ACE-5.json`
- `configs/a15/OP-NORD-4-6.1.75.json`
- `configs/a15/OP-NORD-4.json`
- `configs/a15/OP-NORD-5.json`
- `configs/a15/OP-NORD-CE-5.json`
- `configs/a15/OP-NORD-CE4-LITE.json`
- `configs/a15/OP-PAD-2-SM8650-6.1.75.json`
- `configs/a15/OP-PAD-2-SM8650.json`
- `configs/a15/OP-PAD-3-MT6897-6.1.75.json`
- `configs/a15/OP-PAD-3-MT6897.json`
- `configs/a15/OP-PAD-PRO-6.1.75.json`
- `configs/a15/OP-PAD-PRO.json`
- `configs/a15/OP12-6.1.75.json`
- `configs/a15/OP12.json`
- `configs/a15/OP13r-6.1.75.json`
- `configs/a15/OP13r.json`
- `configs/a16/OP-ACE-3-PRO-6.1.118.json`
- `configs/a16/OP-ACE-3-PRO.json`
- `configs/a16/OP-ACE-3V-6.1.118.json`
- `configs/a16/OP-ACE-3V.json`
- `configs/a16/OP-ACE-5-6.1.118.json`
- `configs/a16/OP-ACE-5-RACE-6.1.134.json`
- `configs/a16/OP-ACE-5-RACE.json`
- `configs/a16/OP-ACE-5.json`
- `configs/a16/OP-NORD-4-6.1.118.json`
- `configs/a16/OP-NORD-5-6.1.118.json`
- `configs/a16/OP-NORD-CE-5-6.1.134.json`
- `configs/a16/OP-NORD-CE-5.json`
- `configs/a16/OP-NORD-CE4-LITE-6.1.118.json`
- `configs/a16/OP-NORD-CE4-LITE.json`
- `configs/a16/OP-NORD-CE6-LITE.json`
- `configs/a16/OP-PAD-2-SM8650.json`
- `configs/a16/OP-PAD-3-MT6897.json`
- `configs/a16/OP-PAD-GO-2.json`
- `configs/a16/OP-PAD-PRO.json`
- `configs/a16/OP-TURBO-6V-6.1.118.json`
- `configs/a16/OP-TURBO-6V.json`
- `configs/a16/OP-TURBO-6X.json`
- `configs/a16/OP12-6.1.118.json`
- `configs/a16/OP12.json`
- `configs/a16/OP13r-6.1.118.json`
- `configs/a16/OP13r.json`

</details>

### Tested on hardware

A green build proves a profile compiles, not that it boots. Profiles carry a `tested` field once someone has flashed them, and the release notes list those separately from the rest.

| Profile | What was verified |
|---|---|
| `OP15` | v2.2.0 on OxygenOS 16 (6.12.23): flashed, booted, used as a daily driver. Not a full subsystem pass |

Everything else is compile-verified only. If you flash one and it works, the useful thing to send back is the profile name, the build tag, and which of boot, suspend/resume, camera, modem, Wi-Fi and thermals you actually exercised.

---

## Flashing

1. Unlock the bootloader and back up your stock `boot` / `init_boot` image.
2. Flash the zip with [Kernel Flasher](https://github.com/fatalcoder524/KernelFlasher), [Horizon Kernel Flasher](https://github.com/libxzr/HorizonKernelFlasher), or a custom recovery. In `lkm` mode the installer patches the ramdisk on-device via `ksud boot-patch`.
3. Reboot, then install the SukiSU-Ultra manager APK.

### Verifying a build

Each release lists a `sha256` next to every zip. Check it before flashing:

```sh
sha256sum OP15-COS17_android16-6.12.69-SuSFS_v2.3.0-r3.zip
```

Every zip also ships a `build-info.json` recording the exact kernel source commit, the SUSFS and SukiSU-Ultra revisions, the toolchain, the image/zip checksums, and a `features` block - `lto`, `autofdo` with the profile hash, `damon`, `bore`, `adios`, `mlgo`, and `patchset_commit` for the external patch repo. Two builds of the same version stay distinguishable.

---

## Not implemented yet

Things a current Android kernel normally has that this one does not. Listed so the gap is visible rather than implied.

| Item | Why it matters | Blocker |
|---|---|---|
| **`CONFIG_INIT_ON_FREE_DEFAULT_ON`** | Zeroes freed heap memory, kills use-after-free info leaks | Perf cost is real; `INIT_ON_ALLOC_DEFAULT_ON` is already on |
| **`CONFIG_ARM64_MTE`** | Memory tagging; GrapheneOS enables it for the kernel | Needs hardware support and a userspace that tolerates the tag checks |
| **16 KB page size** | Required for new Android 16+ devices | Not a toggle; changing it breaks every existing binary on the device |

Already on and easy to assume otherwise: `CONFIG_RANDOMIZE_KSTACK_OFFSET` defaults to `y` and both kernel trees select `HAVE_ARCH_RANDOMIZE_KSTACK_OFFSET`, so it is active without appearing in `gki_defconfig`.

[`ROADMAP.md`](ROADMAP.md) carries the rest: what shipped, what was investigated and rejected with the reason, and what is blocked upstream.

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
| Kernel patches | WildKernels | [github.com/WildKernels/kernel_patches](https://github.com/WildKernels/kernel_patches) |
| BORE scheduler | firelzrd | [github.com/firelzrd/bore-scheduler](https://github.com/firelzrd/bore-scheduler) |
| ADIOS I/O scheduler | firelzrd | [github.com/firelzrd/adios](https://github.com/firelzrd/adios) |
