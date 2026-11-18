#!/usr/bin/env bash
# Run libavcodec's own-package tests in batches.
#
# Why: `moon test -p libavcodec` builds one test-args JSON listing every
# file in the package (563 .mbt files) and passes it to moonrun.exe on the
# command line. On Windows that exceeds the 32K command-line limit and the
# spawn fails with "文件名或扩展名太长 (os error 206)".
#
# Workaround: name the test files explicitly in batches so the JSON stays
# short. Black-box *_test.mbt runs on wasm; white-box *_wbtest.mbt runs on
# wasm-gc (wasm hits the V8 "local count too large" ceiling).
set -u
cd "$(dirname "$0")/.." || exit 1

LOG="${1:-/tmp/libavcodec_batches.log}"
: > "$LOG"

BATCH_FILES=15
TPASS=0
TFAIL=0
NPASS=0
NFAIL=0
ELAPSED=0

run_batch() {
  # $1 = target, rest = files
  local target="$1"; shift
  local files=("$@")
  [ ${#files[@]} -eq 0 ] && return 0
  local cmd=(moon test --target "$target" --no-render)
  cmd+=("${files[@]}")
  local start end dur out line pass fail rc
  start=$(date +%s)
  out=$(timeout 2400 "${cmd[@]}" 2>&1)
  rc=$?
  end=$(date +%s)
  dur=$((end - start))
  ELAPSED=$((ELAPSED + dur))
  line=$(printf '%s' "$out" | grep -E "^Total tests:" | tail -1)
  pass=$(printf '%s' "$line" | sed -nE 's/.*passed: ([0-9]+).*/\1/p')
  fail=$(printf '%s' "$line" | sed -nE 's/.*failed: ([0-9]+).*/\1/p')
  [ -z "${pass:-}" ] && pass=0
  [ -z "${fail:-}" ] && fail=0
  TPASS=$((TPASS + pass)); TFAIL=$((TFAIL + fail))
  local tag="ok"
  if [ "$rc" -ne 0 ]; then
    tag="RC=$rc"; NFAIL=$((NFAIL + 1))
    printf '%s\n' "$out" | tail -20 >> "$LOG"
  else
    NPASS=$((NPASS + 1))
  fi
  printf '[%4ss] %-10s n=%-3s pass=%-4s fail=%-3s %s\n' \
    "$dur" "$target" "${#files[@]}" "$pass" "$fail" "$tag" >> "$LOG"
}

batch_files() {
  # $1 = target, $2 = max files per batch, rest = file list
  # NOTE: the file list is passed as arguments, never through a pipe — a
  # pipeline would run this in a subshell and the TPASS/TFAIL totals would
  # be lost.
  local target="$1"
  local maxn="$2"
  shift 2
  local -a cur=()
  local f
  for f in "$@"; do
    [ -z "$f" ] && continue
    cur+=("$f")
    if [ ${#cur[@]} -ge "$maxn" ]; then
      run_batch "$target" "${cur[@]}"
      cur=()
    fi
  done
  [ ${#cur[@]} -gt 0 ] && run_batch "$target" "${cur[@]}"
  return 0
}

enc_bb=()
while IFS= read -r f; do enc_bb+=("$f"); done < <(ls libavcodec/*_test.mbt 2>/dev/null | grep -v '_wbtest\.mbt$' | grep 'h264_enc')
rest_bb=()
while IFS= read -r f; do rest_bb+=("$f"); done < <(ls libavcodec/*_test.mbt 2>/dev/null | grep -v '_wbtest\.mbt$' | grep -v 'h264_enc')
enc_wb=()
while IFS= read -r f; do enc_wb+=("$f"); done < <(ls libavcodec/*_wbtest.mbt 2>/dev/null | grep 'h264_enc')
rest_wb=()
while IFS= read -r f; do rest_wb+=("$f"); done < <(ls libavcodec/*_wbtest.mbt 2>/dev/null | grep -v 'h264_enc')

echo "=== black-box (wasm) ===" | tee -a "$LOG"
# H.264 encoder tests are RD-heavy (h264_enc_brc_test alone takes ~220s),
# so they get their own small batches.
batch_files wasm 5 "${enc_bb[@]}"
batch_files wasm 15 "${rest_bb[@]}"

echo "=== white-box (wasm-gc) ===" | tee -a "$LOG"
batch_files wasm-gc 5 "${enc_wb[@]}"
batch_files wasm-gc 15 "${rest_wb[@]}"

echo "=== SUMMARY ===" | tee -a "$LOG"
echo "libavcodec: passed=$TPASS failed=$TFAIL  batches ok=$NPASS bad=$NFAIL  elapsed=${ELAPSED}s" | tee -a "$LOG"
exit 0
