# Pull source paths out of "azcopy jobs show --with-status=Success" output.
#
# Matches the source URLs rather than a named field, so this works whether
# the output is text or JSON and survives a format change.
#
# Emits one path per line, relative to PREFIX, percent-decoding as it goes,
# because "azcopy rm --list-of-files" requires paths that are NOT URL encoded.
#
# Run with LC_ALL=C. sprintf("%c") then emits raw bytes, so a percent-encoded
# UTF-8 filename is reassembled correctly instead of being mangled.
#
# -v SRC_ENDPOINT=<url>  -v DST_ENDPOINT=<url>  -v CONTAINER=<name>  -v PREFIX=<dir>
# PREFIX may be empty, meaning the container root.

function hex2dec(h,   d, i, c, v) {
  d = 0
  for (i = 1; i <= length(h); i++) {
    c = tolower(substr(h, i, 1))
    v = index("0123456789abcdef", c) - 1
    if (v < 0) return -1
    d = d * 16 + v
  }
  return d
}

function urldecode(s,   out, h, n) {
  out = ""
  while (match(s, /%[0-9A-Fa-f][0-9A-Fa-f]/)) {
    out = out substr(s, 1, RSTART - 1)
    h = substr(s, RSTART + 1, 2)
    n = hex2dec(h)
    out = out sprintf("%c", n)
    s = substr(s, RSTART + 3)
  }
  return out s
}

# Escape ERE metacharacters so an endpoint (which contains dots) can be
# dropped into a match() pattern as a literal string.
function reesc(s,   out, i, c, special) {
  out = ""
  special = "\\^$.[]|()*+?{}"
  for (i = 1; i <= length(s); i++) {
    c = substr(s, i, 1)
    if (index(special, c) > 0) out = out "\\" c
    else out = out c
  }
  return out
}

# Strip scheme, host and query string, then make the path relative to PREFIX.
# Returns "" for anything outside the prefix.
function relpath(url,   p, i) {
  p = url
  sub(/^https?:\/\/[^\/]+\//, "", p)
  i = index(p, "?")
  if (i > 0) p = substr(p, 1, i - 1)
  p = urldecode(p)

  if (index(p, CONTAINER "/") != 1) return ""
  p = substr(p, length(CONTAINER) + 2)
  if (PREFIX != "") {
    if (index(p, PREFIX "/") != 1) return ""
    p = substr(p, length(PREFIX) + 2)
  }
  if (p == "" || p ~ /\/$/) return ""
  return p
}

BEGIN {
  TAB   = sprintf("\t")
  srcRe = reesc(SRC_ENDPOINT) "/[^ \t\"',;\\\\]+"
  dstRe = reesc(DST_ENDPOINT) "/[^ \t\"',;\\\\]+"
}

{
  line = $0
  sub(/\r$/, "", line)

  if (!match(line, srcRe)) next
  srcStart = RSTART; srcLen = RLENGTH
  rel = relpath(substr(line, srcStart, srcLen))
  if (rel == "") next

  # Free sanity check: the job record names the destination too. Where the
  # same line carries it, report which container/share the job actually wrote to.
  # Search only after the source match, otherwise a same-endpoint source and
  # destination (e.g. two containers in one storage account) re-matches the
  # source URL as if it were the destination. relpath() above calls
  # urldecode(), which itself calls match() and clobbers RSTART/RLENGTH, so
  # the source match bounds must be saved before that call, not read after it.
  dest = ""
  tail = substr(line, srcStart + srcLen)
  if (match(tail, dstRe)) {
    dest = substr(tail, RSTART, RLENGTH)
    i = index(dest, "?")
    if (i > 0) dest = substr(dest, 1, i - 1)
    dest = urldecode(dest)
  }

  if (seen[rel]++) next
  if (dest != "") print rel TAB dest
  else            print rel
}
