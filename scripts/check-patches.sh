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

echo "== $model ($android-$kernel) =="

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
    printf '%s\n' "$rejects" | sed 's/^/     REJECT: /' >&2
    fail "$label: left rejects"
  fi
  log "$label: clean"
}

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
    printf '%s\n' "$rejects" | sed 's/^/     REJECT: /' >&2
    fail "susfs: left rejects"
  fi
fi

if [ "$bore" = "true" ]; then
  case "$kernel" in
    6.12)
      # Mirrors the build: vendor trees ship 750000ULL, GKI canon is 700000ULL.
      sed -i.bak 's/750000ULL/700000ULL/g; s/0\.75 msec/0.70 msec/g' \
        "$kernel_dir/kernel/sched/fair.c" 2>/dev/null || true
      rm -f "$kernel_dir/kernel/sched/fair.c.bak"
      apply "BORE" "$patches_dir/bore_6.12.patch" --ignore-whitespace -F3
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

echo "== $model: patch sequence applies cleanly =="
