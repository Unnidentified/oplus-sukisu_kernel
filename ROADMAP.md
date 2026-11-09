# Roadmap

What is done, what was deliberately rejected, and what is still open. Every
entry carries the evidence behind the decision, so a future reader can check it
instead of trusting it.

This kernel targets a **normal daily-driver phone**, not a benchmark build. That
single constraint rejects most of the tuning advice floating around: anything
that trades correctness, debuggability or battery for a synthetic score is out.

---

## Shipped

| Area | What | PR |
|---|---|---|
| Correctness | `SUS_MAP` scope fix, per-device SUSFS pins, duplicated matrix block removed, fail-fast ref resolution | #30 |
| Gates | Patch dry-run against the real base, config schema + validator, KMI/ABI check, actionlint + shellcheck in CI | #30 |
| Provenance | `build-info.json` per build, per-zip sha256 in the release notes, upload guard | #30 |
| Hygiene | Patch provenance headers, BORE slice decision documented, `battery_patches/` removed, build badge, failure notification | #33 |
| Kernel | AutoFDO profile, DAMON, `LTO_NONE` symbol fix | #35 |
| Kernel | BORE, ADIOS and AutoFDO on the OxygenOS 16 profile | #36 |
| CI | `lto_override` repair, resolved-config feature audit | #37 |
| Kernel | Reviewed `opt` allowlist, LTO settled, dead O3 symbol fixed | #38 |
| Hardening | `LIST_HARDENED`, `RANDOM_KMALLOC_CACHES` on every 6.6+ profile | #39 |
| CI | `configs/schema.json` excluded from matrix generation | #40 |
| Kernel | BORE applied with `-F0`, both 6.12.23 hunks adapted | #41 |
| Release | Zips named with the release revision | #42 |
| Debug | KASAN off by default, `kasan` profile field, two build-time guards | #43 |

---

## Decided against

These were investigated and rejected. The reasoning is the useful part; do not
re-litigate without new evidence.

| Candidate | Why not |
|---|---|
| **LTO on 6.12** | Google's Kleaf docs say LTO is disabled by default on GKI from android14-6.1 up and "should only be modified when the trade-offs are fully understood". `gki_defconfig` has no LTO line, so `LTO_NONE` applies. The 151 profiles using `thin` are the deviation, not the 8 using `none`. `lto_override` exists for one-off experiments |
| **`-O3` as default** | `CC_OPTIMIZE_FOR_PERFORMANCE_O3` was removed in Linux 6.0, so on 6.1+ the symbol is a no-op and only `KCFLAGS_EXTRA="-O3"` reaches the compiler. It is blind: it unrolls and inlines on heuristics, growing kernel text and hurting i-cache. AutoFDO and LTO do the same transforms guided by profile data |
| **`CONFIG_INIT_ON_FREE_DEFAULT_ON`** | `INIT_ON_ALLOC_DEFAULT_ON` is already on and covers the main info-leak path. This doubles the zeroing for a smaller marginal gain |
| **`CONFIG_ARM64_MTE`** | Needs hardware support and a userspace that tolerates tag checks. Enabling it blind crashes things |
| **16 KB page size** | Not a toggle. Changing it breaks every existing binary on the device |
| **`CONFIG_SCHEDSTATS=n`** | Gates the `sched_stat_*` tracepoints (`kernel/sched/build_utility.c:74`). Perfetto's `sched_blocked_reason` needs them |
| **`ZSWAP`** | No swap device on these phones |
| **`NO_HZ_FULL` / `CPU_ISOLATION`** | Needs `isolcpus`, which no Android userspace sets |
| **`DEFERRED_STRUCT_PAGE_INIT`** | Only pays off on very large memory with a long boot; adds a second init pass |
| **`PAGE_REPORTING`** | Hypervisor feature, not applicable |
| **`THP_ALWAYS`** | `THP_MADVISE` plus `THP_SWAP` is the right default; always-on THP costs memory and latency on a phone |
| **`HZ_300`** | No upstream user; `HZ=250` is what GKI ships |
| **`PREEMPT_DYNAMIC`** | Adds a static call on every preempt point for a runtime switch nothing flips |
| **`SCHED_THERMAL_PRESSURE`** | Removed in 6.12 |
| **`opt` patches outside the allowlist** | Each one is listed with its reason in the [README](README.md#optimisation-patches-opt). The short version: they either compile to nothing on arm64, hide real errors, or trade data safety for a number |

---

## Blocked upstream

### `CONFIG_SCHED_CLUSTER`

Cluster-aware scheduling landed in 2021 and works on uniform topologies. On
asymmetric ones it does not balance across clusters of equal-capacity CPUs that
share an L2, which is exactly the shape of a modern phone SoC.

Ricardo Neri's fix series, *sched: Fix cluster scheduling in the presence of
asymmetric capacity*, went through six revisions between June 2025 and July 2026
and was merged into the tip `sched/core` branch, pulled for the **v7.3** merge
window (Ingo Molnar, 2026-08-17). It is not in 6.12 and will not be backported:
it is a six-patch scheduler series touching `update_sd_pick_busiest()`,
`sched_balance_find_src_rq()` and the `SD_PREFER_SIBLING` handling in
`sched_domains`.

Enabling the symbol without the fix leaves cluster balancing broken on exactly
the hardware this repo targets. Backporting a six-patch load-balancer series
into a vendor 6.12 tree is not a change a daily-driver kernel should carry.

**Revisit when** a 6.12-based GKI branch picks the series up, or when the repo
moves to a kernel that has it.

---

## Not started

### `scx_lavd`

`sched_ext` is already enabled (`CONFIG_SCHED_CLASS_EXT=y`), so the mechanism is
there. `scx_lavd` is a latency-aware BPF scheduler that would replace the
in-kernel policy for every task.

Two things block it:

1. It needs a userspace loader (`scx_loader` or the `scx_lavd` binary) running
   as a service on the device. A kernel zip cannot ship that.
2. It **replaces** BORE rather than stacking with it. Loading a `sched_ext`
   scheduler takes over dispatch entirely, so the two are mutually exclusive by
   construction.

Shipping it means shipping a second thing to install and keep running, and
losing BORE's in-kernel behaviour. Worth prototyping on a spare device, not
worth making the default.

### DAMON policies

The mechanism is built in and dormant: `DAMON`, `DAMON_VADDR`, `DAMON_PADDR`,
`DAMON_RECLAIM`, `DAMON_LRU_SORT`, `DAMON_SYSFS`. Nothing starts `kdamond`, so
the cost when unused is code size only.

A policy is a userspace decision, not a kernel one: which regions to monitor,
what access pattern counts as hot, and what to do about it. `DAMON_RECLAIM`
thrashing against a phone's working set is worse than no policy at all. This
needs measurement on a real device before it needs code.

---

## How to propose something

1. Check the [Decided against](#decided-against) table first.
2. Bring a source: an upstream commit, a mailing-list thread, a Kconfig help
   text, or a measurement. "This is a known optimisation" is not one.
3. State the cost. Every entry above that was rejected was rejected on cost, not
   on the claim that it does nothing.
4. If it is a patch, it goes through `scripts/check-patches.sh` and the CI gates
   before it goes anywhere near a release.
