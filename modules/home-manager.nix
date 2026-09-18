{ config, lib, ... }:

let
  path = [
    "targets"
    "darwin"
    "appIdentity"
  ];
  cfg = lib.getAttrFromPath path config;
in
{
  imports = [ (import ./options.nix path) ];

  config = lib.mkIf (cfg.apps != [ ]) {
    assertions = [
      {
        assertion = config.targets.darwin.copyApps.enable || config.targets.darwin.linkApps.enable;
        message = ''
          targets.darwin.appIdentity needs home-manager to install applications,
          but both targets.darwin.copyApps and targets.darwin.linkApps are
          disabled.
        '';
      }
    ];

    home.packages = cfg.stabilized;
  };
}
