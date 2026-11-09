#!/usr/bin/env bash
# Dry-run the kernel patch sequence for one build profile against its pinned base.
#
# This is the check that catches upstream drift before a 40-minute build does.
# It reproduces, in order, what .github/actions/build-kernel/action.yml applies:
#
#   susfs 50_add_susfs_in_<branch>.patch  ->  task_mmu SUS_MAP fix (only if the
#   main patch rejected)  ->  BORE  ->  ADIOS
#
# and fails if any .rej file is left behind.
#
# Usage: scripts/check-patches.sh configs/a16/OP15-COS17.json
# Env:   WORKDIR (default: mktemp -d), KEEP=1 to keep the work tree.

set -euo pipefail

config="${1:?usage: check-patches.sh <config.json>}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
config="$(cd "$(dirname "$config")" && pwd)/$(basename "$config")"

workdir="${WORKDIR:-$(mktemp -d)}"
keep="${KEEP:-0}"
cleanup() { [ "$keep" = "1" ] || rm -rf "$workdir"; }
trap cleanup EXIT

log() { printf '  %s\n' "$*"; }
fail() { printf '::error::%s\n' "$*" >&2; exit 1; }

j() { jq -r "$1" "$config"; }

model=$(j .model)
android=$(j .android_version)
kernel=$(j .kernel_version)
manifest=$(j .manifest)
susfs=$(j '.susfs // false')
bore=$(j '.bore // false')
adios=$(j '.adios // false')
susfs_pin=$(j '.susfs_hash // empty')
blocked=$(j '.blocked // empty')

echo "== $model ($android-$kernel) =="
[ -n "$blocked" ] && echo "   marked blocked: $blocked"

manifest_path="$repo_root/manifests/$(basename "$(dirname "$config")")/$manifest"
[ -f "$manifest_path" ] || fail "manifest not found: $manifest_path"

read -r kernel_url kernel_ref < <(python3 - "$manifest_path" <<'PY'
import sys, xml.etree.ElementTree as ET

root = ET.parse(sys.argv[1]).getroot()
remotes = {r.get("name"): r.get("fetch") for r in root.findall("remote")}

def is_kernel(project):
    name = project.get("name") or ""
    path = project.get("path") or ""
    if path == "kernel_platform/common":
        return True
    if name.startswith("android_kernel_modules"):
        return False
    if name.startswith("android_kernel_"):
        return True
    # fallback: a linkfile that materialises kernel_platform/common
    return any(lf.get("dest") == "kernel_platform/common"
               for lf in project.findall("linkfile"))

for project in root.findall("project"):
    if is_kernel(project):
        fetch = (remotes.get(project.get("remote")) or "").rstrip("/")
        print(fetch + "/" + project.get("name"), project.get("revision"))
        break
PY
)
[ -n "${kernel_url:-}" ] || fail "no kernel source project in $manifest_path"
log "kernel source: $kernel_url @ $kernel_ref"

patches_dir="$repo_root/.github/actions/build-kernel/patches"
susfs_branch="gki-${android}-${kernel}"

# Collect every path the patches touch so the sparse checkout stays small.
paths_file="$workdir/paths.txt"
: > "$paths_file"
add_patch_paths() {
  [ -f "$1" ] || return 0
  grep '^diff --git' "$1" | awk '{print $3}' | sed 's|^a/||' >> "$paths_file"
}

susfs_patch=""
if [ "$susfs" = "true" ]; then
  # Mirrors the androidXX_susfs_branch_or_commit input defaults in
  # build-kernel-release.yml. Keep the two in sync.
  case "${android}-${kernel}" in
    android16-6.12) default_susfs_ref="acb92d4abc922cac384a207744b2db40281a7c7f" ;;
    *)              default_susfs_ref="" ;;
  esac
  susfs_ref="${susfs_pin:-${default_susfs_ref:-$susfs_branch}}"
  log "susfs @ $susfs_ref"
  git init -q "$workdir/susfs"
  git -C "$workdir/susfs" remote add origin https://gitlab.com/simonpunk/susfs4ksu.git
  git -C "$workdir/susfs" fetch -q --depth 1 origin "$susfs_ref" \
    || fail "cannot fetch susfs ref $susfs_ref"
  git -C "$workdir/susfs" checkout -q FETCH_HEAD
  susfs_patch="$workdir/susfs/kernel_patches/50_add_susfs_in_${susfs_branch}.patch"
  [ -f "$susfs_patch" ] || fail "susfs patch missing: 50_add_susfs_in_${susfs_branch}.patch"
  add_patch_paths "$susfs_patch"
fi

[ "$bore" = "true" ] && add_patch_paths "$patches_dir/bore_6.12.patch"
[ "$bore" = "true" ] && add_patch_paths "$patches_dir/bore-fix-6.12.23.patch"
[ "$adios" = "true" ] && add_patch_paths "$patches_dir/adios_ioscheduler_6.12.patch"
add_patch_paths "$patches_dir/susfs-fix-task_mmu-sus-map-gki-6.12.patch"

sort -u "$paths_file" -o "$paths_file"

# Sparse clone of the pinned base. blob:none keeps it to a few MB.
kernel_dir="$workdir/kernel"
git init -q "$kernel_dir"
git -C "$kernel_dir" remote add origin "$kernel_url"
git -C "$kernel_dir" config core.sparseCheckout true
git -C "$kernel_dir" sparse-checkout init --no-cone
git -C "$kernel_dir" sparse-checkout set --stdin < "$paths_file"
git -C "$kernel_dir" fetch -q --depth 1 --filter=blob:none origin "$kernel_ref" \
  || fail "cannot fetch $kernel_url @ $kernel_ref"
git -C "$kernel_dir" checkout -q FETCH_HEAD
log "checked out $(wc -l < "$paths_file") path(s)"

apply() {
  # apply <label> <patch> [extra patch args...]
  local label="$1" patch_file="$2"
  shift 2
  [ -f "$patch_file" ] || fail "$label: patch file missing: $patch_file"
  local rc=0
  ( cd "$kernel_dir" && patch -p1 --forward "$@" < "$patch_file" ) || rc=$?
  if [ "$rc" -gt 1 ]; then
    fail "$label: patch failed seriously (rc=$rc)"
  fi
  local rejects
  rejects=$(find "$kernel_dir" -name '*.rej' | sort)
  if [ -n "$rejects" ]; then
    # Relative to the work tree: the absolute mktemp path is noise in a log
    # and makes two runs of the same profile look different.
    printf '%s\n' "$rejects" | sed "s|^$kernel_dir/||; s|^|     REJECT: |" >&2
    fail "$label: left rejects"
  fi
  log "$label: clean"
}

# The build edits a handful of vendor files before the SUSFS patch, because the
# patch's context expects headers and lines those trees do not have. Without
# these the dry-run reports rejects the build never sees, which is how the
# known-unbuildable list drifted. Mirrors the "Fake kernel patch to fix
# failures" block in action.yml; keep the two in sync.
#
# perl rather than sed: BSD sed and GNU sed disagree about \t inside an append,
# and this script runs on both.
insert_after() {
  # insert_after <file> <anchor> <marker> <text>
  local file="$1" anchor="$2" marker="$3" text="$4"
  [ -f "$file" ] || return 0
  grep -qxF "$marker" "$file" && return 0
  grep -qF "$anchor" "$file" || return 0
  ANCHOR="$anchor" TEXT="$text" perl -i.bak -pe '
    if (!$done && index($_, $ENV{ANCHOR}) >= 0) { $_ .= $ENV{TEXT}; $done = 1 }
  ' "$file"
  rm -f "$file.bak"
  log "prepatch: ${file#"$kernel_dir"/} += ${marker#"${marker%%[![:space:]]*}"}"
}

delete_line() {
  # delete_line <file> <exact line>
  local file="$1" marker="$2"
  [ -f "$file" ] || return 0
  grep -qxF "$marker" "$file" || return 0
  MARKER="$marker" perl -i.bak -ne 'print unless $_ eq "$ENV{MARKER}\n"' "$file"
  rm -f "$file.bak"
  log "prepatch: ${file#"$kernel_dir"/} -= $marker"
}

prepatch() {
  local base="$kernel_dir"
  case "${android}-${kernel}" in
    android15-6.6)
      insert_after "$base/fs/namespace.c" \
        '#include <trace/hooks/blk.h>' \
        '#include <trace/hooks/fs.h>' \
        $'#include <trace/hooks/fs.h>\n'
      insert_after "$base/fs/proc/task_mmu.c" \
        'int ret = 0, copied = 0;' \
        $'\tunsigned int nr_subpages = __PAGE_SIZE / PAGE_SIZE;' \
        $'\tpagemap_entry_t *res = NULL;\n\tunsigned int nr_subpages = __PAGE_SIZE / PAGE_SIZE;\n'
      insert_after "$base/fs/proc/base.c" \
        '#include <linux/cpufreq_times.h>' \
        '#include <linux/dma-buf.h>' \
        $'#include <linux/dma-buf.h>\n'
      insert_after "$base/mm/memory.c" \
        '#include <linux/sched/sysctl.h>' \
        '#include <linux/zswap.h>' \
        $'#include <linux/zswap.h>\n'
      # Widen the last_vma_end if block so the SUS_MAP hunk has a body to match.
      if [ -f "$base/fs/proc/task_mmu.c" ] \
         && grep -qF 'if (vma->vm_end > last_vma_end)' "$base/fs/proc/task_mmu.c" \
         && ! grep -qxF 'SUSFS_IS_INODE_SUS_MAP' "$base/fs/proc/task_mmu.c"; then
        perl -i.bak -0pe 's/\t\t\tif \(vma->vm_end > last_vma_end\)\n\t\t\t\tsmap_gather_stats\(vma, &mss, last_vma_end\);/\t\t\tif (vma->vm_end > last_vma_end) {\n\t\t\t\tsmap_gather_stats(vma, \&mss, last_vma_end);\n\t\t\t\tlast_vma_end = vma->vm_end;\n\t\t\t}/' \
          "$base/fs/proc/task_mmu.c"
        rm -f "$base/fs/proc/task_mmu.c.bak"
        log "prepatch: fs/proc/task_mmu.c last_vma_end block widened"
      fi
      ;;
    android13-5.15)
      delete_line "$base/mm/memory.c" '#include <linux/swap_slots.h>'
      ;;
    android14-6.1)
      insert_after "$base/fs/proc/base.c" \
        '#include <linux/cpufreq_times.h>' \
        '#include <linux/dma-buf.h>' \
        $'#include <linux/dma-buf.h>\n'
      ;;
  esac
}

if [ "$susfs" = "true" ]; then
  prepatch
fi

if [ "$susfs" = "true" ]; then
  # The main patch is expected to reject on 6.12.30+; rc=1 is tolerated so the
  # adapted fix below can run, exactly like the build does.
  rc=0
  ( cd "$kernel_dir" && patch -p1 --forward < "$susfs_patch" ) || rc=$?
  [ "$rc" -le 1 ] || fail "susfs: patch failed seriously (rc=$rc)"

  if find "$kernel_dir" -name 'task_mmu.c.rej' | grep -q .; then
    log "susfs: task_mmu rejected, applying adapted fix"
    rm -f "$kernel_dir/fs/proc/task_mmu.c.rej"
    apply "susfs task_mmu fix" "$patches_dir/susfs-fix-task_mmu-sus-map-gki-6.12.patch"
  else
    log "susfs: task_mmu applied from the main patch, fix not needed"
  fi

  rejects=$(find "$kernel_dir" -name '*.rej' | sort)
  if [ -n "$rejects" ]; then
    # Relative to the work tree: the absolute mktemp path is noise in a log
    # and makes two runs of the same profile look different.
    printf '%s\n' "$rejects" | sed "s|^$kernel_dir/||; s|^|     REJECT: |" >&2
    fail "susfs: left rejects"
  fi
fi

if [ "$bore" = "true" ]; then
  case "$kernel" in
    6.12)
      # Mirrors the build: vendor trees ship 750000ULL and a 0.75 msec comment,
      # GKI canon is 700000ULL / 0.70 msec. Bracket expressions keep the sed
      # free of backslashes.
      sed -i.bak 's/750000ULL/700000ULL/g; s/0[.]75 msec/0.70 msec/g' \
        "$kernel_dir/kernel/sched/fair.c" 2>/dev/null || true
      rm -f "$kernel_dir/kernel/sched/fair.c.bak"
      # -F0 mirrors the build: with fuzz the pick_eevdf hunk lands in the wrong
      # place on 6.12.23 instead of rejecting.
      rc=0
      ( cd "$kernel_dir" && patch -p1 --forward --ignore-whitespace -F0 < "$patches_dir/bore_6.12.patch" ) || rc=$?
      [ "$rc" -le 1 ] || fail "BORE: patch failed seriously (rc=$rc)"
      if [ -f "$kernel_dir/kernel/sched/fair.c.rej" ]; then
        rej_hunks=$(grep -c '^@@' "$kernel_dir/kernel/sched/fair.c.rej" || true)
        if [ "$rej_hunks" != "2" ] \
           || ! grep -q 'if (curr && protect && protect_slice(curr))' "$kernel_dir/kernel/sched/fair.c.rej" \
           || ! grep -q 'se_bore(curr)->burst_time += delta_exec' "$kernel_dir/kernel/sched/fair.c.rej"; then
          cat "$kernel_dir/kernel/sched/fair.c.rej" >&2
          fail "BORE: unexpected rejects"
        fi
        log "BORE: 6.12.23 divergences detected, applying adapted hunks"
        rc=0
        ( cd "$kernel_dir" && patch -p1 --forward -F0 < "$patches_dir/bore-fix-6.12.23.patch" ) || rc=$?
        [ "$rc" -eq 0 ] || fail "BORE: adapted hunks did not apply (rc=$rc)"
        rm -f "$kernel_dir/kernel/sched/fair.c.rej"
      else
        log "BORE: clean"
      fi
      # Post-conditions, same as the build.
      for needle in \
        'static const unsigned int nsecs_per_tick' \
        'unsigned int sysctl_sched_min_base_slice' \
        'void sched_update_min_base_slice(void)' \
        'se_bore(curr)->burst_time += delta_exec'; do
        grep -qF "$needle" "$kernel_dir/kernel/sched/fair.c" \
          || fail "BORE: missing '$needle'"
      done
      guard_ctx=$(grep -A2 'sched_burst_parity_threshold < cfs_rq->nr_running' "$kernel_dir/kernel/sched/fair.c" || true)
      case "$guard_ctx" in
        *'return curr;'*) ;;
        *) fail "BORE: parity guard is not in front of return curr" ;;
      esac
      grep -q 'CONFIG_SCHED_BORE' "$kernel_dir/kernel/sched/sched.h" \
        || fail "BORE: kernel/sched/sched.h was not patched"
      ;;
    *) log "BORE: no patch for $kernel, skipped" ;;
  esac
fi

if [ "$adios" = "true" ]; then
  case "$kernel" in
    6.12) apply "ADIOS" "$patches_dir/adios_ioscheduler_6.12.patch" --ignore-whitespace -F3 ;;
    *) log "ADIOS: no patch for $kernel, skipped" ;;
  esac
fi

# A blocked profile that now applies cleanly means the blocker is gone and the
# field is stale. Say so instead of leaving a working profile switched off.
if [ -n "$blocked" ]; then
  printf '::warning::%s is marked blocked but its patch sequence now applies. Remove the "blocked" field from %s.\n' \
    "$model" "${config#"$repo_root"/}"
fi

echo "== $model: patch sequence applies cleanly =="
