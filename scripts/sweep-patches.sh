#!/usr/bin/env bash
# Run check-patches.sh over every build profile and report which ones fail.
#
# check-patches.sh answers "does the patch sequence apply to this profile's
# pinned base". This answers "for which profiles does it not", which is the
# question that keeps the README's known-unbuildable table honest. The PR gate
# samples a handful of profiles because a full sweep is too slow for it; this
# is the exhaustive version, meant for a schedule or a local run.
#
# Usage:
#   scripts/sweep-patches.sh                             # every profile
#   scripts/sweep-patches.sh configs/a16/OP15.json ...   # a subset
#
# Env:
#   JOBS  parallel workers (default 6)
#   OUT   write the TSV here as well as stdout
#
# Exit code 0 when every profile passes, 1 when any fails. A profile marked
# 'blocked' is expected to fail: it is reported as BLOCKED, not as a failure,
# and a blocked profile that passes is reported as STALE so the field gets
# removed.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

jobs="${JOBS:-6}"
out="${OUT:-}"

if [ "$#" -gt 0 ]; then
  configs=("$@")
else
  mapfile -t configs < <(find configs -mindepth 2 -name '*.json' | sort)
fi

[ "${#configs[@]}" -gt 0 ] || { echo "no configs to check" >&2; exit 1; }

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

# The worker is a file rather than an exported function: xargs runs it in a
# fresh shell, and a file keeps the quoting out of the xargs invocation.
cat > "$workdir/worker.sh" <<'WORKER'
#!/usr/bin/env bash
set -uo pipefail
cfg="$1"
log=$(mktemp)
trap 'rm -f "$log"' EXIT
rc=0
./scripts/check-patches.sh "$cfg" >"$log" 2>&1 || rc=$?

blocked=$(jq -r '.blocked // empty' "$cfg")

if [ "$rc" -eq 0 ]; then
  if [ -n "$blocked" ]; then
    printf 'STALE\t%s\tmarked blocked but the patch sequence applies\n' "$cfg"
  else
    printf 'PASS\t%s\t\n' "$cfg"
  fi
  exit 0
fi

why=$(grep -oE '[A-Za-z0-9_/]+\.c\.rej' "$log" | sed 's/\.rej$//' | sort -u | paste -sd, -)
if [ -z "$why" ]; then
  why=$(grep -m1 '::error::' "$log" | sed 's/::error:://' || true)
fi
[ -n "$why" ] || why="see log"

if [ -n "$blocked" ]; then
  printf 'BLOCKED\t%s\t%s\n' "$cfg" "$why"
else
  printf 'FAIL\t%s\t%s\n' "$cfg" "$why"
fi
WORKER
chmod +x "$workdir/worker.sh"

printf '%s\0' "${configs[@]}" \
  | xargs -0 -P "$jobs" -I{} "$workdir/worker.sh" {} \
  > "$workdir/results.tsv"

sort -k2 "$workdir/results.tsv" -o "$workdir/results.tsv"

count() { awk -F'\t' -v s="$1" '$1 == s' "$workdir/results.tsv" | wc -l | tr -d ' '; }
pass=$(count PASS)
blocked=$(count BLOCKED)
fail=$(count FAIL)
stale=$(count STALE)

printf '%-8s %-46s %s\n' STATUS PROFILE DETAIL
while IFS=$'\t' read -r status cfg detail; do
  printf '%-8s %-46s %s\n' "$status" "${cfg#configs/}" "$detail"
done < "$workdir/results.tsv"

echo
echo "pass=$pass blocked=$blocked fail=$fail stale=$stale"

if [ -n "$out" ]; then
  cp "$workdir/results.tsv" "$out"
  echo "wrote $out"
fi

if [ "$fail" -gt 0 ]; then
  echo
  echo "::error::$fail profile(s) fail the patch sequence and are not marked blocked"
  exit 1
fi

if [ "$stale" -gt 0 ]; then
  echo
  echo "::warning::$stale profile(s) are marked blocked but now apply; remove the 'blocked' field"
fi

exit 0
