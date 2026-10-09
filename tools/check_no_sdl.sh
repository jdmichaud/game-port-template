#!/bin/sh
# Fails when the given binary contains SDL, statically or as a shared library: the agent host
# must not depend on SDL. SDL is linked statically, so the check looks for SDL's own function
# names in the binary, and for an SDL library among its dynamic dependencies.
# Run it on an unstripped build (the default): a stripped binary has no symbol names to find.
set -eu
bin="${1:?usage: check_no_sdl.sh <binary>}"
[ -f "$bin" ] || { echo "check_no_sdl: no such file: $bin" >&2; exit 2; }

if grep -q 'SDL_CreateWindow' "$bin"; then
  echo "check_no_sdl: $bin contains SDL" >&2
  exit 1
fi
if command -v ldd >/dev/null 2>&1 && ldd "$bin" 2>&1 | grep -qi 'libsdl'; then
  echo "check_no_sdl: $bin links SDL dynamically" >&2
  exit 1
fi
echo "check_no_sdl: $bin has no SDL"
