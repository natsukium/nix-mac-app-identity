path:

{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = lib.getAttrFromPath path config;
  # Called here rather than taken from pkgs so that the module works without the
  # overlay applied.
  stabilizeApp = pkgs.callPackage ../pkgs/stabilize-app.nix { };
in
{
  options = lib.setAttrByPath path {
    apps = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      example = lib.literalExpression "[ pkgs.handy ]";
      description = ''
        Packages to install with a stable identity: their `.app` bundles are
        signed under a designated requirement that does not depend on their
        contents, so permissions granted to them survive a rebuild. Bundles
        carrying a Developer ID signature are passed through untouched, and a
        package that cannot be given a stable identity fails the build.

        List them here *instead of* in the usual package list: a second copy of
        the same application would give macOS two bundles with one identifier to
        choose between.
      '';
    };

    stabilized = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      internal = true;
      readOnly = true;
      default = map stabilizeApp cfg.apps;
    };
  };
}
