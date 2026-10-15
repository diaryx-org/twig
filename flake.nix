{
  description = "twig — a lossless Djot/Markdown/HTML/XML document parser/editor CLI and library";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    # The org's shared Rust toolchain and the dev shell that carries it.
    diaryx-nix.url = "github:diaryx-org/nix";
    diaryx-nix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, flake-utils, diaryx-nix }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };

        # The version lives in the workspace's Cargo.toml (the number every
        # crate inherits and the CLI prints as `twig --version`).
        version = (builtins.fromTOML (builtins.readFile ./Cargo.toml)).workspace.package.version;
      in {
        packages = rec {
          default = twig;

          twig = pkgs.rustPlatform.buildRustPackage {
            pname = "twig";
            inherit version;
            src = ./.;
            cargoLock = {
              lockFile = ./Cargo.lock;
              # twig-meta's fig comes from git, pinned by its rev in
              # Cargo.lock; the CLI does not build it, but the lock vendors it.
              outputHashes."fig-6.0.0" = "sha256-RBvK/KOnIEAxBqjMauad8UPdBg9h496nSl0tWRbWAGY=";
            };

            # The CLI crate only; the engine is its dependency, and the C ABI
            # (twig-capi) is not part of the command-line package.
            cargoBuildFlags = [ "-p" "twig-doc-cli" ];
            cargoTestFlags = [ "-p" "twig-doc-cli" ];

            meta = {
              description = "Parse, query, edit, and losslessly round-trip Djot, Markdown, HTML, XML, and AsciiDoc documents";
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

        # git-cliff comes with the shared shell, for scripts/changelog.sh and the
        # generated region of CHANGELOG.md's Unreleased section.
        devShells.default = diaryx-nix.devShells.${system}.rust;
      });
}
