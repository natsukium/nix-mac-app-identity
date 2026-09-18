#!/usr/bin/env bash
# Usage: appName=<name> identifier=<id> executable=<path> [version=<v>]
#        [mainProgram=<name>] [showInDock=1] [icon=<path>] mk-bundle.sh <out>
set -euo pipefail

out=$1
appName=${appName-}
identifier=${identifier-}
executable=${executable-}
version=${version:-0}
mainProgram=${mainProgram:-$appName}
showInDock=${showInDock:-}
icon=${icon:-}

target=$executable

# makeWrapper leaves a shell script behind, but a bundle's main executable has
# to be the Mach-O that ends up running, or the signature covers the wrong
# thing.
if head -c2 "$target" | grep -q '#!'; then
  # shellcheck disable=SC2016 # the \$0 is sed matching the literal text a wrapper carries
  wrapped=$(sed -n 's/^exec -a "\$0" "\([^"]*\)".*/\1/p' "$target" | head -1)
  if [ -z "$wrapped" ]; then
    echo "error: $target is a script this cannot see through" >&2
    exit 1
  fi
  if [ "$(grep -cvE '^#!|^exec -a|^$' "$target")" -gt 0 ]; then
    echo "error: $target sets up an environment that a bundle cannot carry:" >&2
    grep -vE '^#!|^exec -a|^$' "$target" >&2
    echo "move it into the launchd agent instead" >&2
    exit 1
  fi
  target=$(readlink -f "$wrapped")
fi

# Moving the binary into a bundle breaks @executable_path and @loader_path
# library resolution at runtime.
if otool -l "$target" | grep -q '@executable_path\|@loader_path'; then
  echo "error: $target loads libraries relative to its own location:" >&2
  otool -l "$target" | grep -E '@executable_path|@loader_path' >&2
  echo "a bundle moves it, so those paths would no longer resolve" >&2
  exit 1
fi

app=$out/Applications/$appName.app
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$target" "$app/Contents/MacOS/$appName"
chmod u+w "$app/Contents/MacOS/$appName"
[ -n "$icon" ] && cp "$icon" "$app/Contents/Resources/$appName.icns"

xmlEscape() {
  local text=$1
  text=${text//&/&amp;}
  text=${text//</&lt;}
  text=${text//>/&gt;}
  printf '%s' "$text"
}

xmlName=$(xmlEscape "$appName")
xmlIdentifier=$(xmlEscape "$identifier")
xmlVersion=$(xmlEscape "$version")

optional=""
if [ -n "$icon" ]; then
  optional+="  <key>CFBundleIconFile</key><string>$xmlName</string>
"
fi
if [ -z "$showInDock" ]; then
  optional+="  <key>LSUIElement</key><true/>
"
fi

cat >"$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple Computer//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>$xmlName</string>
  <key>CFBundleIdentifier</key><string>$xmlIdentifier</string>
  <key>CFBundleName</key><string>$xmlName</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleShortVersionString</key><string>$xmlVersion</string>
  <key>CFBundleVersion</key><string>$xmlVersion</string>
$optional</dict>
</plist>
EOF

printf 'APPL????' >"$app/Contents/PkgInfo"

mkdir -p "$out/bin"
ln -s "../Applications/$appName.app/Contents/MacOS/$appName" "$out/bin/$mainProgram"
