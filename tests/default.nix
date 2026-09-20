{
  lib,
  cctools,
  libplist,
  libxml2,
  makeBinaryWrapper,
  mkAppBundle,
  perl,
  rcodesign,
  rsync,
  runCommand,
  runCommandCC,
  shellcheck,
  stabilizeApp,
  writeScript,
}:

let
  scriptTools = [
    libplist.bin
    libxml2.bin
    perl
    rcodesign
    rsync
  ];

  infoPlist =
    {
      executable,
      identifier ? null,
      packageType ? null,
    }:
    lib.concatStrings (
      [
        ''<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>''
        "<key>CFBundleExecutable</key><string>${executable}</string>"
      ]
      ++ lib.optional (identifier != null) "<key>CFBundleIdentifier</key><string>${identifier}</string>"
      ++ lib.optional (
        packageType != null
      ) "<key>CFBundlePackageType</key><string>${packageType}</string>"
      ++ [ "</dict></plist>" ]
    );

  # Shaped like the packages this signs: one bundle under Applications holding a
  # real Mach-O. `marker` changes the executable's bytes without touching
  # anything the requirement is supposed to name. Every switch below adds one
  # shape a real bundle can have, so a check can name the one it is about.
  mkPkg =
    {
      name,
      identifier ? null,
      marker ? 0,
      selfReference ? false,
      escapingBinary ? false,
      scriptExecutable ? false,
      duplicateInBin ? false,
      binaryPlist ? false,
      identifierNamesSource ? false,
      binaryWrapper ? false,
      nestedHelper ? false,
      binaryResource ? false,
      nestedBundle ? false,
      nestedPkgInfo ? false,
      linkIntoNestedBundle ? false,
      brokenBundle ? false,
      emptyIdentifierBundle ? false,
      shallowFramework ? false,
      rootBundle ? false,
      rootBundleLink ? false,
      nakedPlist ? false,
      nonStringPackageType ? false,
      colonName ? false,
      dotDotExecutable ? false,
      linkedHelper ? false,
      linkedDirectory ? false,
      danglingLink ? false,
      dsStoreResource ? false,
      dsStoreMacOS ? false,
      masReceipt ? false,
      locversion ? false,
      groupedApp ? false,
      teamSigned ? null,
    }:
    let
      needsHelper = lib.any (x: x) [
        nestedHelper
        nestedBundle
        nestedPkgInfo
        brokenBundle
        emptyIdentifierBundle
        shallowFramework
        rootBundle
        nakedPlist
        nonStringPackageType
        colonName
        dotDotExecutable
        linkedHelper
        dsStoreResource
        dsStoreMacOS
        masReceipt
        locversion
        groupedApp
        (teamSigned == "helper")
      ];
    in
    runCommandCC "test-pkg-${name}"
      {
        nativeBuildInputs =
          lib.optional binaryPlist libplist.bin
          ++ lib.optional binaryWrapper makeBinaryWrapper
          ++ lib.optional (teamSigned != null) rcodesign;
      }
      ''
        app=$out/Applications/${name}.app
        mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

        ${
          if scriptExecutable then
            ''
              printf '#!/bin/sh\nexit 0\n' > "$app/Contents/MacOS/${name}"
              chmod +x "$app/Contents/MacOS/${name}"
            ''
          else
            ''
              printf 'const char *p = "%s";\nint main(void){return p[0] * 0 + %d;}\n' \
                "${if selfReference then "$out" else "none"}" ${toString marker} > main.c
              cc -o "$app/Contents/MacOS/${name}" main.c
            ''
        }

        printf '%s\n' ${
          lib.concatMapStringsSep " " (line: "'${line}'") (
            [
              ''<?xml version="1.0" encoding="UTF-8"?>''
              ''<plist version="1.0">''
              "<dict>"
              "  <key>CFBundleExecutable</key><string>${name}</string>"
            ]
            ++ lib.optional (identifier != null) "  <key>CFBundleIdentifier</key><string>${identifier}</string>"
            ++ [
              "  <key>CFBundleName</key><string>${name}</string>"
              "  <key>CFBundlePackageType</key><string>APPL</string>"
              "</dict>"
              "</plist>"
            ]
          )
        } > "$app/Contents/Info.plist"

        ${lib.optionalString identifierNamesSource ''
          sed -i "s|@SOURCE@|$out|" "$app/Contents/Info.plist"
        ''}

        ${lib.optionalString binaryPlist ''
          plistutil -i "$app/Contents/Info.plist" -f bin -o Info.bin
          mv Info.bin "$app/Contents/Info.plist"
        ''}

        ${lib.optionalString needsHelper ''
          printf 'const char *p = "%s";\nint main(void){return p[0] * 0;}\n' "$out" > helper.c
          cc -o helper helper.c
        ''}

        ${lib.optionalString nestedHelper ''
          mkdir -p "$app/Contents/MacOS/helpers"
          cp helper "$app/Contents/MacOS/helpers/tool"
        ''}

        ${lib.optionalString dotDotExecutable ''
          cp helper "$app/Contents/MacOS/..dotdot"
        ''}

        ${lib.optionalString linkedHelper ''
          cp helper "$app/Contents/Resources/realhelper"
          ln -s ../Resources/realhelper "$app/Contents/MacOS/linked"
        ''}

        ${lib.optionalString linkedDirectory ''
          ln -s ../Resources "$app/Contents/MacOS/linkdir"
        ''}

        ${lib.optionalString danglingLink ''
          ln -s missing/target "$app/Contents/MacOS/broken"
        ''}

        ${lib.optionalString colonName ''
          cp helper "$app/Contents/MacOS/a:b"
        ''}

        ${lib.optionalString binaryResource ''
          printf 'PK\0\0%s\0\0stored' "$out/Applications" > "$app/Contents/Resources/blob.bin"
        ''}

        ${lib.optionalString nestedBundle ''
          plug=$app/Contents/MacOS/Extra.plugin
          mkdir -p "$plug/Contents/MacOS"
          cp helper "$plug/Contents/MacOS/Extra"
          printf '%s' '${
            infoPlist {
              executable = "Extra";
              identifier = "com.example.plugin";
            }
          }' > "$plug/Contents/Info.plist"
        ''}

        ${lib.optionalString nestedPkgInfo ''
          cp helper "$app/Contents/MacOS/Extra.plugin/Contents/PkgInfo"
        ''}

        ${lib.optionalString linkIntoNestedBundle ''
          ln -s Extra.plugin/Contents/MacOS/Extra "$app/Contents/MacOS/toplugin"
        ''}

        ${lib.optionalString brokenBundle ''
          broken=$app/Contents/MacOS/Broken.bundle
          mkdir -p "$broken/Contents/MacOS"
          cp helper "$broken/Contents/MacOS/Broken"
          printf 'not a plist' > "$broken/Contents/Info.plist"
        ''}

        ${lib.optionalString emptyIdentifierBundle ''
          empty=$app/Contents/MacOS/Empty.plugin
          mkdir -p "$empty/Contents/MacOS"
          cp helper "$empty/Contents/MacOS/Empty"
          printf '%s' '${
            infoPlist {
              executable = "Empty";
              identifier = "";
            }
          }' > "$empty/Contents/Info.plist"
        ''}

        ${lib.optionalString shallowFramework ''
          framework=$app/Contents/MacOS/Shallow.framework
          mkdir -p "$framework/Contents"
          cp helper "$framework/Contents/Shallow"
          printf '%s' '${
            infoPlist {
              executable = "Contents/Shallow";
              identifier = "com.example.shallow";
              packageType = "FMWK";
            }
          }' > "$framework/Info.plist"
        ''}

        ${lib.optionalString rootBundle ''
          root=$app/Root.plugin
          mkdir -p "$root/Contents/MacOS"
          cp helper "$root/Contents/MacOS/Root"
          cp helper "$root/Contents/PkgInfo"
          printf '%s' '${
            infoPlist {
              executable = "Root";
              identifier = "com.example.root";
            }
          }' > "$root/Contents/Info.plist"
        ''}

        ${lib.optionalString rootBundleLink ''
          ln -s ../../Root.plugin/Contents/MacOS/Root "$app/Contents/MacOS/toroot"
        ''}

        ${lib.optionalString nakedPlist ''
          printf '%s' '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict></dict></plist>' \
            > "$app/Contents/MacOS/helpers/Info.plist"
        ''}

        ${lib.optionalString nonStringPackageType ''
          printf '%s' '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundlePackageType</key><true/><key>CFBundleName</key><string>helpers</string></dict></plist>' \
            > "$app/Contents/MacOS/helpers/Info.plist"
        ''}

        ${lib.optionalString dsStoreResource ''
          cp helper "$app/Contents/Resources/.DS_Store"
        ''}

        ${lib.optionalString dsStoreMacOS ''
          cp helper "$app/Contents/MacOS/.DS_Store"
        ''}

        ${lib.optionalString masReceipt ''
          mkdir -p "$app/Contents/_MASReceipt"
          cp helper "$app/Contents/_MASReceipt/receipt"
        ''}

        ${lib.optionalString locversion ''
          mkdir -p "$app/Contents/en.lproj"
          cp helper "$app/Contents/en.lproj/locversion.plist"
        ''}

        ${lib.optionalString groupedApp ''
          other=$out/Applications/group/Other.app
          mkdir -p "$other/Contents/MacOS"
          cp helper "$other/Contents/MacOS/Other"
          printf '%s' '${
            infoPlist {
              executable = "Other";
              identifier = "com.example.other";
            }
          }' > "$other/Contents/Info.plist"
        ''}

        ${lib.optionalString duplicateInBin ''
          mkdir -p $out/bin
          cp "$app/Contents/MacOS/${name}" "$out/bin/${name}"
        ''}

        ${lib.optionalString escapingBinary ''
          mkdir -p $out/bin
          printf 'const char *p = "%s";\nint main(void){return p[0] * 0;}\n' "$out" > escape.c
          cc -o $out/bin/escape escape.c
        ''}

        ${lib.optionalString binaryWrapper ''
          wrapProgram "$app/Contents/MacOS/${name}" --set MARKER 1
        ''}

        ${lib.optionalString (teamSigned != null) ''
          rcodesign sign --timestamp-url none --signing-time 2026-01-01T00:00:00Z \
            --pem-file ${./team.pem} --team-name TEAMID1234 \
            ${
              if teamSigned == "main" then
                ''"$app/Contents/MacOS/${name}"''
              else
                ''"$app/Contents/MacOS/helpers/tool"''
            }
        ''}
      '';

  # rcodesign decodes the stored requirement back to the text form csreq -t
  # prints, so a check can assert on what a reader would see rather than on a
  # blob.
  designated = ''
    designated() {
      rcodesign print-signature-info "$1" \
        | sed -n "s/^ *- 'designated([0-9]*): [0-9]*: \(.*\);'$/\1/p" \
        | head -1
    }
  '';

  codeIdentifier = ''
    codeIdentifier() {
      rcodesign print-signature-info "$1" | sed -n "s/^ *identifier: //p" | head -1
    }
  '';

  # Asserts the requirement a reader would see for one file, so every check that
  # names a Mach-O inside a bundle says the same thing about it.
  requiresIdentifier = ''
    ${designated}
    requiresIdentifier() {
      local got want
      got=$(designated "$1")
      want="identifier \"$2\""
      if [ "$got" != "$want" ]; then
        echo "expected $1 to be signed under: $want" >&2
        echo "but it decoded to: $got" >&2
        exit 1
      fi
    }
  '';

  # A refusal has no passing form to build, so it is driven from a check that
  # runs the script itself and requires both a failure and the stated reasons: a
  # refusal raised for a different reason is its own regression.
  refusesToStabilize =
    {
      name,
      reason,
      pkg,
      outName ? "stabilized",
    }:
    runCommand "check-stabilize-refuses-${name}"
      {
        nativeBuildInputs = scriptTools;
      }
      ''
        if bash ${../scripts/stabilize.sh} ${pkg} "$PWD/${outName}" > stdout.log 2> stderr.log; then
          echo "the build succeeded, expected it to be refused" >&2
          exit 1
        fi
        for want in ${lib.escapeShellArgs (lib.toList reason)}; do
          if ! grep -qF "$want" stderr.log; then
            echo "refused, but not for $want:" >&2
            cat stderr.log >&2
            exit 1
          fi
        done
        touch $out
      '';

  # The identifier's length decides how much padding the requirement blob needs,
  # and a blob that miscounts it does not survive being parsed back.
  paddingCase =
    suffix:
    let
      name = "Pad${lib.toUpper suffix}";
      identifier = "com.example.${suffix}";
      stabilized = stabilizeApp (mkPkg {
        inherit name identifier;
      });
    in
    runCommand "check-requirement-names-${identifier}"
      {
        nativeBuildInputs = [ rcodesign ];
      }
      ''
        ${requiresIdentifier}
        requiresIdentifier "${stabilized}/Applications/${name}.app" "${identifier}"
        touch $out
      '';

  # A refusal has no passing form to build either, so it runs the script the same
  # way, against an executable a bundle cannot honestly carry.
  refusesToBundle =
    {
      name,
      reason,
      executable,
    }:
    runCommand "check-bundle-refuses-${name}"
      {
        inherit executable;
        appName = "Refused";
        identifier = "com.example.refused";
        nativeBuildInputs = [ cctools ];
      }
      ''
        if bash ${../scripts/mk-bundle.sh} "$PWD/bundle" > stdout.log 2> stderr.log; then
          echo "the bundle was built, expected it to be refused" >&2
          exit 1
        fi
        if ! grep -qF ${lib.escapeShellArg reason} stderr.log; then
          echo "refused, but not for ${reason}:" >&2
          cat stderr.log >&2
          exit 1
        fi
        touch $out
      '';

  daemon = runCommandCC "test-daemon-1.2" { meta.mainProgram = "daemon"; } ''
    mkdir -p $out/bin
    printf 'int main(void){return 0;}\n' > main.c
    cc -o $out/bin/daemon main.c
  '';

  # One bundle carrying every shape that has to end up under the app's own
  # identity: the makeBinaryWrapper stub and its target, a helper in a
  # subdirectory, a dot-dot name, a link out to Resources, and a nested bundle
  # that keeps its own.
  wrappedPkg = mkPkg {
    name = "Wrapped";
    identifier = "com.example.wrapped";
    binaryWrapper = true;
    nestedHelper = true;
    nestedBundle = true;
    dotDotExecutable = true;
    linkedHelper = true;
  };
  wrappedStabilized = stabilizeApp wrappedPkg;

  longName = "test-pkg-" + lib.concatStrings (lib.replicate 66 "abc");
  longNamePkg =
    runCommand longName
      {
        outputs = [
          "out"
          "bin"
        ];
      }
      ''
        mkdir -p "$out/Applications" "$bin"
      '';
in
{
  shellcheck =
    runCommand "check-shellcheck"
      {
        nativeBuildInputs = [ shellcheck ];
      }
      ''
        shellcheck ${../scripts}/*.sh
        touch $out
      '';

  requirement-names-the-identifier-len1 = paddingCase "a";
  requirement-names-the-identifier-len2 = paddingCase "ab";
  requirement-names-the-identifier-len3 = paddingCase "abc";
  requirement-names-the-identifier-len0 = paddingCase "abcd";

  identifier-is-read-from-a-binary-plist =
    let
      name = "Binary";
      identifier = "com.example.binary";
      pkg = mkPkg {
        inherit name identifier;
        binaryPlist = true;
      };
      stabilized = stabilizeApp pkg;
    in
    runCommand "check-identifier-is-read-from-a-binary-plist"
      {
        nativeBuildInputs = [ rcodesign ];
      }
      ''
        # Guards the fixture: read out of an XML plist this check proves nothing.
        if [ "$(head -c8 "${pkg}/Applications/${name}.app/Contents/Info.plist")" != bplist00 ]; then
          echo "the fixture Info.plist is not in the binary format" >&2
          exit 1
        fi

        ${requiresIdentifier}
        requiresIdentifier "${stabilized}/Applications/${name}.app" "${identifier}"
        touch $out
      '';

  requirement-survives-a-content-change =
    let
      pkg =
        marker:
        mkPkg {
          name = "Stable";
          identifier = "com.example.stable";
          inherit marker;
        };
      a = stabilizeApp (pkg 0);
      b = stabilizeApp (pkg 1);
    in
    runCommand "check-requirement-survives-a-content-change"
      {
        nativeBuildInputs = [ rcodesign ];
      }
      ''
        ${requiresIdentifier}
        exe=Contents/MacOS/Stable
        if cmp -s "${a}/Applications/Stable.app/$exe" "${b}/Applications/Stable.app/$exe"; then
          echo "the two builds are byte-identical, so this proves nothing" >&2
          exit 1
        fi

        # Comparing the two against each other is not enough: a build that wrote
        # no designated requirement at all gives two empty strings that match.
        for app in "${a}" "${b}"; do
          requiresIdentifier "$app/Applications/Stable.app" com.example.stable
        done
        touch $out
      '';

  wrapped-executable-is-signed-under-the-identifier =
    runCommand "check-wrapped-executable-is-signed-under-the-identifier"
      {
        nativeBuildInputs = [ rcodesign ];
      }
      ''
        src="${wrappedPkg}/Applications/Wrapped.app"
        app="${wrappedStabilized}/Applications/Wrapped.app"

        # Guards the fixture: without a wrapper stub execing a hidden sibling,
        # nothing here is the case the check is about.
        if [ ! -f "$src/Contents/MacOS/.Wrapped-wrapped" ]; then
          echo "the fixture carries no wrapped executable behind a makeBinaryWrapper stub" >&2
          exit 1
        fi

        ${requiresIdentifier}
        ${codeIdentifier}
        requiresIdentifier "$app/Contents/MacOS/.Wrapped-wrapped" com.example.wrapped

        # Unscoped, rcodesign names a nested Mach-O after its own file, which is
        # what the wrapped executable was identified by before it was given a scope.
        got=$(codeIdentifier "$app/Contents/MacOS/.Wrapped-wrapped")
        if [ "$got" != com.example.wrapped ]; then
          echo "expected the wrapped executable to be signed as com.example.wrapped, got: $got" >&2
          exit 1
        fi

        if grep -rlaF "${wrappedPkg}" "${wrappedStabilized}"; then
          echo "the files above still name the unsigned source, so the stub execs into it" >&2
          exit 1
        fi
        if ! grep -qaF "$app/Contents/MacOS/.Wrapped-wrapped" "$app/Contents/MacOS/Wrapped"; then
          echo "the stub does not name the stabilized .Wrapped-wrapped" >&2
          exit 1
        fi

        "$app/Contents/MacOS/Wrapped"
        touch $out
      '';

  nested-helper-is-signed-under-the-identifier =
    runCommand "check-nested-helper-is-signed-under-the-identifier"
      {
        nativeBuildInputs = [ rcodesign ];
      }
      ''
        app="${wrappedStabilized}/Applications/Wrapped.app"
        ${requiresIdentifier}
        requiresIdentifier "$app/Contents/MacOS/helpers/tool" com.example.wrapped
        grep -qaF "${wrappedStabilized}" "$app/Contents/MacOS/helpers/tool"
        "$app/Contents/MacOS/helpers/tool"
        touch $out
      '';

  dot-dot-and-linked-helpers-are-signed-under-the-identifier =
    runCommand "check-dot-dot-and-linked-helpers-are-signed-under-the-identifier"
      {
        nativeBuildInputs = [ rcodesign ];
      }
      ''
        app="${wrappedStabilized}/Applications/Wrapped.app"
        ${requiresIdentifier}
        requiresIdentifier "$app/Contents/MacOS/..dotdot" com.example.wrapped
        requiresIdentifier "$app/Contents/Resources/realhelper" com.example.wrapped
        "$app/Contents/MacOS/linked"
        touch $out
      '';

  nested-bundle-keeps-its-own-identifier =
    runCommand "check-nested-bundle-keeps-its-own-identifier"
      {
        nativeBuildInputs = [ rcodesign ];
      }
      ''
        ${codeIdentifier}
        got=$(codeIdentifier "${wrappedStabilized}/Applications/Wrapped.app/Contents/MacOS/Extra.plugin/Contents/MacOS/Extra")
        if [ "$got" != com.example.plugin ]; then
          echo "a nested bundle is signed by rcodesign under its own identifier," >&2
          echo "but Extra came out as: $got" >&2
          exit 1
        fi
        touch $out
      '';

  binary-resource-is-left-alone =
    let
      pkg = mkPkg {
        name = "Resourced";
        identifier = "com.example.resourced";
        binaryResource = true;
      };
      stabilized = stabilizeApp pkg;
    in
    runCommand "check-binary-resource-is-left-alone" { } ''
      # A format with its own checksums is corrupted by a byte rewrite and the
      # outer seal cannot repair it, so it has to come through untouched.
      cmp "${stabilized}/Applications/Resourced.app/Contents/Resources/blob.bin" \
          "${pkg}/Applications/Resourced.app/Contents/Resources/blob.bin"
      touch $out
    '';

  empty-identifier-bundle-is-left-to-rcodesign =
    let
      stabilized = stabilizeApp (mkPkg {
        name = "Hosting";
        identifier = "com.example.hosting";
        emptyIdentifierBundle = true;
      });
    in
    runCommand "check-empty-identifier-bundle-is-left-to-rcodesign"
      {
        nativeBuildInputs = [ rcodesign ];
      }
      ''
        app="${stabilized}/Applications/Hosting.app"
        ${requiresIdentifier}
        ${codeIdentifier}
        requiresIdentifier "$app/Contents/MacOS/Hosting" com.example.hosting

        # An empty CFBundleIdentifier is still one to rcodesign, so the
        # directory is a nested bundle it signs rather than a tree to scope.
        got=$(codeIdentifier "$app/Contents/MacOS/Empty.plugin/Contents/MacOS/Empty")
        if [ "$got" != "'''" ]; then
          echo "expected rcodesign to sign Empty under an empty identifier, got: $got" >&2
          exit 1
        fi
        touch $out
      '';

  shallow-framework-is-left-to-rcodesign =
    let
      stabilized = stabilizeApp (mkPkg {
        name = "Framed";
        identifier = "com.example.framed";
        binaryWrapper = true;
        shallowFramework = true;
      });
    in
    runCommand "check-shallow-framework-is-left-to-rcodesign"
      {
        nativeBuildInputs = [ rcodesign ];
      }
      ''
        ${requiresIdentifier}
        requiresIdentifier "${stabilized}/Applications/Framed.app/Contents/MacOS/.Framed-wrapped" com.example.framed
        touch $out
      '';

  vendor-signature-is-judged-by-the-main-executable =
    let
      stabilized = stabilizeApp (mkPkg {
        name = "Mixed";
        identifier = "com.example.mixed";
        binaryWrapper = true;
        nestedHelper = true;
        teamSigned = "helper";
      });
    in
    runCommand "check-vendor-signature-is-judged-by-the-main-executable"
      {
        nativeBuildInputs = [ rcodesign ];
      }
      ''
        # A helper carrying someone else's team signature must not make the app
        # look vendor-signed and leave its wrapper at a cdhash requirement.
        ${requiresIdentifier}
        requiresIdentifier "${stabilized}/Applications/Mixed.app/Contents/MacOS/.Mixed-wrapped" com.example.mixed
        touch $out
      '';

  vendor-signed-app-is-left-untouched =
    let
      pkg = mkPkg {
        name = "Vendored";
        identifier = "com.example.vendored";
        selfReference = true;
        teamSigned = "main";
      };
      stabilized = stabilizeApp pkg;
    in
    runCommand "check-vendor-signed-app-is-left-untouched" { } ''
      src="${pkg}/Applications/Vendored.app"
      app="${stabilized}/Applications/Vendored.app"
      cd "$app/Contents/MacOS"
      find . -type f -print0 | while IFS= read -r -d "" f; do
        cmp "$f" "$src/Contents/MacOS/$f"
      done
      # The bytes under a vendor signature have to stay the ones it was made
      # over, so even a self-reference is kept rather than repointed.
      grep -qaF "${pkg}" "$app/Contents/MacOS/Vendored"
      touch $out
    '';

  script-in-macos-is-left-alone-when-unsupported-is-allowed =
    let
      pkg = mkPkg {
        name = "Scripted";
        identifier = "com.example.scripted";
        scriptExecutable = true;
        selfReference = true;
        nestedHelper = true;
      };
      stabilized = stabilizeApp {
        package = pkg;
        allowUnsupported = true;
      };
    in
    runCommand "check-script-in-macos-is-left-alone" { } ''
      src="${pkg}/Applications/Scripted.app"
      app="${stabilized}/Applications/Scripted.app"
      if [ -e "$app/Contents/_CodeSignature" ]; then
        echo "a bundle whose Contents/MacOS holds a script cannot be sealed by any" >&2
        echo "signer, so it must come through untouched rather than half-signed" >&2
        exit 1
      fi
      cd "$app/Contents/MacOS"
      find . -type f -print0 | while IFS= read -r -d "" f; do
        cmp "$f" "$src/Contents/MacOS/$f"
      done
      touch $out
    '';

  identifier-less-script-bundle-is-passed-through =
    let
      pkg = mkPkg {
        name = "Anonscript";
        scriptExecutable = true;
      };
      stabilized = stabilizeApp {
        package = pkg;
        allowUnsupported = true;
      };
    in
    runCommand "check-identifier-less-script-bundle-is-passed-through" { } ''
      app="${stabilized}/Applications/Anonscript.app"
      # The identifier is only required of a bundle that gets signed, so a
      # passed-through one must not be refused for missing it.
      if [ -e "$app/Contents/_CodeSignature" ]; then
        echo "expected the bundle to come through unsigned" >&2
        exit 1
      fi
      cmp "$app/Contents/MacOS/Anonscript" \
          "${pkg}/Applications/Anonscript.app/Contents/MacOS/Anonscript"
      touch $out
    '';

  unresolvable-link-is-passed-through-when-unsupported-is-allowed =
    let
      stabilized = stabilizeApp {
        package = mkPkg {
          name = "Dangling";
          identifier = "com.example.dangling";
          danglingLink = true;
        };
        allowUnsupported = true;
      };
    in
    runCommand "check-unresolvable-link-is-passed-through" { } ''
      app="${stabilized}/Applications/Dangling.app"
      if [ -e "$app/Contents/_CodeSignature" ]; then
        echo "expected the bundle to come through unsigned" >&2
        exit 1
      fi
      if [ "$(readlink "$app/Contents/MacOS/broken")" != missing/target ]; then
        echo "the link was not kept as it was" >&2
        exit 1
      fi
      touch $out
    '';

  duplicate-bin-entry-becomes-a-link =
    let
      stabilized = stabilizeApp (mkPkg {
        name = "Duped";
        identifier = "com.example.duped";
        duplicateInBin = true;
      });
    in
    runCommand "check-duplicate-bin-entry-becomes-a-link" { } ''
      link="${stabilized}/bin/Duped"
      if [ ! -L "$link" ]; then
        echo "bin/Duped stayed a copy; a second copy of the bundle executable is" >&2
        echo "identified by its own store path, so the grant would not reach it" >&2
        exit 1
      fi
      target=$(readlink "$link")
      want=../Applications/Duped.app/Contents/MacOS/Duped
      if [ "$target" != "$want" ]; then
        echo "bin/Duped links to $target, expected $want" >&2
        exit 1
      fi
      touch $out
    '';

  self-referencing-duplicate-is-not-an-escape =
    let
      stabilized = stabilizeApp (mkPkg {
        name = "Selfref";
        identifier = "com.example.selfref";
        selfReference = true;
        duplicateInBin = true;
      });
    in
    runCommand "check-self-referencing-duplicate-is-not-an-escape" { } ''
      # A duplicate binary in bin/ pointing to the old store path becomes a symlink,
      # so it should not be treated as an illegal escape reference.
      link="${stabilized}/bin/Selfref"
      if [ ! -L "$link" ]; then
        echo "bin/Selfref stayed a copy" >&2
        exit 1
      fi
      touch $out
    '';

  long-output-name-is-refused-at-eval =
    let
      acceptsOut = (builtins.tryEval (stabilizeApp longNamePkg).outPath).success;
      acceptsBin = (builtins.tryEval (stabilizeApp longNamePkg.bin).outPath).success;
    in
    assert lib.assertMsg (lib.stringLength longName == 207)
      "the fixture name is ${toString (lib.stringLength longName)} characters, not the 207 this is about";
    assert lib.assertMsg acceptsOut "a 207-character output name has to be accepted";
    assert lib.assertMsg (
      !acceptsBin
    ) "a 211-character output name cannot be reproduced, so it has to be refused at eval time";
    runCommand "check-long-output-name-is-refused-at-eval" { } "touch $out";

  stabilize-refuses-an-escaping-binary = refusesToStabilize {
    name = "an-escaping-binary";
    reason = "name this package's own store path from outside the bundle";
    pkg = mkPkg {
      name = "Escape";
      identifier = "com.example.escape";
      escapingBinary = true;
    };
  };

  stabilize-refuses-a-bundle-without-an-identifier = refusesToStabilize {
    name = "a-bundle-without-an-identifier";
    reason = "has no readable CFBundleIdentifier";
    pkg = mkPkg { name = "Anon"; };
  };

  stabilize-refuses-an-identifier-that-names-the-source = refusesToStabilize {
    name = "an-identifier-that-names-the-source";
    reason = "CFBundleIdentifier names";
    pkg = mkPkg {
      name = "Selfid";
      identifier = "com.example.@SOURCE@";
      identifierNamesSource = true;
    };
  };

  stabilize-refuses-a-script-in-macos = refusesToStabilize {
    name = "a-script-in-macos";
    reason = "Contents/MacOS holds files that are not Mach-O";
    pkg = mkPkg {
      name = "Scripted";
      identifier = "com.example.scripted";
      scriptExecutable = true;
    };
  };

  stabilize-refuses-a-package-without-an-app = refusesToStabilize {
    name = "a-package-without-an-app";
    reason = "has no .app under Applications";
    pkg = daemon;
  };

  stabilize-refuses-a-bundle-reference-when-lengths-differ = refusesToStabilize {
    name = "a-bundle-reference-when-lengths-differ";
    reason = "differ in length";
    pkg = mkPkg {
      name = "Lengths";
      identifier = "com.example.lengths";
      selfReference = true;
    };
  };

  stabilize-refuses-a-broken-nested-bundle = refusesToStabilize {
    name = "a-broken-nested-bundle";
    reason = "not Mach-O: Broken.bundle/Contents/Info.plist";
    pkg = mkPkg {
      name = "Brokenhost";
      identifier = "com.example.brokenhost";
      brokenBundle = true;
    };
  };

  stabilize-refuses-a-naked-plist-under-macos = refusesToStabilize {
    name = "a-naked-plist-under-macos";
    reason = "not Mach-O: helpers/Info.plist";
    pkg = mkPkg {
      name = "Naked";
      identifier = "com.example.naked";
      nestedHelper = true;
      nakedPlist = true;
    };
  };

  stabilize-refuses-a-non-string-package-type-under-macos = refusesToStabilize {
    name = "a-non-string-package-type-under-macos";
    reason = "not Mach-O: helpers/Info.plist";
    pkg = mkPkg {
      name = "Mistyped";
      identifier = "com.example.mistyped";
      nestedHelper = true;
      nonStringPackageType = true;
    };
  };

  stabilize-refuses-a-link-into-a-nested-bundle = refusesToStabilize {
    name = "a-link-into-a-nested-bundle";
    reason = "not Mach-O: toplugin";
    pkg = mkPkg {
      name = "Linkplug";
      identifier = "com.example.linkplug";
      nestedBundle = true;
      linkIntoNestedBundle = true;
    };
  };

  stabilize-refuses-a-link-into-a-root-bundle = refusesToStabilize {
    name = "a-link-into-a-root-bundle";
    reason = "not Mach-O: toroot";
    pkg = mkPkg {
      name = "Linkroot";
      identifier = "com.example.linkroot";
      rootBundle = true;
      rootBundleLink = true;
    };
  };

  stabilize-refuses-a-directory-link-under-macos = refusesToStabilize {
    name = "a-directory-link-under-macos";
    reason = "not Mach-O: linkdir";
    pkg = mkPkg {
      name = "Dirlink";
      identifier = "com.example.dirlink";
      linkedDirectory = true;
    };
  };

  stabilize-refuses-an-unresolvable-link = refusesToStabilize {
    name = "an-unresolvable-link";
    reason = "not Mach-O: broken";
    pkg = mkPkg {
      name = "Dangling";
      identifier = "com.example.dangling";
      danglingLink = true;
    };
  };

  stabilize-refuses-a-colon-in-an-executable-name = refusesToStabilize {
    name = "a-colon-in-an-executable-name";
    reason = "not Mach-O: a:b";
    pkg = mkPkg {
      name = "Coloned";
      identifier = "com.example.coloned";
      colonName = true;
    };
  };

  stabilize-refuses-a-mach-o-the-signer-would-not-resign = refusesToStabilize {
    name = "a-mach-o-the-signer-would-not-resign";
    reason = [
      "seals without signing"
      "Contents/Resources/.DS_Store"
    ];
    pkg = mkPkg {
      name = "Dsstore";
      identifier = "com.example.dsstore";
      dsStoreResource = true;
    };
  };

  stabilize-refuses-a-ds-store-mach-o-under-macos = refusesToStabilize {
    name = "a-ds-store-mach-o-under-macos";
    reason = "not Mach-O: .DS_Store";
    pkg = mkPkg {
      name = "Dsmacos";
      identifier = "com.example.dsmacos";
      dsStoreMacOS = true;
    };
  };

  stabilize-refuses-a-mach-o-under-mas-receipt = refusesToStabilize {
    name = "a-mach-o-under-mas-receipt";
    reason = [
      "seals without signing"
      "Contents/_MASReceipt/receipt"
    ];
    pkg = mkPkg {
      name = "Receipted";
      identifier = "com.example.receipted";
      masReceipt = true;
    };
  };

  # The out path the script is given ends in .app here, so the bundle a sealed
  # path is measured against cannot be the first ".app/" in it.
  stabilize-refuses-sealed-only-under-a-dot-app-out = refusesToStabilize {
    name = "sealed-only-under-a-dot-app-out";
    outName = "stabilized.app";
    reason = [
      "seals without signing"
      "Contents/_MASReceipt/receipt"
    ];
    pkg = mkPkg {
      name = "Receipted";
      identifier = "com.example.receipted";
      masReceipt = true;
    };
  };

  stabilize-refuses-a-nested-pkginfo-mach-o = refusesToStabilize {
    name = "a-nested-pkginfo-mach-o";
    reason = [
      "seals without signing"
      "Extra.plugin/Contents/PkgInfo"
    ];
    pkg = mkPkg {
      name = "Pkginfo";
      identifier = "com.example.pkginfo";
      nestedBundle = true;
      nestedPkgInfo = true;
    };
  };

  stabilize-refuses-a-root-bundle-pkginfo-mach-o = refusesToStabilize {
    name = "a-root-bundle-pkginfo-mach-o";
    reason = [
      "seals without signing"
      "Root.plugin/Contents/PkgInfo"
    ];
    pkg = mkPkg {
      name = "Rootplug";
      identifier = "com.example.rootplug";
      rootBundle = true;
    };
  };

  stabilize-refuses-a-locversion-mach-o = refusesToStabilize {
    name = "a-locversion-mach-o";
    reason = [
      "seals without signing"
      "Contents/en.lproj/locversion.plist"
    ];
    pkg = mkPkg {
      name = "Locversion";
      identifier = "com.example.locversion";
      locversion = true;
    };
  };

  stabilize-refuses-a-mach-o-in-an-app-below-a-subdirectory = refusesToStabilize {
    name = "a-mach-o-in-an-app-below-a-subdirectory";
    reason = [
      "from outside the bundle"
      "group/Other.app/Contents/MacOS/Other"
    ];
    pkg = mkPkg {
      name = "Grouped";
      identifier = "com.example.grouped";
      groupedApp = true;
    };
  };

  bundle-from-a-package-is-resolvable-with-get-exe =
    let
      bundled = mkAppBundle {
        package = daemon;
        identifier = "com.example.daemon";
      };
    in
    runCommand "check-bundle-from-a-package-is-resolvable-with-get-exe" { } ''
      if [ "${lib.getExe bundled}" != "${bundled}/bin/daemon" ]; then
        echo "lib.getExe resolved to ${lib.getExe bundled}, expected ${bundled}/bin/daemon" >&2
        exit 1
      fi
      [ -x "${lib.getExe bundled}" ]
      grep -q '<key>CFBundleShortVersionString</key><string>${lib.getVersion daemon}</string>' \
        "${bundled}/Applications/test-daemon.app/Contents/Info.plist"
      touch $out
    '';

  bundle-is-signed-under-its-identifier =
    let
      bundled = mkAppBundle {
        name = "Daemon";
        identifier = "com.example.daemon";
        executable = "${daemon}/bin/daemon";
        mainProgram = "daemon";
      };
    in
    runCommand "check-bundle-is-signed-under-its-identifier"
      {
        nativeBuildInputs = [ rcodesign ];
      }
      ''
        ${requiresIdentifier}
        requiresIdentifier "${bundled}/Applications/Daemon.app" com.example.daemon

        if [ "$(readlink "${bundled}/bin/daemon")" != ../Applications/Daemon.app/Contents/MacOS/Daemon ]; then
          echo "bin/daemon does not link into the bundle" >&2
          exit 1
        fi
        [ -x "${bundled.mainExecutable}" ]
        touch $out
      '';

  wrapper-is-seen-through-to-its-executable =
    let
      bundled = mkAppBundle {
        name = "Wrapped";
        identifier = "com.example.wrapped";
        executable = writeScript "daemon-wrapper" ''
          #!/bin/sh
          exec -a "$0" "${daemon}/bin/daemon" "$@"
        '';
      };
    in
    runCommand "check-wrapper-is-seen-through-to-its-executable" { } ''
      # A wrapper script sealed as the bundle's main executable would make nix's
      # bash the responsible process, at a store path that moves whenever nixpkgs
      # bumps bash. Compared before signing, which rewrites what it seals.
      cmp "${bundled.unstabilized}/Applications/Wrapped.app/Contents/MacOS/Wrapped" "${daemon}/bin/daemon"
      touch $out
    '';

  bundle-refuses-a-wrapper-carrying-an-environment = refusesToBundle {
    name = "a-wrapper-carrying-an-environment";
    reason = "sets up an environment that a bundle cannot carry";
    executable = writeScript "wrapper-with-environment" ''
      #!/bin/sh
      export SOME_SETTING=1
      exec -a "$0" "${daemon}/bin/daemon" "$@"
    '';
  };

  bundle-refuses-an-opaque-script = refusesToBundle {
    name = "an-opaque-script";
    reason = "is a script this cannot see through";
    executable = writeScript "opaque-script" ''
      #!/bin/sh
      echo not a wrapper this can see through
    '';
  };

  # The bundle is a new store path, so a load path resolved against the
  # executable's own location points somewhere else once it is copied in.
  bundle-refuses-a-relative-load-path = refusesToBundle {
    name = "a-relative-load-path";
    reason = "loads libraries relative to its own location";
    executable =
      runCommandCC "test-relative-load-path" { } ''
        mkdir -p $out/bin
        printf 'int main(void){return 0;}\n' > main.c
        cc -o $out/bin/relative main.c -Wl,-rpath,@loader_path/../lib
      ''
      + "/bin/relative";
  };
}
