{
  lib,
  cctools,
  libplist,
  libxml2,
  mkAppBundle,
  rcodesign,
  rsync,
  runCommand,
  runCommandCC,
  shellcheck,
  stabilizeApp,
  writeScript,
}:

let
  # Shaped like the packages this signs: one bundle under Applications holding a
  # real Mach-O. `marker` changes the executable's bytes without touching
  # anything the requirement is supposed to name.
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
    }:
    runCommandCC "test-pkg-${name}"
      {
        nativeBuildInputs = lib.optional binaryPlist libplist.bin;
      }
      ''
        app=$out/Applications/${name}.app
        mkdir -p "$app/Contents/MacOS"

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

        ${lib.optionalString binaryPlist ''
          plistutil -i "$app/Contents/Info.plist" -f bin -o Info.bin
          mv Info.bin "$app/Contents/Info.plist"
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

  # A refusal has no passing form to build, so it is driven from a check that
  # runs the script itself and requires both a failure and the stated reason: a
  # refusal raised for a different reason is its own regression.
  refusesToStabilize =
    {
      name,
      reason,
      pkg,
    }:
    runCommand "check-stabilize-refuses-${name}"
      {
        nativeBuildInputs = [
          libplist.bin
          libxml2.bin
          rcodesign
          rsync
        ];
      }
      ''
        if bash ${../scripts/stabilize.sh} ${pkg} "$PWD/stabilized" > stdout.log 2> stderr.log; then
          echo "the build succeeded, expected it to be refused" >&2
          exit 1
        fi
        if ! grep -qF ${lib.escapeShellArg reason} stderr.log; then
          echo "refused, but not for ${reason}:" >&2
          cat stderr.log >&2
          exit 1
        fi
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
        ${designated}
        got=$(designated "${stabilized}/Applications/${name}.app")
        want='identifier "${identifier}"'
        if [ "$got" != "$want" ]; then
          echo "expected the designated requirement to be: $want" >&2
          echo "but it decoded to: $got" >&2
          exit 1
        fi
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

        ${designated}
        got=$(designated "${stabilized}/Applications/${name}.app")
        want='identifier "${identifier}"'
        if [ "$got" != "$want" ]; then
          echo "expected the designated requirement to be: $want" >&2
          echo "but it decoded to: $got" >&2
          exit 1
        fi
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
        ${designated}
        exe=Contents/MacOS/Stable
        if cmp -s "${a}/Applications/Stable.app/$exe" "${b}/Applications/Stable.app/$exe"; then
          echo "the two builds are byte-identical, so this proves nothing" >&2
          exit 1
        fi

        # Comparing the two against each other is not enough: a build that wrote
        # no designated requirement at all gives two empty strings that match.
        want='identifier "com.example.stable"'
        for app in "${a}" "${b}"; do
          got=$(designated "$app/Applications/Stable.app")
          if [ "$got" != "$want" ]; then
            echo "expected both builds to be signed under: $want" >&2
            echo "but $app decoded to: $got" >&2
            exit 1
          fi
        done
        touch $out
      '';

  script-in-macos-is-left-alone-when-unsupported-is-allowed =
    let
      pkg = mkPkg {
        name = "Scripted";
        identifier = "com.example.scripted";
        scriptExecutable = true;
      };
      stabilized = stabilizeApp {
        package = pkg;
        allowUnsupported = true;
      };
    in
    runCommand "check-script-in-macos-is-left-alone" { } ''
      app="${stabilized}/Applications/Scripted.app"
      if [ -e "$app/Contents/_CodeSignature" ]; then
        echo "a bundle whose Contents/MacOS holds a script cannot be sealed by any" >&2
        echo "signer, so it must come through untouched rather than half-signed" >&2
        exit 1
      fi
      cmp "$app/Contents/MacOS/Scripted" \
          "${pkg}/Applications/Scripted.app/Contents/MacOS/Scripted"
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
        ${designated}
        got=$(designated "${bundled}/Applications/Daemon.app")
        want='identifier "com.example.daemon"'
        if [ "$got" != "$want" ]; then
          echo "expected the bundle to be signed under: $want" >&2
          echo "but it decoded to: $got" >&2
          exit 1
        fi

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
