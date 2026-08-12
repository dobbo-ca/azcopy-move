#!/bin/sh
# Delete source objects, but only the ones proven to be at the destination.
#
# Two independent sources of truth must agree:
#   1. What azcopy CLAIMS it copied  -- azcopy jobs show --with-status=Success
#   2. What is ACTUALLY there, with its size  -- azcopy list on the destination
#
# A path is deleted only if both agree and the byte counts match. Everything
# else is reported and kept. Survivors go to one "azcopy rm --list-of-files".
#
# Nothing is deleted unless CLEANUP_ENABLED=true.
#
# Configuration comes from the environment. The SAS tokens are read from
# mounted files, never from a Helm value, a values file, or the pod env --
# but they do appear in the azcopy process argv below, which azcopy gives no
# way to avoid.
#
#   JOB_ID                              required, the azcopy job to read
#   FROM_TO                             required, e.g. BlobBlob, FileBlob -- used to tell
#                                        "azcopy rm" the source location explicitly instead
#                                        of letting it infer from a ".blob"/".file" substring
#                                        in the host, which an overridden endpoint may lack
#   SOURCE_ENDPOINT SOURCE_CONTAINER SOURCE_PREFIX   required (SOURCE_PREFIX may be empty)
#   DEST_ENDPOINT DEST_CONTAINER        required
#   DEST_PREFIX             optional, empty means the container/share root
#   SOURCE_SAS_FILE         required
#   DEST_SAS_FILE           optional; without it the destination is not checked
#   WORK_DIR                default /work
#   CLEANUP_ENABLED         "true" to actually delete
#   TRUST_JOB_RECORD_ONLY   "true" to skip the destination check
#   RECONCILE               "false" to disable the stranded-file sweep
#   SKIP_SIZE_CHECK         "true" to skip the byte comparison
#   AZCOPY                  default "azcopy"

set -eu

LC_ALL=C
export LC_ALL

AZCOPY="${AZCOPY:-azcopy}"
WORK_DIR="${WORK_DIR:-/work}"
SCRIPT_DIR="$(dirname "$0")"

die() { echo "ERROR: $*" >&2; exit 1; }

for v in JOB_ID FROM_TO SOURCE_ENDPOINT SOURCE_CONTAINER DEST_ENDPOINT DEST_CONTAINER SOURCE_SAS_FILE; do
  eval "val=\${$v:-}"
  [ -n "$val" ] || die "$v is not set"
done

# The Trash target for "azcopy rm", derived from what we already know rather
# than left for azcopy to infer from a ".blob"/".file" substring in the host
# -- an overridden endpoint (emulator, private link, IP) may not carry one.
case "$FROM_TO" in
  File*) RM_FROM_TO=FileTrash ;;
  Blob*) RM_FROM_TO=BlobTrash ;;
  *) die "cannot derive an azcopy rm --from-to from FROM_TO=$FROM_TO" ;;
esac

SOURCE_PREFIX="${SOURCE_PREFIX:-}"
DEST_PREFIX="${DEST_PREFIX:-}"
CLEANUP_ENABLED="${CLEANUP_ENABLED:-false}"
TRUST_JOB_RECORD_ONLY="${TRUST_JOB_RECORD_ONLY:-false}"
RECONCILE="${RECONCILE:-true}"
SKIP_SIZE_CHECK="${SKIP_SIZE_CHECK:-false}"

# SAS only. Stop azcopy silently preferring an inherited OAuth identity.
unset AZCOPY_AUTO_LOGIN_TYPE AZCOPY_TENANT_ID 2>/dev/null || true

# Read a SAS: strip all whitespace and any leading "?". A trailing newline
# breaks the signature, and the failure reads as an authorization error.
read_sas() {
  tr -d ' \t\r\n' < "$1" | sed 's/^?//'
}

[ -f "$SOURCE_SAS_FILE" ] || die "no such file: $SOURCE_SAS_FILE"
SOURCE_SAS="$(read_sas "$SOURCE_SAS_FILE")"
[ -n "$SOURCE_SAS" ] || die "$SOURCE_SAS_FILE is empty"

DEST_SAS=""
if [ "$TRUST_JOB_RECORD_ONLY" != "true" ] && [ -n "${DEST_SAS_FILE:-}" ] && [ -f "$DEST_SAS_FILE" ]; then
  DEST_SAS="$(read_sas "$DEST_SAS_FILE")"
fi

DESTCHECK=0
SIZECHECK=0
[ -n "$DEST_SAS" ] && DESTCHECK=1
[ "$SKIP_SIZE_CHECK" != "true" ] && SIZECHECK=1
RECON=0
[ "$RECONCILE" != "false" ] && RECON=1

SRC_ROOT="${SOURCE_ENDPOINT}/${SOURCE_CONTAINER}"
[ -n "$SOURCE_PREFIX" ] && SRC_ROOT="${SRC_ROOT}/${SOURCE_PREFIX}"
DST_ROOT="${DEST_ENDPOINT}/${DEST_CONTAINER}"
[ -n "$DEST_PREFIX" ] && DST_ROOT="${DST_ROOT}/${DEST_PREFIX}"

[ "$SRC_ROOT" != "$DST_ROOT" ] || die "source and destination are the same location; refusing to delete"

mkdir -p "$WORK_DIR"
JOB_RAW="$WORK_DIR/job.raw"
CAND="$WORK_DIR/candidates.tsv"
SRC_TSV="$WORK_DIR/src.tsv"
DST_TSV="$WORK_DIR/dest.tsv"
DELLIST="$WORK_DIR/delete-list.txt"
REPORT="$WORK_DIR/delete-report.csv"
COUNTS="$WORK_DIR/counts.txt"

: > "$SRC_TSV"
: > "$DST_TSV"
: > "$DELLIST"

# ---------------------------------------------------------------------------
# 1. Candidates from the job record.
# ---------------------------------------------------------------------------
echo "Reading job $JOB_ID ..."
"$AZCOPY" jobs show "$JOB_ID" --with-status=Success > "$JOB_RAW" 2>&1 || true

awk -v SRC_ENDPOINT="$SOURCE_ENDPOINT" -v DST_ENDPOINT="$DEST_ENDPOINT" \
    -v CONTAINER="$SOURCE_CONTAINER" -v PREFIX="$SOURCE_PREFIX" \
    -f "$SCRIPT_DIR/candidates.awk" "$JOB_RAW" > "$CAND"

NCAND=$(wc -l < "$CAND" | tr -d ' ')
echo "Candidates from azcopy : $NCAND"

# ---------------------------------------------------------------------------
# 2. What is actually on the destination.
# ---------------------------------------------------------------------------
if [ "$DESTCHECK" = "1" ]; then
  echo "Listing destination ..."
  "$AZCOPY" list "${DST_ROOT}?${DEST_SAS}" --machine-readable --running-tally \
    > "$WORK_DIR/dest.raw" 2>&1 || die "azcopy list failed on the destination; see $WORK_DIR/dest.raw"
  awk -v STRIP="" -f "$SCRIPT_DIR/parse-list.awk" "$WORK_DIR/dest.raw" > "$DST_TSV"
  echo "Files at destination   : $(wc -l < "$DST_TSV" | tr -d ' ')"
else
  echo ""
  echo "NO DESTINATION SAS. The destination will not be checked."
  echo "The azcopy job record is the only evidence that these files arrived."
  echo ""
fi

# ---------------------------------------------------------------------------
# 3. Source sizes, for the byte comparison.
# ---------------------------------------------------------------------------
if [ "$SIZECHECK" = "1" ]; then
  echo "Listing source ..."
  "$AZCOPY" list "${SRC_ROOT}?${SOURCE_SAS}" --machine-readable --running-tally \
    > "$WORK_DIR/src.raw" 2>&1 || die "azcopy list failed on the source; see $WORK_DIR/src.raw"
  awk -v STRIP="" -f "$SCRIPT_DIR/parse-list.awk" "$WORK_DIR/src.raw" > "$SRC_TSV"
  echo "Files at source        : $(wc -l < "$SRC_TSV" | tr -d ' ')"
fi

# ---------------------------------------------------------------------------
# 4. Decide. Default verdict is keep.
# ---------------------------------------------------------------------------
awk -v SRC="$SRC_TSV" -v DST="$DST_TSV" -v CAND="$CAND" \
    -v DELLIST="$DELLIST" -v REPORT="$REPORT" -v COUNTFILE="$COUNTS" \
    -v DESTCHECK="$DESTCHECK" -v SIZECHECK="$SIZECHECK" -v RECONCILE="$RECON" \
    -v DEST_CONTAINER="$DEST_CONTAINER" -v DEST_ENDPOINT="$DEST_ENDPOINT" \
    -f "$SCRIPT_DIR/decide.awk" "$SRC_TSV" "$DST_TSV" "$CAND"

read -r NDEL NKEEP NADDED < "$COUNTS"
echo ""
echo "Reconcile added        : ${NADDED:-0}"
echo "Verified, safe to del  : ${NDEL:-0}"
echo "Held back              : ${NKEEP:-0}"
echo "Report                 : $REPORT"

if [ "${NDEL:-0}" -eq 0 ]; then
  echo ""
  echo "Nothing to delete."
  exit 0
fi

sort -o "$DELLIST" "$DELLIST"

# ---------------------------------------------------------------------------
# 5. Delete.
# ---------------------------------------------------------------------------
if [ "$CLEANUP_ENABLED" != "true" ]; then
  echo ""
  echo "CLEANUP_ENABLED is not true. Reporting only, deleting nothing."
  echo "Would delete ${NDEL} object(s). Plan:"
  "$AZCOPY" rm "${SRC_ROOT}?${SOURCE_SAS}" --from-to="$RM_FROM_TO" --list-of-files "$DELLIST" --recursive --dry-run
  exit 0
fi

if [ "$DESTCHECK" != "1" ]; then
  echo "WARNING: deleting on the job record alone; the destination was not checked." >&2
fi

echo ""
echo "Deleting ${NDEL} object(s) ..."
"$AZCOPY" rm "${SRC_ROOT}?${SOURCE_SAS}" --from-to="$RM_FROM_TO" --list-of-files "$DELLIST" --recursive
echo "Deleted ${NDEL} object(s)."
