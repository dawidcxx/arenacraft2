{

  description = "Arenacraft2 development environment";

  inputs = {
    flake-utils.url = "github:numtide/flake-utils";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };
        lib = nixpkgs.lib;
      in
      {
        devShells = {
          default = pkgs.mkShell.override { stdenv = pkgs.clangStdenv; } {
            nativeBuildInputs = with pkgs; [
              zig
              zls
              pkg-config

              hyperfine
              entr
              tokei

            ];

            shellHook = ''
              export DATABASE_URL="postgresql://arenacraft:arenacraft@127.0.0.1:5432/arenacraft"
              unset NIX_CFLAGS_COMPILE
            '';
          };
        };
      }
    );
}
