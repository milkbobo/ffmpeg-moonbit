#!/usr/bin/env bash
# Run `moon test` package by package (serial) and summarise.
# Rationale: a single `moon test` over the whole workspace can wedge on the
# .moon-lock; per-package invocation keeps each link step small and gives a
# per-package pass/fail breakdown.
set -u
cd "$(dirname "$0")/.." || exit 1

LOG="${1:-/tmp/moon_test_all.log}"
: > "$LOG"

PKGS=$(find . -name moon.pkg -not -path "./_build/*" -not -path "./.worktrees/*" \
  -not -path "./_ref/*" -not -path "./.trash/*" -not -path "./.scratch/*" \
  -not -path "./scripts/_build/*" -not -path "./.mooncakes/*" \
  | sed 's|/moon.pkg||; s|^\./||' | sort)

TOTAL_PASS=0
TOTAL_FAIL=0
FAILED_PKGS=""
TOTAL_SEC=0

for p in $PKGS; do
  start=$(date +%s)
  out=$(timeout 400 moon test --target wasm --no-render -p "$p" 2>&1)
  rc=$?
  end=$(date +%s)
  dur=$((end - start))
  TOTAL_SEC=$((TOTAL_SEC + dur))
  line=$(printf '%s' "$out" | grep -E "^Total tests:" | tail -1)
  pass=$(printf '%s' "$line" | sed -nE 's/.*passed: ([0-9]+).*/\1/p')
  fail=$(printf '%s' "$line" | sed -nE 's/.*failed: ([0-9]+).*/\1/p')
  [ -z "${pass:-}" ] && pass=0
  [ -z "${fail:-}" ] && fail=0
  TOTAL_PASS=$((TOTAL_PASS + pass))
  TOTAL_FAIL=$((TOTAL_FAIL + fail))
  status="ok"
  if [ "$rc" -ne 0 ]; then
    status="RC=$rc"
    FAILED_PKGS="$FAILED_PKGS $p"
  fi
  printf '[%5ss] %-50s pass=%-5s fail=%-4s %s\n' "$dur" "$p" "$pass" "$fail" "$status" | tee -a "$LOG"
  if [ "$rc" -ne 0 ]; then
    printf '%s\n' "$out" | tail -25 | tee -a "$LOG"
  fi
done

echo "=== SUMMARY ===" | tee -a "$LOG"
echo "packages: $(printf '%s\n' "$PKGS" | wc -l), passed: $TOTAL_PASS, failed: $TOTAL_FAIL, elapsed: ${TOTAL_SEC}s" | tee -a "$LOG"
[ -n "$FAILED_PKGS" ] && echo "problem packages:$FAILED_PKGS" | tee -a "$LOG"
exit 0
