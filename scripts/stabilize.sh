#!/usr/bin/env bash
# Usage: stabilize.sh <source> <out>
#        stabilize.sh --emit-requirement <identifier> <file>
set -euo pipefail

# Binary form of: designated => identifier "<id>"
# magic(4) length(4) kind(4) opIdent(4) strlen(4) identifier padding
emitRequirement() {
  local LC_ALL=C
  local identifier=$1 file=$2 len pad header="" padding="" word n
  len=${#identifier}
  pad=$(((4 - len % 4) % 4))
  for word in $((0xfade0c00)) $((20 + len + pad)) 1 2 "$len"; do
    header+=$(printf '\\0%03o\\0%03o\\0%03o\\0%03o' \
      $((word >> 24 & 255)) $((word >> 16 & 255)) $((word >> 8 & 255)) $((word & 255)))
  done
  for ((n = 0; n < pad; n++)); do padding+='\0000'; done
  printf '%b%s%b' "$header" "$identifier" "$padding" >"$file"
}

if [ "${1-}" = --emit-requirement ]; then
  emitRequirement "$2" "$3"
  exit 0
fi

source=$1
out=$2
allowUnsupported=${allowUnsupported:-}

unsupported() {
  if [ -n "$allowUnsupported" ]; then
    echo "warning: $1" >&2
    return 0
  fi
  echo "error: $1" >&2
  echo "pass allowUnsupported = true to accept this package unsigned" >&2
  exit 1
}

rsync --archive --copy-unsafe-links "$source/" "$out/"
chmod -R u+w "$out"

# A second copy of a bundle executable outside the bundle is identified by its
# own store path, so a grant made against the bundle does not reach it.
shopt -s nullglob
for app in "$out"/Applications/*.app; do
  for exe in "$app"/Contents/MacOS/*; do
    [ -f "$exe" ] || continue
    for dup in "$out"/bin/*; do
      { [ -f "$dup" ] && [ ! -L "$dup" ]; } || continue
      cmp -s "$exe" "$dup" || continue
      echo "bin/$(basename "$dup"): linking into $(basename "$app"), a second copy would keep its own identity"
      ln -sf "../Applications/$(basename "$app")/Contents/MacOS/$(basename "$exe")" "$dup"
    done
  done
done

repoint() {
  local pattern=${source//./\\.}
  sed -i "s|$pattern|$out|g" "$1"
  if grep -qF "$source" "$1"; then
    echo "error: $1 still names $source after the rewrite" >&2
    exit 1
  fi
}

# Binaries outside the bundle pointing to the old store path could execute the
# unsigned original and cannot be rewritten in place. References inside the
# bundle stay under the new signature and are safe to keep.
escapes=""
while IFS= read -r -d "" f; do
  if grep -qI "" "$f"; then
    repoint "$f"
  elif [[ $f != "$out"/Applications/*.app/* ]]; then
    escapes="$escapes  $f
"
  fi
done < <(grep -rlaZF "$source" "$out" 2>/dev/null || true)

if [ -n "$escapes" ]; then
  echo "error: these binaries name this package's own store path from outside the bundle," >&2
  echo "so they can reach the unsigned original and the path cannot be rewritten in place:" >&2
  printf '%s' "$escapes" >&2
  exit 1
fi

# Converted to XML rather than read where it lies: an Info.plist may be in the
# binary format, which has no text for a reader to match against.
bundleIdentifier() {
  plistutil -i "$1" -f xml -o - |
    xmllint --xpath 'string(//key[.="CFBundleIdentifier"]/following-sibling::string[1])' -
}

apps=("$out"/Applications/*.app)
if [ ${#apps[@]} -eq 0 ]; then
  unsupported "$source has no .app under Applications, so nothing here can be given an identity"
fi

for app in "${apps[@]}"; do
  name=$(basename "$app")
  plist="$app/Contents/Info.plist"

  # Piping rcodesign reports SIGPIPE as a signing failure. Non-zero exit means
  # the bundle is unreadable (unsigned bundles succeed), so do not fall through.
  if ! rcodesign print-signature-info "$app" >info.yaml 2>info.err; then
    echo "error: $name: cannot read the existing signature:" >&2
    cat info.err >&2
    exit 1
  fi

  if grep -q '^ *team_name:' info.yaml; then
    echo "$name: keeping the vendor signature, its requirement is already stable"
    continue
  fi

  # codesign seals everything under Contents/MacOS as code, so a bundle with a
  # script in there cannot be sealed by any signer, rcodesign included.
  unsignable=""
  for f in "$app"/Contents/MacOS/* "$app"/Contents/MacOS/.*; do
    [ -f "$f" ] || continue
    case $(od -An -tx4 -N4 "$f" | tr -d " ") in
    feedfacf | cffaedfe | feedface | cefaedfe | cafebabe | bebafeca) ;;
    *) unsignable="$unsignable $(basename "$f")" ;;
    esac
  done
  if [ -n "$unsignable" ]; then
    unsupported "$name: Contents/MacOS holds files that are not Mach-O:$unsignable"
    continue
  fi

  # rcodesign identifies a bundle by CFBundleIdentifier, so the requirement has
  # to name that and not whatever the existing signature happens to say.
  id=""
  [ -f "$plist" ] && id=$(bundleIdentifier "$plist")
  if [ -z "$id" ]; then
    echo "error: $name has no readable CFBundleIdentifier" >&2
    exit 1
  fi

  emitRequirement "$id" requirement.bin
  echo "$name: signing as \"$id\""
  # Nested bundles under Contents need no separate pass: rcodesign finds them
  # and signs them deepest-first before the outer bundle.
  rcodesign sign --binary-identifier "$id" --code-requirements-file requirement.bin "$app"

  rcodesign print-signature-info "$app" >signed.yaml
  requirement=$(sed -n "s/^ *- 'designated([0-9]*): [0-9]*: \(.*\);'$/\1/p" signed.yaml | head -1)
  if [ "$requirement" != "identifier \"$id\"" ]; then
    echo "error: $name came out under the requirement ${requirement:-<none>}," >&2
    echo "not one naming \"$id\"" >&2
    exit 1
  fi
done
