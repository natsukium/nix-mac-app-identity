{
  lib,
  libplist,
  libxml2,
  perl,
  rcodesign,
  rsync,
  runCommand,
}:

arg:

let
  args = if lib.isDerivation arg then { package = arg; } else arg;
  inherit (args) package;
  allowUnsupported = args.allowUnsupported or false;
  # The source's own store name, so $source and $out have equal length and a
  # Mach-O inside the bundle can be rewritten in place.
  name = builtins.substring 33 (-1) (baseNameOf package.outPath);
in
assert lib.assertMsg (lib.stringLength name <= 207)
  "stabilizeApp: ${name} is longer than the 207 characters a derivation name may have, so the stabilized store path cannot match it in length";
runCommand name
  {
    inherit (package) meta;
    pname = "${lib.getName package}-stable-identity";
    version = lib.getVersion package;
    allowUnsupported = lib.optionalString allowUnsupported "1";
    nativeBuildInputs = [
      libplist.bin
      libxml2.bin
      perl
      rcodesign
      rsync
    ];
    passthru = (package.passthru or { }) // {
      unstabilized = package;
    };
  }
  ''
    bash ${../scripts/stabilize.sh} ${package} "$out"
  ''
