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
      gcc
      # C++ linting, formatting, and sanitizer support
      clang
      clang-tools # provides clang-format, clang-tidy
      llvm # provides llvm-symbolizer for ASan stack traces
      cppcheck

      go-task
    ]
    ++ lib.optionals pkgs.stdenv.isLinux [ inotify-tools ];

  git-hooks.hooks = {
    mix-format = {
      enable = !config.devenv.isTesting;
      name = "mix-format";
      files = ".ex[s]?$";
      entry = "mix format";
    };
    mix-check = {
      enable = !config.devenv.isTesting;
      name = "mix-check";
      entry = "mix check";
      pass_filenames = false;
      stages = [
        "pre-commit"
        "pre-push"
      ];
      files = ".ex[s]?$";
    };

    prettier.enable = !config.devenv.isTesting;
    nixfmt-rfc-style.enable = !config.devenv.isTesting;
    clang-format.enable = !config.devenv.isTesting;

    # C++ static analysis (cppcheck + clang-tidy via task)
    cpp-check = {
      enable = !config.devenv.isTesting;
      name = "cpp-check";
      entry = "task cpp:check";
      pass_filenames = false;
      types_or = [
        "c"
        "c++"
      ];
    };
  };
}
