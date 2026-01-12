{pkgs}: {
  deps = [
    pkgs.nodejs_20
    pkgs.postgresql
    pkgs.elixir
    pkgs.autoreconfHook
    pkgs.inotify-tools
    
  ];
}