#!/usr/bin/env bash
# Installs Swift's Static Linux SDK (musl), which `build-linux-cli.sh --static`
# uses to produce a self-contained `metagent` binary. The SDK must match the
# toolchain exactly, so CI pins the swift:6.2.4 image alongside this checksum
# (from swiftlang/swift-org-website _data/builds/swift_releases.yml).
set -euo pipefail

toolchain="6.2.4"
sdk_version="0.1.0"
checksum="24bdf84495dd31a6de2eb679647c1982b747bfbfe1a2060c779d84dcecd902a4"

installed="$(swift --version 2>&1 | sed -n 's/^Swift version \([0-9.]*\).*/\1/p' | head -n 1)"
if [[ "$installed" != "$toolchain" ]]; then
  echo "install-static-linux-sdk.sh: toolchain is Swift $installed; this SDK needs Swift $toolchain" >&2
  exit 1
fi

if swift sdk list 2>/dev/null | grep -q "swift-${toolchain}-RELEASE_static-linux-${sdk_version}"; then
  echo "Static Linux SDK ${sdk_version} for Swift ${toolchain} already installed"
  exit 0
fi

swift sdk install \
  "https://download.swift.org/swift-${toolchain}-release/static-sdk/swift-${toolchain}-RELEASE/swift-${toolchain}-RELEASE_static-linux-${sdk_version}.artifactbundle.tar.gz" \
  --checksum "$checksum"
