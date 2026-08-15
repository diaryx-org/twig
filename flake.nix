{
  description = "twig — a lossless Djot/Markdown/HTML/XML document parser/editor CLI and library";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    # Pins the exact Zig toolchain (0.16.0) twig is built with, matching CI.
    zig-overlay.url = "github:mitchellh/zig-overlay";
    zig-overlay.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, flake-utils, zig-overlay }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        zig = zig-overlay.packages.${system}."0.16.0";

        # The version lives in build.zig.zon (the single source of truth the CLI
        # compiles into its `--version` string via build.zig). Parse it so the
        # flake reports the same number as `twig --version`.
        version =
          let m = builtins.match ".*\n[[:blank:]]*.version = \"([^\"]+)\".*"
                    (builtins.readFile ./build.zig.zon);
          in if m == null
             then throw "twig flake: could not find `.version` in build.zig.zon"
             else builtins.head m;
      in {
        packages = rec {
          default = twig;

          twig = pkgs.stdenv.mkDerivation {
            pname = "twig";
            inherit version;
            src = ./.;

            nativeBuildInputs = [ zig ];

            # twig has no build.zig.zon dependencies, so the build needs no
            # network access — but Zig still wants a writable cache dir, which
            # the read-only Nix store won't provide.
            dontConfigure = true;
            dontInstall = true; # `zig build --prefix $out` installs directly.

            # No `-Dstrip`: twig's build.zig only exposes the standard
            # target/optimize options.
            buildPhase = ''
              runHook preBuild
              export HOME="$TMPDIR"
              export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global-cache"
              export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-local-cache"
              zig build --prefix "$out" -Doptimize=ReleaseFast
              runHook postBuild
            '';

            meta = {
              description = "Parse, query, edit, and losslessly round-trip Djot, Markdown, HTML, and XML documents";
              homepage = "https://github.com/diaryx-org/twig";
              license = with pkgs.lib.licenses; [ mit asl20 ];
              mainProgram = "twig";
              platforms = pkgs.lib.platforms.unix;
            };
          };
        };

        apps.default = {
          type = "app";
          program = "${self.packages.${system}.twig}/bin/twig";
        };

        devShells.default = pkgs.mkShell {
          # git-cliff drives scripts/changelog.sh, which regenerates the
          # generated region of CHANGELOG.md's Unreleased section.
          nativeBuildInputs = [
            zig
            pkgs.git-cliff
          ];
        };
      });
}
