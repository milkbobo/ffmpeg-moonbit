#!/usr/bin/env bash
# Run `moon test` for every package listed in a file, serially.
# Usage: _run_pkg_tests.sh <pkglist> <logfile>
set -u
cd "$(dirname "$0")/.." || exit 1
LIST="${1:?pkg list required}"
LOG="${2:-/tmp/pkg_tests.log}"
: > "$LOG"

ok=0; bad=0; skip=0
badpkgs=()

while IFS= read -r p; do
  [ -z "$p" ] && continue
  echo "=== $p ===" | tee -a "$LOG"
  out=$(timeout 2400 moon test -p "$p" --target wasm --no-render 2>&1)
  rc=$?
  if echo "$out" | grep -qi 'local count too large'; then
    echo "  [retry wasm-gc]" | tee -a "$LOG"
    out=$(timeout 2400 moon test -p "$p" --target wasm-gc --no-render 2>&1)
    rc=$?
  fi
  if [ "$rc" -eq 0 ] && ! echo "$out" | grep -qE 'failed: [1-9]'; then
    line=$(printf '%s' "$out" | grep -E '^Total tests:' | tail -1)
    echo "  OK  ${line:-no tests}" | tee -a "$LOG"
    ok=$((ok+1))
  else
    line=$(printf '%s' "$out" | grep -E '^Total tests:' | tail -1)
    echo "  FAIL rc=$rc ${line:-}" | tee -a "$LOG"
    printf '%s\n' "$out" | tail -60 >> "$LOG"
    bad=$((bad+1)); badpkgs+=("$p")
  fi
done < "$LIST"

echo "=== SUMMARY ===" | tee -a "$LOG"
echo "ok=$ok bad=$bad" | tee -a "$LOG"
for p in "${badpkgs[@]:-}"; do [ -n "$p" ] && echo "BAD: $p" | tee -a "$LOG"; done
