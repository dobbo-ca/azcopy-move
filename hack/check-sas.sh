#!/bin/sh
# Validate an Azure SAS token without ever printing it.
#
# Usage: check-sas.sh <token-file> <required-permissions>
#   check-sas.sh /path/to/source-sas rdl
#
# Checks:
#   - the file exists and is non-empty
#   - the token does not start with "?" (a common copy/paste artifact)
#   - the token has an "sv=" parameter
#   - the token has a "sig=" parameter
#   - each letter of <required-permissions> is present in the "sp=" parameter
#   - warns (does not fail) when "se=" expires within 48 hours
#
# Works with both BSD date (macOS) and GNU date (Linux), like the deploy.sh
# this was lifted from.

set -eu

die() { echo "ERROR: $*" >&2; exit 1; }

[ "$#" -eq 2 ] || die "usage: $0 <token-file> <required-permissions>"

FILE="$1"
WANT="$2"

[ -f "$FILE" ] || die "no such file: $FILE"
[ -s "$FILE" ] || die "$FILE is empty"

BODY="$(tr -d ' \t\r\n' < "$FILE")"

case "$BODY" in
  '?'*) die "$FILE starts with '?'. Remove it." ;;
esac

case "$BODY" in
  *sv=*) ;;
  *) die "$FILE has no sv= parameter." ;;
esac

case "$BODY" in
  *sig=*) ;;
  *) die "$FILE has no sig= parameter." ;;
esac

# A real token (as az CLI mints it) has no leading '?' or '&' before its
# first parameter, so prefix one before extracting -- otherwise a parameter
# sitting first in the string (commonly se=) can never match "[?&]name=".
QBODY="&$BODY"

# sp= holds the permission letters, e.g. sp=rdl. Extract up to the next '&'.
SP="$(printf '%s' "$QBODY" | sed -n 's/.*[?&]sp=\([^&]*\).*/\1/p')"

i=1
n=${#WANT}
while [ "$i" -le "$n" ]; do
  p="$(printf '%s' "$WANT" | cut -c"$i")"
  case "$SP" in
    *"$p"*) ;;
    *) die "$FILE is missing the '$p' permission. Need: $WANT" ;;
  esac
  i=$((i + 1))
done

# Warn on an expiry inside 48 hours. Every run fails once a SAS lapses.
SE="$(printf '%s' "$QBODY" | sed -n 's/.*[?&]se=\([^&]*\).*/\1/p')"
SE="$(printf '%s' "$SE" | sed 's/%3A/:/g')"

if [ -z "$SE" ]; then
  echo "$(basename "$FILE"): no se= found, cannot check expiry"
else
  NOW_S=$(date -u +%s)
  EXP_S=""
  if EXP_S=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$SE" +%s 2>/dev/null); then
    :
  elif EXP_S=$(date -u -d "$SE" +%s 2>/dev/null); then
    :
  fi
  if [ -n "$EXP_S" ]; then
    HOURS=$(( (EXP_S - NOW_S) / 3600 ))
    echo "$(basename "$FILE"): expires $SE  (${HOURS}h)"
    if [ "$HOURS" -le 48 ]; then
      echo "WARNING: $(basename "$FILE") expires within 48 hours. Every run will fail after that." >&2
    fi
  else
    echo "$(basename "$FILE"): expires $SE  (could not parse)"
  fi
fi

echo "$(basename "$FILE"): OK, has sv=, sig=, and permissions [$WANT]"
