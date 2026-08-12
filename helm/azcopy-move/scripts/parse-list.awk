# Convert "azcopy list" output into "relativepath<TAB>bytes".
#
# Input lines look like:   [INFO: ]<path>; Content Length: <n>
# Run with LC_ALL=C so byte handling is predictable.
#
# -v STRIP=<prefix>   remove this leading directory from each path

BEGIN { TAB = sprintf("\t") }

{
  line = $0
  sub(/\r$/, "", line)

  if (!match(line, /; Content Length: [0-9]+[ \t]*$/)) next

  n = substr(line, RSTART, RLENGTH)
  sub(/^; Content Length: /, "", n)
  gsub(/[ \t]+$/, "", n)

  p = substr(line, 1, RSTART - 1)
  sub(/^INFO:[ \t]+/, "", p)
  gsub(/^[ \t]+/, "", p)
  gsub(/[ \t]+$/, "", p)

  if (p == "") next
  if (STRIP != "" && index(p, STRIP "/") == 1) p = substr(p, length(STRIP) + 2)
  if (p == "" || p ~ /\/$/) next        # skip directory entries

  print p TAB n
}
