#!/bin/sh
# Fails when the given binary depends on an SDL shared library: the agent host must not
# depend on SDL. A fully static binary passes.
set -eu
bin="${1:?usage: check_no_sdl.sh <binary>}"
[ -f "$bin" ] || { echo "check_no_sdl: no such file: $bin" >&2; exit 2; }

if command -v ldd >/dev/null 2>&1; then
  deps="$(ldd "$bin" 2>&1 || true)"
  case "$deps" in
    *"not a dynamic executable"*|*"statically linked"*) echo "check_no_sdl: $bin is static"; exit 0 ;;
  esac
  if printf '%s\n' "$deps" | grep -qi 'sdl'; then
    echo "check_no_sdl: $bin links SDL:" >&2
    printf '%s\n' "$deps" | grep -i 'sdl' >&2
    exit 1
  fi
  echo "check_no_sdl: $bin has no SDL dependency"
  exit 0
fi

# Without ldd, inspect the dynamic section directly.
if command -v readelf >/dev/null 2>&1; then
  if readelf -d "$bin" 2>/dev/null | grep -i 'NEEDED' | grep -qi 'sdl'; then
    echo "check_no_sdl: $bin links SDL" >&2
    exit 1
  fi
  echo "check_no_sdl: $bin has no SDL dependency"
  exit 0
fi

echo "check_no_sdl: neither ldd nor readelf available" >&2
exit 2
