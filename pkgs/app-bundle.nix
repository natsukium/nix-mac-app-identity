{
  lib,
  cctools,
  runCommand,
  stabilizeApp,
}:

{
  package ? null,
  identifier,
  executable ? null,
  name ? null,
  version ? null,
  mainProgram ? null,
  showInDock ? false,
  icon ? null,
}:

let
  derived =
    if package != null && executable != null then
      throw "mkAppBundle: pass either package or executable, not both"
    else if package != null then
      {
        name = lib.getName package;
        version = if lib.getVersion package == "" then "0" else lib.getVersion package;
        executable = lib.getExe package;
        mainProgram = package.meta.mainProgram or (lib.getName package);
      }
    else if executable != null then
      {
        inherit executable;
        name = if name != null then name else throw "mkAppBundle: an executable needs a name";
        version = "0";
        mainProgram = name;
      }
    else
      throw "mkAppBundle: pass a package, or an executable together with a name";

  appName = if name != null then name else derived.name;
  program = if mainProgram != null then mainProgram else derived.mainProgram;

  bundle =
    runCommand "${appName}.app"
      {
        inherit identifier;
        inherit (derived) executable;
        version = if version != null then version else derived.version;
        inherit appName;
        mainProgram = program;
        showInDock = lib.optionalString showInDock "1";
        icon = lib.optionalString (icon != null) "${icon}";
        nativeBuildInputs = [ cctools ];
        meta = {
          description = "${appName} as an application bundle";
          mainProgram = program;
        };
      }
      ''
        bash ${../scripts/mk-bundle.sh} "$out"
      '';

  stabilized = stabilizeApp bundle;
in
stabilized
// {
  mainExecutable = "${stabilized}/Applications/${appName}.app/Contents/MacOS/${appName}";
}
