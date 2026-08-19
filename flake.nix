{
  description = "A flake template for Phoenix 1.7 projects.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  };

  outputs = {
    self,
    nixpkgs,
  }: let
    overlay = prev: final: rec {
      erlang = prev.beam.interpreters.erlang_29;
      beamPackages = prev.beam.packagesWith erlang;
      elixir = beamPackages.elixir_1_20;
      hex = beamPackages.hex;
    };

    forAllSystems = nixpkgs.lib.genAttrs [
      "x86_64-linux"
      "aarch64-linux"
#      "x86_64-darwin"
#      "aarch64-darwin"
    ];

    nixpkgsFor = system:
      import nixpkgs {
        inherit system;
        overlays = [overlay];
      };
  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgsFor system;
      # FIXME: import the Mix deps into Nix by running `mix2nix > deps.nix` from a dev shell
      # mixNixDeps = import ./deps.nix {
      #  lib = pkgs.lib;
      #  beamPackages = pkgs.beamPackages;
      #};
    in {
      default = pkgs.beamPackages.mixRelease {
        pname = "my-phx-app";
        # Elixir app source path
        src = ./.;
        version = "0.1.0";
        # FIXME: mixNixDeps was specified in the FIXME above. Uncomment the next line.
        # inherit mixNixDeps;

        # add esbuild and tailwindcss
        buildInputs = [pkgs.elixir pkgs.esbuild pkgs.tailwindcss];

        # Explicitly declare tailwind and esbuild binary paths (don't let Mix fetch them)
        preConfigure = ''
          substituteInPlace config/config.exs \
            --replace "config :tailwind," "config :tailwind, path: \"${pkgs.tailwindcss}/bin/tailwindcss\","\
            --replace "config :esbuild," "config :esbuild, path: \"${pkgs.esbuild}/bin/esbuild\", "
        '';

        # Deploy assets before creating release
        preInstall = ''
          # https://github.com/phoenixframework/phoenix/issues/2690
           mix do deps.loadpaths --no-deps-check, assets.deploy
        '';
      };
    });
    devShells = forAllSystems (system: let
      pkgs = nixpkgsFor system;
    in {
      default = self.devShells.${system}.dev;
      # Single shell: no MIX_ENV override (see shell.nix), so `mix test`
      # runs in :test and everything else defaults to :dev.
      dev = pkgs.callPackage ./shell.nix {
        dbName = "db_dev";
      };
    });
  };
}
