{
  lib,
  pkgs,
  pkgsLinux,
  runCommand,
  runCommandCC,
  stabilizeApp,
}:

let
  fixture = runCommandCC "test-module-pkg" { } ''
    app=$out/Applications/Demo.app
    mkdir -p "$app/Contents/MacOS"
    printf 'int main(void){return 0;}\n' > main.c
    cc -o "$app/Contents/MacOS/demo" main.c
    printf '%s' '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>demo</string><key>CFBundleIdentifier</key><string>com.example.demo</string></dict></plist>' \
      > "$app/Contents/Info.plist"
  '';

  stabilizedFixture = stabilizeApp fixture;

  hostOptions = {
    options = {
      lib = lib.mkOption {
        type = lib.types.attrsOf lib.types.attrs;
        default = { };
      };

      assertions = lib.mkOption {
        type = lib.types.listOf lib.types.unspecified;
        default = [ ];
      };

      home.packages = lib.mkOption {
        type = lib.types.listOf lib.types.package;
        default = [ ];
      };

      environment.systemPackages = lib.mkOption {
        type = lib.types.listOf lib.types.package;
        default = [ ];
      };

      targets.darwin.copyApps.enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
      };

      targets.darwin.linkApps.enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
      };

      programs.demo = lib.mkOption {
        type = lib.types.submodule {
          options.pkg = lib.mkOption { type = lib.types.package; };
        };
        default = { };
      };
    };
  };

  evalHost =
    {
      module,
      packages ? pkgs,
      modules ? [ ],
    }:
    (lib.evalModules {
      modules = [
        module
        hostOptions
        { _module.args.pkgs = packages; }
      ]
      ++ modules;
    }).config;

  evalHome = args: evalHost (args // { module = ../modules/home-manager.nix; });
  evalDarwin = args: evalHost (args // { module = ../modules/darwin.nix; });

  check =
    name: condition:
    assert condition;
    runCommand name { } "touch $out";

  hmEmpty = evalHome {
    modules = [
      {
        targets.darwin.copyApps.enable = true;
        targets.darwin.appIdentity.apps = [ ];
      }
    ];
  };

  hmListed = evalHome {
    modules = [
      {
        targets.darwin.copyApps.enable = true;
        targets.darwin.appIdentity.apps = [ fixture ];
      }
    ];
  };

  darwinEmpty = evalDarwin {
    modules = [ { system.appIdentity.apps = [ ]; } ];
  };

  merged = evalHome {
    modules = [
      { targets.darwin.copyApps.enable = true; }
      {
        lib.sentinel = {
          marker = true;
        };
      }
    ];
  };

  linuxEmpty = evalHome {
    packages = pkgsLinux;
    modules = [ { targets.darwin.copyApps.enable = true; } ];
  };

  submoduleConsumer = evalHome {
    modules = [
      { targets.darwin.copyApps.enable = true; }
      (
        { config, ... }:
        {
          programs.demo.pkg = config.lib.appIdentity.stabilizeApp fixture;
        }
      )
    ];
  };
in
{
  hm-empty = check "hm-empty" (
    hmEmpty.lib.appIdentity ? stabilizeApp
    && hmEmpty.lib.appIdentity ? mkAppBundle
    && hmEmpty.home.packages == [ ]
  );

  darwin-empty = check "darwin-empty" (
    darwinEmpty.lib.appIdentity ? stabilizeApp
    && darwinEmpty.lib.appIdentity ? mkAppBundle
    && darwinEmpty.environment.systemPackages == [ ]
  );

  hm-same-derivation = check "hm-same-derivation" (
    (hmEmpty.lib.appIdentity.stabilizeApp fixture).drvPath == stabilizedFixture.drvPath
  );

  hm-apps-listed = check "hm-apps-listed" (
    lib.length hmListed.home.packages == 1
    && (lib.head hmListed.home.packages).drvPath == stabilizedFixture.drvPath
  );

  lib-merge = check "lib-merge" (merged.lib.sentinel.marker && merged.lib.appIdentity ? stabilizeApp);

  linux-empty = check "linux-empty" (
    linuxEmpty.home.packages == [ ]
    &&
      builtins.attrNames linuxEmpty.lib.appIdentity == [
        "mkAppBundle"
        "stabilizeApp"
      ]
  );

  submodule-consumer = check "submodule-consumer" (
    submoduleConsumer.programs.demo.pkg.drvPath == stabilizedFixture.drvPath
  );
}
