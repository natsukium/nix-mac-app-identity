{ pkgs }:

let
  stabilizeApp = pkgs.callPackage ./pkgs/stabilize-app.nix { };
in
{
  inherit stabilizeApp;
  mkAppBundle = pkgs.callPackage ./pkgs/app-bundle.nix { inherit stabilizeApp; };
}
