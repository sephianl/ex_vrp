#!/usr/bin/env bash
# Puts the interpreter-only Erlang (interpreter_erlang.nix) in the Nix store, taking it
# from the Nix binary cache directory given as $1 when that holds it, and leaves it there
# for the next run. Building it from source takes about twelve minutes; an unusable cache
# falls back to that build rather than failing.
set -euo pipefail

cache_dir="$1"
derivation="$(dirname "$0")/interpreter_erlang.nix"
out_path="$(nix eval --raw -f "$derivation" outPath)"

if [ -d "$cache_dir" ]; then
  nix copy --no-check-sigs --from "file://$cache_dir" "$out_path" ||
    echo "the cached interpreter-only Erlang could not be restored; building it"
fi

nix build --no-link -f "$derivation"
nix copy --to "file://$cache_dir?compression=zstd" "$out_path"
