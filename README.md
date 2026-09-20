# nix-mac-app-identity

macOS applications and daemons built by Nix lack a stable code signing
identity. Every rebuild produces a different binary hash or store path, causing
macOS to revoke granted permissions (Accessibility, Input Monitoring, etc.).

This project gives those programs an identity that does not change.

## The Problem

macOS records TCC permission grants against an application's code signing
requirement. Nix breaks this in two ways:

- **GUI Applications (`.app`)**: Applications built or patched by nixpkgs are
  ad-hoc signed. Without a Developer ID certificate to name a team, macOS binds
  the grant to the binary's code directory hash (`cdhash`):

  ```
  Microphone  com.pais.handy  bundle id  allowed  cdhash H"493fd2e49bb233214468453036785ce8c79d14b9"
  ```

  Any rebuild changes that hash, invalidating the grant.

- **Bare Executables (daemons, CLI tools)**: Executables outside a bundle lack
  a bundle identifier, so macOS tracks them by absolute path. In Nix, that path
  lives in `/nix/store/...` and moves on every rebuild. Additionally,
  `makeWrapper` scripts make `bash` the responsible process, breaking grants
  whenever nixpkgs updates `bash`.

## Usage

Add the input to your `flake.nix`:

```nix
inputs.nix-mac-app-identity.url = "github:natsukium/nix-mac-app-identity";
```

The helpers come from the flake itself, with no overlay to set up:

```nix
appIdentity = pkgs.callPackage inputs.nix-mac-app-identity { };
```

This gives `appIdentity.stabilizeApp` and `appIdentity.mkAppBundle`, used
below.

### GUI Applications

Use the home-manager or nix-darwin module:

```nix
# home-manager (requires copyApps or linkApps enabled)
{
  imports = [ inputs.nix-mac-app-identity.homeManagerModules.default ];
  targets.darwin.appIdentity.apps = [ pkgs.handy ];
}

# nix-darwin
{
  imports = [ inputs.nix-mac-app-identity.darwinModules.default ];
  system.appIdentity.apps = [ pkgs.handy ];
}
```

List packages here _instead of_ in `home.packages` or
`environment.systemPackages` to avoid installing duplicate bundles with the
same identifier.

#### From another module

Once the module is imported, `config.lib.appIdentity` exposes the same helpers
to other modules in the configuration. Called with the same package set, it
builds the same derivation as the `pkgs.callPackage` route above:

```nix
{ config, pkgs, lib, ... }:
let
  skhdApp = config.lib.appIdentity.mkAppBundle {
    package = pkgs.skhd;
    identifier = "com.koekeishiya.skhd";
  };
in
{
  programs.kitty.package = config.lib.appIdentity.stabilizeApp pkgs.kitty;

  launchd.agents.skhd.config.ProgramArguments = [ (lib.getExe skhdApp) ];
}
```

- Available whenever the module is imported, even with an empty `apps`.
- Not usable inside `imports`.
- A submodule receives its own `config`, so a parent passes the helper or the result in.
- On Linux the attribute exists, but applying a helper is unsupported and may fail at evaluation or build.

#### Standalone

Without the module, stabilize a package by hand:

```nix
{
  environment.systemPackages = [ (appIdentity.stabilizeApp pkgs.handy) ];
}
```

`stabilizeApp` fails the build on a package it cannot give a stable identity:
one whose `Contents/MacOS` holds something other than a Mach-O, and one that
carries no `.app` at all. To install such a package as it is, pass an attribute
set instead of the package:

```nix
appIdentity.stabilizeApp {
  package = pkgs.firefox;
  allowUnsupported = true;
}
```

The build then warns and leaves the bundle untouched, rather than silently
producing a package whose permissions will not survive a rebuild.

### Bare Executables

Wrap an executable in a minimal `.app` bundle with `appIdentity.mkAppBundle`:

```nix
let
  skhdApp = appIdentity.mkAppBundle {
    package = pkgs.skhd;
    identifier = "com.koekeishiya.skhd";
  };
in
{
  launchd.agents.skhd.config.ProgramArguments = [ (lib.getExe skhdApp) ];
}
```

`name`, `version`, and `mainProgram` default to the package's metadata; pass
any explicitly to override. For an unmanaged binary, pass `executable` and
`name` instead of `package`.

The result is an ordinary package whose `$out/bin/<mainProgram>` links into the
bundle. The bundle stays in the Nix store without being copied to
`/Applications`; macOS matches permissions by its identifier.

Bundled applications are hidden from the Dock. Pass `showInDock = true` for one
that belongs there.

## How It Works

### Designated Requirements

`stabilizeApp` signs bundles under a designated requirement naming only the
bundle identifier:

```
designated => identifier "com.pais.handy"
```

The signature is ad-hoc (requiring no certificate or keychain setup). Signing
happens inside the Nix derivation, surviving byte-for-byte when copied into
`/Applications`. Subsequent builds share the same identifier and retain
permissions.

Every Mach-O under `Contents/MacOS` is signed under that same requirement, not
just the bundle's main executable. A `makeBinaryWrapper` stub execs a hidden
sibling (`.handy-wrapped`), and the kernel holds _that_ process, so a helper
left with its own file-name identifier and `cdhash` requirement would lose the
grant on every rebuild. Nested bundles (`.plugin`, `.framework`) keep the
identifier of their own `Info.plist`.

### Vendor Signatures

Bundles carrying an authentic Apple Developer ID signature are passed through
untouched; their requirement already names a stable Team ID.

### Path Rewriting & Deduplication

- References to the original store path are repointed to the new output: in
  wrapper scripts and other text files, and in Mach-O binaries inside the
  bundle, which the signer rebuilds afterwards. A Mach-O can only be rewritten
  in place, so the stabilized output is given the source's own store name to
  keep the two paths equal in length. Identify the result by `pname` rather
  than by its store name; a bundle from `mkAppBundle` is named `<App>.app`.
- Binaries outside the bundle pointing back to the old store path abort the
  build, because they could execute into unsigned code and nothing re-signs
  them after a rewrite. So do Mach-Os sitting where a signer seals without
  signing (`Info.plist`, `PkgInfo`, `_MASReceipt`, `_CodeSignature`), where a
  rewrite would leave a signature the bytes no longer match. Binary files that
  are not Mach-O (archives, databases, compiled resources) are left as they
  are.
- Duplicate binaries in `bin/` matching `Contents/MacOS/` become relative links
  into the bundle, preventing them from carrying separate store-path identities.

### Bundle Inspection (`mkAppBundle`)

`mkAppBundle` verifies the target is a Mach-O binary, sees through
`makeWrapper` scripts (failing if environment variables cannot be preserved in
a bundle), and rejects binaries loading libraries via `@executable_path` or
`@loader_path`.

## Diagnostics

```console
# Watch real-time TCC decisions from the unified log (no Full Disk Access needed)
$ nix run github:natsukium/nix-mac-app-identity#tcc-watch -- --last 5m handy
2026-09-18 10:08:22.202832  [457.621] accessor identifier=handy
                                    binary=/nix/store/...-handy-0.9.6/Applications/Handy.app/Contents/MacOS/handy
2026-09-18 10:08:22.206933  [457.621] subject  com.pais.handy

# Dump stored TCC grants and requirements (requires Full Disk Access)
$ nix run github:natsukium/nix-mac-app-identity#tcc-dump -- handy
Microphone  com.pais.handy  bundle id  allowed  identifier "com.pais.handy"
```

## Limitations

- Bundles containing shell wrapper scripts in `Contents/MacOS` (e.g., Firefox),
  unpacked extended attributes as files (`:com.apple.provenance`), or
  restricted entitlements cannot be sealed; a `makeBinaryWrapper` stub is a
  Mach-O and is supported. Pass `allowUnsupported = true` to bypass unsupported
  bundles with a warning where possible.
- Ad-hoc requirements matching `identifier "<id>"` are verified by bundle
  identifier rather than a cryptographic key; any local process claiming that
  identifier satisfies the requirement.
- Switching an existing application to a stabilized identity changes its code
  requirement, requiring permissions to be granted once upon initial launch.

## Development

```console
$ nix fmt
$ nix flake check
```

## License

Apache-2.0
