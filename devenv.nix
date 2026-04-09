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
      valgrind
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
      entry = "mix check --no-retry";
      pass_filenames = false;
      stages = [ "pre-push" ];
      files = ".ex[s]?$";
    };
    mix-compile = {
      enable = !config.devenv.isTesting;
      name = "mix-compile";
      entry = "mix compile --warnings-as-errors";
      pass_filenames = false;
      stages = [ "pre-commit" ];
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

    # AddressSanitizer tests (pre-push, catches heap OOB + use-after-free)
    asan-test = {
      enable = !config.devenv.isTesting;
      name = "asan-test";
      entry = "task test:asan";
      pass_filenames = false;
      stages = [ "pre-push" ];
      types_or = [
        "c"
        "c++"
      ];
    };

    # Valgrind test (pre-push, catches uninitialized reads that ASAN misses)
    valgrind-test = {
      enable = !config.devenv.isTesting;
      name = "valgrind-test";
      entry = "task test:valgrind";
      pass_filenames = false;
      stages = [ "pre-push" ];
      types_or = [
        "c"
        "c++"
      ];
    };
  };
}
