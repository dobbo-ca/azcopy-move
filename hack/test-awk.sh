#!/bin/sh
# Golden tests for the awk programs under helm/azcopy-move/scripts/.
#
# Plain sh and diff, no framework. Each case feeds a fixture to the awk
# program with the -v arguments the case needs, diffs the result against a
# golden file, and prints one PASS/FAIL line. Exits non-zero if any case
# failed.
#
# Usage: hack/test-awk.sh

set -eu

LC_ALL=C
export LC_ALL

unset CDPATH
HERE="$(cd -- "$(dirname -- "$0")/.." && pwd)"
SCRIPTS="$HERE/helm/azcopy-move/scripts"
FIX="$HERE/test/fixtures"
GOLD="$HERE/test/golden"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAILED=0

pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; FAILED=1; }

check() {
  name="$1"; got="$2"; want="$3"
  if diff -u "$want" "$got" > "$TMP/diff.$$" 2>&1; then
    pass "$name"
  else
    fail "$name"
    sed 's/^/      /' "$TMP/diff.$$"
  fi
}

# --- candidates.awk ---------------------------------------------------------

run_candidates() {
  name="$1"; src_ep="$2"; dst_ep="$3"; container="$4"; prefix="$5"
  out="$TMP/candidates-$name.txt"
  awk -v SRC_ENDPOINT="$src_ep" -v DST_ENDPOINT="$dst_ep" \
      -v CONTAINER="$container" -v PREFIX="$prefix" \
      -f "$SCRIPTS/candidates.awk" "$FIX/candidates/$name.txt" > "$out"
  check "candidates.awk: $name" "$out" "$GOLD/candidates/$name.txt"
}

run_candidates blob-to-file \
  "https://srcacct.blob.core.windows.net" "https://dstacct.file.core.windows.net" raw imports
run_candidates file-to-blob \
  "https://srcacct.file.core.windows.net" "https://dstacct.blob.core.windows.net" share2 exports
run_candidates percent-encoded \
  "https://srcacct.blob.core.windows.net" "https://dstacct.file.core.windows.net" raw imports
run_candidates empty-prefix \
  "https://srcacct.blob.core.windows.net" "https://dstacct.file.core.windows.net" raw ""
run_candidates outside-prefix \
  "https://srcacct.blob.core.windows.net" "https://dstacct.file.core.windows.net" raw imports
run_candidates duplicate \
  "https://srcacct.blob.core.windows.net" "https://dstacct.file.core.windows.net" raw imports
run_candidates regex-metachars \
  "https://my-acct.blob.core.windows.net" "https://dstacct.file.core.windows.net" raw imports
# same storage account, two containers -- the destination match must not
# re-match the source URL.
run_candidates same-endpoint \
  "https://acct1.blob.core.windows.net" "https://acct1.blob.core.windows.net" raw incoming
# empty PREFIX must not waive the container check: a foreign container is
# still discarded.
run_candidates foreign-container-empty-prefix \
  "https://srcacct.blob.core.windows.net" "https://dstacct.file.core.windows.net" raw ""

# --- parse-list.awk ----------------------------------------------------------

run_parse_list() {
  name="$1"; strip="$2"
  out="$TMP/parse-list-$name.txt"
  awk -v STRIP="$strip" -f "$SCRIPTS/parse-list.awk" "$FIX/parse-list/$name.txt" > "$out"
  check "parse-list.awk: $name" "$out" "$GOLD/parse-list/$name.txt"
}

run_parse_list blob-listing ""
run_parse_list file-share-listing ""
run_parse_list dir-entries ""
run_parse_list trailing-cr ""

# --- decide.awk ---------------------------------------------------------------
# decide.awk writes three separate output files (REPORT, DELLIST, COUNTFILE)
# and does not create DELLIST at all when nothing is deleted. Normalize all
# three into one blob per case so a single diff covers the whole verdict.

run_decide() {
  name="$1"; destcheck="$2"; sizecheck="$3"; reconcile="$4"; dest_container="$5"; dest_endpoint="$6"
  dir="$FIX/decide/$name"
  work="$TMP/decide-$name"
  mkdir -p "$work"
  awk -v SRC="$dir/src.tsv" -v DST="$dir/dst.tsv" -v CAND="$dir/cand.tsv" \
      -v DELLIST="$work/dellist.txt" -v REPORT="$work/report.csv" -v COUNTFILE="$work/counts.txt" \
      -v DESTCHECK="$destcheck" -v SIZECHECK="$sizecheck" -v RECONCILE="$reconcile" \
      -v DEST_CONTAINER="$dest_container" -v DEST_ENDPOINT="$dest_endpoint" \
      -f "$SCRIPTS/decide.awk" "$dir/src.tsv" "$dir/dst.tsv" "$dir/cand.tsv" > /dev/null
  out="$TMP/decide-$name.txt"
  {
    echo "REPORT"
    cat "$work/report.csv"
    echo "DELLIST"
    [ -f "$work/dellist.txt" ] && cat "$work/dellist.txt"
    echo "COUNTS"
    cat "$work/counts.txt"
  } > "$out"
  check "decide.awk: $name" "$out" "$GOLD/decide/$name.txt"
}

DSTEP="https://dstacct.file.core.windows.net"

# verified delete: source and destination agree on size, job wrote to the
# expected container.
run_decide verified-delete 1 1 0 share1 "$DSTEP"
# MISSING at destination -> keep.
run_decide missing-at-dest 1 1 0 share1 "$DSTEP"
# SIZE MISMATCH -> keep.
run_decide size-mismatch 1 1 0 share1 "$DSTEP"
# job wrote to a container other than DEST_CONTAINER -> keep.
run_decide wrong-container 1 1 0 share1 "$DSTEP"
# job wrote to a path where DEST_CONTAINER occurs only as a nested segment
# under a different container -> keep. An unanchored substring test would
# wrongly pass this.
run_decide container-name-substring 1 1 0 archive "https://acct1.blob.core.windows.net"
# reconcile: a file absent from the job record but present, size-matched, at
# both source and destination is picked up as a stranded delete candidate.
run_decide reconcile-stranded 1 1 1 share1 "$DSTEP"
# DESTCHECK=0: job record is the only evidence, so verdict is delete with
# reason "job record only".
run_decide destcheck-0 0 1 0 share1 "$DSTEP"

# --- candidates-file.awk -----------------------------------------------------
#
# Feeds the ad-hoc delete. A path mangled here becomes a delete that misses its
# target, so the awkward CSV cases are the point: a comma inside a quoted path,
# a doubled quote, a duplicate row, CRLF, and a "keep" row (kept deliberately —
# verdicts are recomputed against live state, not trusted from the file).

run_candidates_file() {
  name="$1"; src="$2"
  out="$TMP/candidates-file-$name.txt"
  awk -f "$SCRIPTS/candidates-file.awk" "$FIX/candidates-file/$src" > "$out"
  check "candidates-file.awk: $name" "$out" "$GOLD/candidates-file-$name.txt"
}

run_candidates_file plain-list plain-list.txt
run_candidates_file report     report.csv

# --- progress.awk ------------------------------------------------------------
#
# The fixture holds a real azcopy stream, carriage returns and all. The caller
# converts those to newlines before the filter, so the tests do the same.

run_progress() {
  name="$1"; interval="$2"; have_systime="$3"
  out="$TMP/progress-$name.txt"
  tr '\r' '\n' < "$FIX/progress/copy-stream.raw" \
    | awk -v INTERVAL="$interval" -v HAVE_SYSTIME="$have_systime" \
          -f "$SCRIPTS/progress.awk" > "$out"
  check "progress.awk: $name" "$out" "$GOLD/progress-$name.txt"
}

# 0 disables throttling: every update survives, blank lines from \r\n go.
run_progress interval-0 0 0
# Count fallback: first update prints, the rest are dropped at this interval.
run_progress count-throttled 30 0

# systime() is a gawk/mawk extension. BSD awk (macOS) aborts on it, so only run
# the time-based case where the local awk actually supports it -- and say so
# rather than silently reporting a pass that never ran.
if awk 'BEGIN { t = systime(); exit (t > 0 ? 0 : 1) }' >/dev/null 2>&1; then
  run_progress time-throttled 999999 1
else
  echo "SKIP  progress.awk: time-throttled (this awk has no systime(); the container's gawk does)"
fi

exit "$FAILED"
