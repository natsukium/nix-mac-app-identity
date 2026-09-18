{
  description = "A stable code signing identity for nix-built macOS applications";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs =
    { nixpkgs, ... }:
    let
      systems = [
        "aarch64-darwin"
        "x86_64-darwin"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      overlays.default = final: _: import ./. { pkgs = final; };

      checks = forAllSystems (pkgs: pkgs.callPackages ./tests (import ./. { inherit pkgs; }));

      # Diagnostics, reachable without a checkout. Kept out of the overlay and out
      # of packages so they never land in anyone's profile.
      apps = forAllSystems (
        pkgs:
        let
          tcc-tools = pkgs.callPackage ./pkgs/tcc-tools.nix { };
        in
        {
          tcc-dump = {
            type = "app";
            program = pkgs.lib.getExe' tcc-tools "tcc-dump";
            meta.description = "Print the stored TCC grants with their code requirement decoded back to text";
          };
          tcc-watch = {
            type = "app";
            program = pkgs.lib.getExe' tcc-tools "tcc-watch";
            meta.description = "Report how TCC identified a process and what it decided, from the unified log";
          };
        }
      );

      homeManagerModules.default = ./modules/home-manager.nix;
      darwinModules.default = ./modules/darwin.nix;

      formatter = forAllSystems (
        pkgs:
        pkgs.runCommand "treefmt"
          {
            nativeBuildInputs = [ pkgs.makeBinaryWrapper ];
          }
          ''
            mkdir -p $out/bin
            makeWrapper ${pkgs.treefmt}/bin/treefmt $out/bin/treefmt \
              --prefix PATH : ${
                pkgs.lib.makeBinPath [
                  pkgs.nixfmt
                  pkgs.oxfmt
                  pkgs.shfmt
                ]
              }
          ''
      );
    };
}
