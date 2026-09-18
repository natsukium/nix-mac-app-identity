#!/usr/bin/env bash
# Print TCC entries with their code requirement decoded back to text.
# Must run from a process that has Full Disk Access.
set -euo pipefail

if [ "${1-}" = --help ] || [ "${1-}" = -h ]; then
  cat <<'EOF'
Usage: tcc-dump [CLIENT]

Print the stored TCC entries with their code requirement decoded back to text.
CLIENT narrows the listing to clients whose name contains it. Must run from a
process that has Full Disk Access.
EOF
  exit 0
fi

db="$HOME/Library/Application Support/com.apple.TCC/TCC.db"
pattern=${1:-}

if ! sqlite3 "$db" 'select 1' >/dev/null 2>&1; then
  echo "cannot read $db" >&2
  echo "grant Full Disk Access to the terminal running this, then restart it" >&2
  exit 1
fi

where="where 1=1"
[ -n "$pattern" ] && where="where client like '%$pattern%'"

tmp=$(mktemp "${TMPDIR:-/tmp}/csreq.XXXXXX")
trap 'rm -f "$tmp"' EXIT

sqlite3 -separator '|' "$db" \
  "select service, client, client_type, auth_value, coalesce(hex(csreq),'') from access $where order by client, service;" |
  while IFS='|' read -r service client ctype auth hex; do
    case "$ctype" in
    0) kind="bundle id" ;;
    1) kind="path     " ;;
    *) kind="type=$ctype" ;;
    esac
    case "$auth" in
    0) verdict=denied ;;
    2) verdict=allowed ;;
    *) verdict="auth=$auth" ;;
    esac

    if [ -n "$hex" ]; then
      printf '%s' "$hex" | xxd -r -p >"$tmp"
      req=$(csreq -r "$tmp" -t 2>/dev/null || echo '<undecodable>')
    else
      req='<none>'
    fi

    printf '%-28s %-34s %s  %-8s %s\n' "${service#kTCCService}" "$client" "$kind" "$verdict" "$req"
  done
