#!/usr/bin/env bash
# Shared helpers sourced by the repo's build and verification scripts.

# Point Swift builds at a shared clang module cache and prefer the full Xcode
# toolchain when one is installed.
setup_swift_build_env() {
  export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/private/tmp/metagent-clang-cache}"
  if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  fi
}
