#!/bin/sh
# One cycle of the drain: copy a source prefix to a destination prefix, then
# delete the source objects proven to have arrived.
#
# 1. azcopy copy, capturing the job ID from its own output.
# 2. remove-migrated.sh reads that specific job.
# 3. It deletes only what it can verify.
#
# Step 3 does nothing unless CLEANUP_ENABLED=true.
#
# Exit codes: 0 success, 1 configuration error, 2 copy produced no job ID,
# 3 cleanup failed.

set -eu

LC_ALL=C
export LC_ALL

AZCOPY="${AZCOPY:-azcopy}"
WORK_DIR="${WORK_DIR:-/work}"
SCRIPT_DIR="$(dirname "$0")"

die() { echo "ERROR: $*" >&2; exit 1; }

for v in SOURCE_ENDPOINT SOURCE_CONTAINER DEST_ENDPOINT DEST_CONTAINER FROM_TO; do
  eval "val=\${$v:-}"
  [ -n "$val" ] || die "$v is not set"
done

SOURCE_PREFIX="${SOURCE_PREFIX:-}"
DEST_PREFIX="${DEST_PREFIX:-}"
SECRETS_DIR="${SECRETS_DIR:-/secrets}"
SOURCE_SAS_FILE="${SOURCE_SAS_FILE:-$SECRETS_DIR/source-sas}"
DEST_SAS_FILE="${DEST_SAS_FILE:-$SECRETS_DIR/dest-sas}"

CLEANUP_ENABLED="${CLEANUP_ENABLED:-false}"
TRUST_JOB_RECORD_ONLY="${TRUST_JOB_RECORD_ONLY:-false}"
RECONCILE="${RECONCILE:-true}"

AZCOPY_OVERWRITE="${AZCOPY_OVERWRITE:-ifSourceNewer}"
AZCOPY_LOG_LEVEL="${AZCOPY_LOG_LEVEL:-ERROR}"
AZCOPY_TRAILING_DOT="${AZCOPY_TRAILING_DOT:-}"
AZCOPY_EXTRA_ARGS="${AZCOPY_EXTRA_ARGS:-}"

# SAS only. No workload identity, no OIDC.
unset AZCOPY_AUTO_LOGIN_TYPE AZCOPY_TENANT_ID 2>/dev/null || true

read_sas() { tr -d ' \t\r\n' < "$1" | sed 's/^?//'; }

[ -f "$SOURCE_SAS_FILE" ] || die "no such file: $SOURCE_SAS_FILE"
SOURCE_SAS="$(read_sas "$SOURCE_SAS_FILE")"
[ -n "$SOURCE_SAS" ] || die "$SOURCE_SAS_FILE is empty"

[ -f "$DEST_SAS_FILE" ] || die "no such file: $DEST_SAS_FILE"
DEST_SAS="$(read_sas "$DEST_SAS_FILE")"
[ -n "$DEST_SAS" ] || die "$DEST_SAS_FILE is empty; the copy cannot write to the destination"

mkdir -p "$WORK_DIR"

SRC="${SOURCE_ENDPOINT}/${SOURCE_CONTAINER}"
[ -n "$SOURCE_PREFIX" ] && SRC="${SRC}/${SOURCE_PREFIX}"
SRC="${SRC}/*"

DST="${DEST_ENDPOINT}/${DEST_CONTAINER}"
[ -n "$DEST_PREFIX" ] && DST="${DST}/${DEST_PREFIX}"

echo "=========================================================="
echo "source    : $SOURCE_ENDPOINT/$SOURCE_CONTAINER/$SOURCE_PREFIX"
echo "dest      : $DEST_ENDPOINT/$DEST_CONTAINER/$DEST_PREFIX"
echo "from-to   : $FROM_TO"
echo "cleanup   : $CLEANUP_ENABLED  (trustJobRecordOnly=$TRUST_JOB_RECORD_ONLY reconcile=$RECONCILE)"
echo "started   : $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "azcopy    : $("$AZCOPY" --version 2>&1 | head -1)"
echo "=========================================================="

# ---------------------------------------------------------------------------
# 1. Copy
# ---------------------------------------------------------------------------
COPY_LOG="$WORK_DIR/copy.log"
echo ""
echo "--- azcopy copy ---"

TRAILING_DOT_ARGS=""
[ -n "$AZCOPY_TRAILING_DOT" ] && TRAILING_DOT_ARGS="--trailing-dot=$AZCOPY_TRAILING_DOT"

set +e
set -f
# shellcheck disable=SC2086
{
  "$AZCOPY" copy "${SRC}?${SOURCE_SAS}" "${DST}?${DEST_SAS}" \
    --from-to="$FROM_TO" \
    --recursive \
    --overwrite="$AZCOPY_OVERWRITE" \
    $TRAILING_DOT_ARGS \
    --log-level="$AZCOPY_LOG_LEVEL" \
    $AZCOPY_EXTRA_ARGS 2>&1
  echo $? > "$WORK_DIR/copy.rc"
} | tee "$COPY_LOG"
set +f
COPY_EXIT="$(cat "$WORK_DIR/copy.rc")"
set -e

JOB_ID="$(sed -n 's/.*[Jj]ob \([0-9a-fA-F][0-9a-fA-F-]\{34\}[0-9a-fA-F]\) has started.*/\1/p' "$COPY_LOG" | head -1)"
if [ -z "$JOB_ID" ]; then
  JOB_ID="$(grep -oE '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}' "$COPY_LOG" | head -1)"
fi

echo ""
echo "copy exit : $COPY_EXIT"
echo "job id    : ${JOB_ID:-<not found>}"

# A non-zero exit does not mean nothing moved. Partial success is normal, and
# the cleanup only ever deletes transfers marked Success, so carry on.
if [ "$COPY_EXIT" -ne 0 ]; then
  echo "WARNING: azcopy copy exited $COPY_EXIT. Continuing to the verified cleanup." >&2
fi
[ -n "$JOB_ID" ] || { echo "ERROR: no azcopy job ID found; skipping cleanup." >&2; exit 2; }

# ---------------------------------------------------------------------------
# 2 and 3. Verify, then delete.
# ---------------------------------------------------------------------------
echo ""
echo "--- verify and cleanup ---"

JOB_ID="$JOB_ID" \
FROM_TO="$FROM_TO" \
SOURCE_ENDPOINT="$SOURCE_ENDPOINT" \
SOURCE_CONTAINER="$SOURCE_CONTAINER" \
SOURCE_PREFIX="$SOURCE_PREFIX" \
DEST_ENDPOINT="$DEST_ENDPOINT" \
DEST_CONTAINER="$DEST_CONTAINER" \
DEST_PREFIX="$DEST_PREFIX" \
SOURCE_SAS_FILE="$SOURCE_SAS_FILE" \
DEST_SAS_FILE="$DEST_SAS_FILE" \
WORK_DIR="$WORK_DIR" \
CLEANUP_ENABLED="$CLEANUP_ENABLED" \
TRUST_JOB_RECORD_ONLY="$TRUST_JOB_RECORD_ONLY" \
RECONCILE="$RECONCILE" \
AZCOPY="$AZCOPY" \
  "$SCRIPT_DIR/remove-migrated.sh" || { echo "ERROR: cleanup failed" >&2; exit 3; }

if [ -f "$WORK_DIR/delete-report.csv" ]; then
  echo ""
  echo "--- delete report (first 50 rows) ---"
  head -50 "$WORK_DIR/delete-report.csv"
fi

echo ""
echo "finished  : $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
