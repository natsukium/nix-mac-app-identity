{
  lib,
  runCommand,
}:

runCommand "tcc-tools"
  {
    meta = {
      description = "Diagnostics for what TCC recorded and how it identified a process";
      license = lib.licenses.asl20;
      platforms = lib.platforms.darwin;
    };
  }
  ''
    install -Dm755 ${../scripts/tcc-dump.sh} $out/bin/tcc-dump
    install -Dm755 ${../scripts/tcc-watch.sh} $out/bin/tcc-watch
    patchShebangs $out/bin
  ''
