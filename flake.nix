{
  description = "doma is a fast, single-binary BM25 search over markdown directories in Odin: indexes at the heading level and returns ranked sections with breadcrumbs, no models or server.";

  # Pinned to the same channel as the system flake so the dev shell reuses
  # store paths you already have instead of downloading a second toolchain.
  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";

  outputs = { nixpkgs, ... }:
    let
      forAll = f: nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ]
        (s: f nixpkgs.legacyPackages.${s});
    in {
      devShells = forAll (pkgs: {
        default = pkgs.mkShell {
          packages = with pkgs; [
            odin
            ols # Odin language server
            gdb

            # Project commands, so the output path lives in one place instead of
            # every `odin build` invocation. Run from the repo root.
            (writeShellScriptBin "build" "exec odin build . -out:build/doma \"$@\"")
            (writeShellScriptBin "test" "exec odin test src -out:build/test \"$@\"")
            (writeShellScriptBin "run" ''
              odin build . -out:build/doma || exit
              exec build/doma "$@"
            '')
          ];
        };
      });
    };
}
