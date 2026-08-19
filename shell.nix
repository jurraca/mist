{
  pkgs,
  dbName,
  beamPackages,
}: let
  # define packages to install
  basePackages = with pkgs; [
    elixir
    hex
    sqlite
    nodejs
    esbuild
    tailwindcss
    autoreconfHook
  ];

  # Add basePackages + optional system packages per system
  inputs = with pkgs;
    basePackages
    ++ lib.optionals stdenv.isLinux [inotify-tools]
    ++ lib.optionals stdenv.isDarwin
    (with darwin.apple_sdk.frameworks; [CoreFoundation CoreServices]);

  # define shell startup command
  hooks = ''
    # this allows mix to work on the local directory
    mkdir -p .nix-mix .nix-hex
    export MIX_HOME=$PWD/.nix-mix
    export HEX_HOME=$PWD/.nix-mix
    export PATH=$MIX_HOME/bin:$HEX_HOME/bin:$PATH

    # NOTE: MIX_ENV is deliberately NOT set here. Forcing it (e.g. to "dev")
    # overrides `mix test`'s preferred :test env, which breaks the test run
    # (no Ecto sandbox pool, test/support not on the compile path). Mix
    # defaults to dev on its own, so nothing needs exporting.

    export LANG=en_US.UTF-8
    # keep your shell history in iex
    export ERL_AFLAGS="-kernel shell_history enabled"
  '';
in
  pkgs.mkShell {
    buildInputs = inputs;
    shellHook = hooks;
  }
