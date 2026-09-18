{ config, lib, ... }:

let
  path = [
    "system"
    "appIdentity"
  ];
  cfg = lib.getAttrFromPath path config;
in
{
  imports = [ (import ./options.nix path) ];

  config = lib.mkIf (cfg.apps != [ ]) {
    environment.systemPackages = cfg.stabilized;
  };
}
