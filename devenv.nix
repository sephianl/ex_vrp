{
  pkgs,
  lib,
  config,
  inputs,
  ...
}:

let
  system = "x86_64-linux";
in
{
  process.managers.process-compose.tui.enable = false;
  cachix.enable = false;

  languages = {
    elixir = {
      enable = true;
      package = pkgs.elixir_1_19;
    };
  };

  packages =
    with pkgs;
    [
      gnumake
    ]
    ++ lib.optionals pkgs.stdenv.isLinux [ inotify-tools ];

  git-hooks.hooks = {
    mix-format = {
      enable = !config.devenv.isTesting;
      name = "mix-format";
      files = ".ex[s]?$";
      entry = "mix format";
    };
    mix-credo = {
      enable = !config.devenv.isTesting;
      name = "mix-credo";
      entry = "mix credo";
      pass_filenames = false;
      stages = [ "pre-push" ];
      files = ".ex$";
    };

    prettier.enable = !config.devenv.isTesting;
    nixfmt-rfc-style.enable = !config.devenv.isTesting;
  };
}
