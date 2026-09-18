#!/usr/bin/env bash
# Report how TCC identifies a process and what it decided, from the unified log.
# Needs no Full Disk Access.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: tcc-watch [--last DURATION] [FILTER]

Report how TCC identified a process and what it decided, read back from the
unified log. Needs no Full Disk Access.

  --last DURATION  how far back to read, as `log show --last` takes it
                   (default: 5m)
  FILTER           extended regular expression the log lines must match
  -h, --help       print this help
EOF
}

since=5m
filter=.

while [ $# -gt 0 ]; do
  case $1 in
  -h | --help)
    usage
    exit 0
    ;;
  --last)
    [ $# -ge 2 ] || {
      echo "error: --last needs a duration" >&2
      exit 1
    }
    since=$2
    shift 2
    ;;
  --last=*)
    since=${1#--last=}
    shift
    ;;
  --)
    shift
    break
    ;;
  -*)
    echo "error: unknown option $1" >&2
    usage >&2
    exit 1
    ;;
  *)
    break
    ;;
  esac
done

if [ $# -gt 1 ]; then
  echo "error: expected at most one filter, got: $*" >&2
  usage >&2
  exit 1
fi
[ $# -eq 1 ] && filter=$1

log show --last "$since" --predicate 'subsystem == "com.apple.TCC"' --info 2>/dev/null |
  grep -E 'AUTHREQ_ATTRIBUTION|AUTHREQ_SUBJECT|AUTHREQ_RESULT|AUTHREQ_CTX' |
  grep -E -- "$filter" |
  sed -E \
    -e 's/^([0-9-]+ [0-9:.]+)[^ ]* .*AUTHREQ_CTX: msgID=([0-9.]+).*service=([A-Za-z]+).*/\1  [\2] service  \3/' \
    -e 's/^([0-9-]+ [0-9:.]+)[^ ]* .*AUTHREQ_ATTRIBUTION: msgID=([0-9.]+).*accessing=\{TCCDProcess: identifier=([^,]*),[^}]*binary_path=([^}]*)\}.*/\1  [\2] accessor identifier=\3\n                                    binary=\4/' \
    -e 's/^([0-9-]+ [0-9:.]+)[^ ]* .*AUTHREQ_SUBJECT: msgID=([0-9.]+), subject=(.*),$/\1  [\2] subject  \3/' \
    -e 's/^([0-9-]+ [0-9:.]+)[^ ]* .*AUTHREQ_RESULT: msgID=([0-9.]+), authValue=([0-9]+), authReason=([0-9]+).*/\1  [\2] result   authValue=\3 authReason=\4/'
