/* Examples

   Perform the same evaluation that occurs on CI via:

     $ NIX_PATH="" nix-instantiate ci.nix --arg supportedSystems '["x86_64-darwin"]'

   Build the release tarball:

     $ NIX_PATH="" nix-instantiate ci.nix -A darwin.tarball
*/

{ supportedSystems ? [ "x86_64-linux" "x86_64-darwin" ] }:

let

  inherit (import ./nix/default.nix { }) lib haskell-nix callPackage;

  # Local library import from derivation functions such as fetchGitHubLFS, etc.
  # upon which local package defintions are dependent.
  localLib = callPackage ./nix/lib { };

  # The key with google storage bucket write permission,
  # deployed to ci via nixops `deployment.keys."service-account.json"`.
  serviceAccountKey =
    builtins.readFile ("/var/lib/hercules-ci-agent/secrets/service-account.json");

  # Push a split output derivation containing "out" and "hash" outputs.
  pushObject =
    { name, extension, drv, contentType ? "application/octet-stream" }:
    let
      # Use the sha256 for the object key prefix.
      sha256 = builtins.readFile (drv.hash + "/sha256");
      # Use md5 as an idempotency check for gsutil.
      contentMD5 = builtins.readFile (drv.hash + "/md5");
    in localLib.pushStorageObject {
      inherit serviceAccountKey name contentMD5 contentType;

      bucket = "bootstrap.urbit.org";
      object = "ci/${lib.removeSuffix extension name}${sha256}.${extension}";
      file = drv.out;
    };

  # Build and push a split output pill derivation with the ".pill" file extension.
  pushPill = name: pill:
    pushObject {
      inherit name;

      drv = pill.build;
      extension = "pill";
    };

  systems = lib.filterAttrs (_: v: builtins.elem v supportedSystems) {
    linux = "x86_64-linux";
    darwin = "x86_64-darwin";
  };

in localLib.dimension "system" systems (systemName: system:
  let
    dynamicPackages = import ./default.nix {
      inherit system;

      enableStatic = false;
    };

    staticPackages = import ./default.nix {
      inherit system;

      enableStatic = true;
    };

    # Filter the stack project to only our locally declared packages.
    haskellPackages =
      haskell-nix.haskellLib.selectProjectPackages staticPackages.hs;

    # The top-level set of attributes to build on ci.
    finalPackages = dynamicPackages // rec {
      # Replace some top-level attributes with their static variant.
      inherit (staticPackages) urbit tarball;

      # Expose the nix-shell derivation as a sanity check.
      shell = import ./shell.nix;

      # Replace the .hs attribute with the individual collections of components
      # displayed as top-level attributes:
      #
      # <system>.hs.library.[...]
      # <system>.hs.checks.[...]
      # <system>.hs.tests.[...]
      # <system>.hs.benchmarks.[...]
      # ...
      #
      # Note that .checks are the actual _execution_ of the tests.
      hs = localLib.collectHaskellComponents haskellPackages;

      # Push the tarball to the remote google storage bucket.
      release = pushObject {
        name = tarball.name;
        drv = tarball;
        extension = tarball.meta.extension;
        contentType = "application/x-gtar";
      };

      # Replace top-level pill attributes with push to google storage variants.
    } // lib.optionalAttrs (system == "x86_64-linux") {
      ivory = pushPill "ivory" dynamicPackages.ivory;
      brass = pushPill "brass" dynamicPackages.brass;
      solid = pushPill "solid" dynamicPackages.solid;

      ivory-ropsten = pushPill "ivory-ropsten" dynamicPackages.ivory-ropsten;
      brass-ropsten = pushPill "brass-ropsten" dynamicPackages.brass-ropsten;
    };

    # Filter derivations that have meta.platform missing the current system,
    # such as testFakeShip on darwin.
    platformFilter = localLib.platformFilterGeneric system;

  in localLib.filterAttrsOnlyRecursive (_: v: platformFilter v) finalPackages)