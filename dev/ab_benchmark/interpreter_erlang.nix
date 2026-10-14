# The Erlang that `mix bench.speed` runs each solve on under Callgrind: devenv's own
# Erlang (same nixpkgs pin, so the same OTP that compiled _build), built without the JIT,
# which Valgrind cannot run.
let
  lock = builtins.fromJSON (builtins.readFile ../../devenv.lock);
  pkgs = import (builtins.fetchTree lock.nodes.nixpkgs.locked) { };
in
pkgs.beamPackages.erlang.overrideAttrs (old: {
  configureFlags = old.configureFlags ++ [ "--disable-jit" ];
  doCheck = false;
})
