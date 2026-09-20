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

isMachO() {
  case $(od -An -tx4 -N4 "$1" | tr -d " ") in
  feedfacf | cffaedfe | feedface | cefaedfe | cafebabe | bebafeca | cafebabf | bfbafeca) return 0 ;;
  *) return 1 ;;
  esac
}

# rcodesign seals these without signing them, even when they are Mach-O
# (code_resources.rs omit rules and bundle_signing.rs exclusions), so a rewrite
# would leave a signature its bytes no longer match.
notResigned() {
  local app=$1 path=$2 root dir rel
  # The rules are relative to the nearest bundle rcodesign signs on its own.
  root=$app
  dir=$(dirname "$path")
  # rcodesign never takes an app's own Contents for a bundle.
  while [[ $dir == "$app"/* ]]; do
    if [ "$dir" != "$app/Contents" ] && isBundle "$dir"; then
      root=$dir
      break
    fi
    dir=$(dirname "$dir")
  done
  if [ -d "$root/Contents" ]; then
    rel=${path#"$root/Contents/"}
  else
    rel=${path#"$root/"}
  fi
  case $rel in
  .DS_Store | */.DS_Store | Info.plist | PkgInfo | CodeResources | CodeResources/* | _MASReceipt | _MASReceipt/* | _CodeSignature/* | *.lproj/locversion.plist) return 0 ;;
  *) return 1 ;;
  esac
}

insideNestedBundle() {
  local app=$1 dir
  dir=$(dirname "$2")
  while [[ $dir == "$app"/* ]]; do
    [ "$dir" != "$app/Contents" ] && isBundle "$dir" && return 0
    dir=$(dirname "$dir")
  done
  return 1
}

# Converted to XML rather than read where it lies: an Info.plist may be in the
# binary format, which has no text for a reader to match against.
plistString() {
  plistutil -i "$1" -f xml -o - 2>/dev/null |
    xmllint --xpath "string(/plist/dict/key[.=\"$2\"]/following-sibling::*[1][self::string])" - 2>/dev/null
}

# An empty string is still a string to rcodesign, so presence is asked apart.
plistHasString() {
  plistutil -i "$1" -f xml -o - 2>/dev/null |
    xmllint --xpath "/plist/dict/key[.=\"$2\"]/following-sibling::*[1][self::string]" - >/dev/null 2>&1
}

# The test rcodesign itself applies when it discovers nested bundles, which it
# signs on their own under their own identifier. Anything that fails it is a
# plain directory to rcodesign, so it is walked into here too.
isBundle() {
  local plist
  if [ -f "$1/Resources/Info.plist" ]; then
    plist=$1/Resources/Info.plist
  elif [[ $1 == *.framework ]] && [ -f "$1/Info.plist" ]; then
    plist=$1/Info.plist
  elif [ -d "$1/Contents" ]; then
    plist=$1/Contents/Info.plist
  else
    plist=$1/Info.plist
  fi
  [ -f "$plist" ] || return 1
  plistutil -i "$plist" -f xml -o - 2>/dev/null | xmllint --xpath '/plist/dict' - >/dev/null 2>&1 || return 1
  if plistHasString "$plist" CFBundlePackageType; then
    [ "$(plistString "$plist" CFBundlePackageType)" != dSYM ]
  else
    plistHasString "$plist" CFBundleIdentifier
  fi
}

# codesign seals everything under Contents/MacOS as code, so a bundle with a
# script anywhere in there cannot be sealed by any signer, rcodesign included.
scanMacOS() {
  local app=$1 dir entry target
  local -A seen=()
  executables=()
  unsignable=""
  local -a pending=("$app/Contents/MacOS")
  while [ ${#pending[@]} -gt 0 ]; do
    dir=${pending[0]}
    pending=("${pending[@]:1}")
    for entry in "$dir"/* "$dir"/.[!.]* "$dir"/..?*; do
      target=$entry
      if [ -L "$entry" ]; then
        if ! target=$(readlink -f "$entry" 2>/dev/null); then
          unsignable="$unsignable ${entry#"$app/Contents/MacOS/"}"
          continue
        fi
        # A link to a directory could reach code that rcodesign signs under
        # its own identity, so it is not followed; a link into a nested bundle
        # would put this bundle's identity on code signed under that one's.
        if [ -d "$target" ] || [[ $target != "$app"/* ]] || [ ! -f "$target" ] || insideNestedBundle "$app" "$target"; then
          unsignable="$unsignable ${entry#"$app/Contents/MacOS/"}"
          continue
        fi
      fi
      if [ -d "$target" ]; then
        isBundle "$target" || pending+=("$target")
      elif [ -f "$target" ]; then
        # rcodesign reads ':' and '@' in a scoped path as its own syntax, so
        # such a Mach-O cannot be named to it.
        if ! isMachO "$target" || [[ ${target#"$app/"} == *[:@]* ]] || notResigned "$app" "$target"; then
          unsignable="$unsignable ${entry#"$app/Contents/MacOS/"}"
        elif [ -z "${seen[$target]-}" ]; then
          seen[$target]=1
          executables+=("${target#"$app/"}")
        fi
      fi
    done
  done
}

apps=("$out"/Applications/*.app)
if [ ${#apps[@]} -eq 0 ]; then
  unsupported "$source has no .app under Applications, so nothing here can be given an identity"
fi

# Decided before anything is rewritten: a bundle this does not sign, whether it
# keeps a vendor signature or is passed through as unsupported, has to keep
# every byte it came with.
declare -A mode=() identifier=()
for app in "${apps[@]}"; do
  name=$(basename "$app")
  plist="$app/Contents/Info.plist"

  # Only the main executable says who signed the app: a bundled framework may
  # carry its own vendor's signature over an app that is otherwise ad-hoc. A
  # main executable that is not a Mach-O carries no signature of its own, so
  # the bundle as a whole is asked instead.
  signed=$app
  main=""
  [ -f "$plist" ] && main=$(plistString "$plist" CFBundleExecutable)
  if [ -n "$main" ] && [ -f "$app/Contents/MacOS/$main" ] && isMachO "$app/Contents/MacOS/$main"; then
    signed="$app/Contents/MacOS/$main"
  fi
  # Piping rcodesign reports SIGPIPE as a signing failure. Non-zero exit means
  # the file is unreadable (unsigned ones succeed), so do not fall through.
  if ! rcodesign print-signature-info "$signed" >info.yaml 2>info.err; then
    echo "error: $name: cannot read the existing signature:" >&2
    cat info.err >&2
    exit 1
  fi
  if grep -q '^ *team_name:' info.yaml; then
    mode[$app]=vendor
    continue
  fi
  scanMacOS "$app"
  if [ -n "$unsignable" ]; then
    unsupported "$name: Contents/MacOS holds files that are not Mach-O:$unsignable"
    mode[$app]=unsupported
    continue
  fi

  # rcodesign identifies a bundle by CFBundleIdentifier, so the requirement has
  # to name that and not whatever the existing signature happens to say.
  id=""
  [ -f "$plist" ] && id=$(plistString "$plist" CFBundleIdentifier)
  if [ -z "$id" ]; then
    echo "error: $name has no readable CFBundleIdentifier" >&2
    exit 1
  fi
  # The rewrite below repoints the plist, but an identity that names a store
  # path is the instability this exists to remove, not one to carry over.
  if [[ $id == *"$source"* ]]; then
    echo "error: $name: CFBundleIdentifier names $source, so it cannot be a stable identity" >&2
    exit 1
  fi
  identifier[$app]=$id
  mode[$app]=sign
done

# Looked up rather than read off the path: the output itself may be named
# <App>.app, so the first ".app/" in a path is not the bundle.
appOf() {
  local app
  for app in "${apps[@]}"; do
    [[ $1 == "$app"/* ]] && printf '%s' "$app" && return 0
  done
  return 1
}

leftAlone() {
  local app
  for app in "${!mode[@]}"; do
    [[ ${mode[$app]} != sign && $1 == "$app"/* ]] && return 0
  done
  return 1
}

repoint() {
  SOURCE=$source OUT=$out perl -0777 -pi -e 's/\Q$ENV{SOURCE}\E/$ENV{OUT}/g' "$1"
  if grep -qaF "$source" "$1"; then
    echo "error: $1 still names $source after the rewrite" >&2
    exit 1
  fi
}

# Binaries outside the bundle pointing to the old store path could execute the
# unsigned original, and nothing re-signs them after a rewrite. A Mach-O inside
# a bundle this signs is rebuilt by rcodesign afterwards, so it can be
# rewritten, but it cannot grow, so the two paths have to match in length. Any
# other binary file keeps whatever internal checksums it has and is left as it
# is.
escapes=""
unrewritable=""
sealedOnly=""
while IFS= read -r -d "" f; do
  app=$(appOf "$f" || true)
  if leftAlone "$f"; then
    continue
  elif grep -qI "" "$f"; then
    repoint "$f"
  elif [ -z "$app" ]; then
    escapes="$escapes  $f
"
  elif ! isMachO "$f"; then
    continue
  elif notResigned "$app" "$f"; then
    sealedOnly="$sealedOnly  $f
"
  elif [ ${#source} -eq ${#out} ]; then
    repoint "$f"
  else
    unrewritable="$unrewritable  $f
"
  fi
done < <(grep -rlaZF "$source" "$out" 2>/dev/null || true)

failed=""
if [ -n "$escapes" ]; then
  echo "error: these binaries name this package's own store path from outside the bundle," >&2
  echo "so they can reach the unsigned original and the path cannot be rewritten in place:" >&2
  printf '%s' "$escapes" >&2
  failed=1
fi
if [ -n "$unrewritable" ]; then
  echo "error: these binaries name $source, which cannot be rewritten in place to $out" >&2
  echo "because the two differ in length:" >&2
  printf '%s' "$unrewritable" >&2
  failed=1
fi
if [ -n "$sealedOnly" ]; then
  echo "error: these binaries name $source but sit where rcodesign seals without signing," >&2
  echo "so a rewrite would leave a signature their bytes no longer match:" >&2
  printf '%s' "$sealedOnly" >&2
  failed=1
fi
[ -z "$failed" ] || exit 1

for app in "${apps[@]}"; do
  name=$(basename "$app")

  case ${mode[$app]} in
  vendor)
    echo "$name: keeping the vendor signature, its requirement is already stable"
    continue
    ;;
  unsupported)
    continue
    ;;
  esac
  id=${identifier[$app]}

  emitRequirement "$id" requirement.bin
  echo "$name: signing as \"$id\""
  # A wrapper in Contents/MacOS execs a sibling, and the kernel holds that
  # sibling, so every Mach-O there needs the bundle's identity. Nested
  # Mach-Os inherit neither identifier nor requirement from the main scope.
  scanMacOS "$app"
  scoped=()
  for exe in "${executables[@]}"; do
    scoped+=(--binary-identifier "$exe:$id" --code-requirements-file "$exe:$PWD/requirement.bin")
  done
  rcodesign sign --binary-identifier "$id" --code-requirements-file requirement.bin "${scoped[@]}" "$app"

  for exe in "${executables[@]}"; do
    rcodesign print-signature-info "$app/$exe" >signed.yaml
    requirement=$(sed -n "s/^ *- 'designated([0-9]*): [0-9]*: \(.*\);'$/\1/p" signed.yaml | head -1)
    if [ "$requirement" != "identifier \"$id\"" ]; then
      echo "error: $name/$exe came out under the requirement ${requirement:-<none>}," >&2
      echo "not one naming \"$id\"" >&2
      exit 1
    fi
  done
done
