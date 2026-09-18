{
  lib,
  libplist,
  libxml2,
  rcodesign,
  rsync,
  runCommand,
}:

arg:

let
  args = if lib.isDerivation arg then { package = arg; } else arg;
  inherit (args) package;
  allowUnsupported = args.allowUnsupported or false;
in
runCommand "${lib.getName package}-stable-identity"
  {
    inherit (package) meta;
    pname = "${lib.getName package}-stable-identity";
    version = lib.getVersion package;
    allowUnsupported = lib.optionalString allowUnsupported "1";
    nativeBuildInputs = [
      libplist.bin
      libxml2.bin
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
