#!/bin/sh
# Installs the headless `metagent` helper (CLI + MCP server) on Linux, for
# servers and cloud agent containers. Suitable for a container setup script:
#
#   curl -fsSL https://raw.githubusercontent.com/ianwatts22/metagent/main/scripts/install-linux.sh | sh
#   curl -fsSL .../install-linux.sh | sh -s -- --mcp claude
#
# Options:
#   --version vX.Y.Z   install a specific release (default: latest)
#   --dir PATH         install directory (default: $METAGENT_INSTALL_DIR or ~/.local/bin)
#   --mcp CLIENT       also register the MCP server with `claude` or `codex`
set -eu

repo="ianwatts22/metagent"
version="latest"
install_dir="${METAGENT_INSTALL_DIR:-$HOME/.local/bin}"
mcp_clients=""

while [ $# -gt 0 ]; do
  case "$1" in
    --version) version="$2"; shift 2 ;;
    --dir) install_dir="$2"; shift 2 ;;
    --mcp) mcp_clients="$mcp_clients $2"; shift 2 ;;
    *) echo "metagent install: unknown option $1" >&2; exit 2 ;;
  esac
done

[ "$(uname -s)" = "Linux" ] || {
  echo "metagent install: this script is for Linux; on macOS install the app from https://metagent.sh" >&2
  exit 1
}

case "$(uname -m)" in
  x86_64 | amd64) arch="x86_64" ;;
  aarch64 | arm64) arch="aarch64" ;;
  *) echo "metagent install: unsupported architecture $(uname -m)" >&2; exit 1 ;;
esac

archive="metagent-linux-$arch.tar.gz"
if [ "$version" = "latest" ]; then
  base="https://github.com/$repo/releases/latest/download"
else
  base="https://github.com/$repo/releases/download/$version"
fi

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

echo "Downloading $archive ($version)..."
curl -fsSL "$base/$archive" -o "$workdir/$archive"
curl -fsSL "$base/$archive.sha256" -o "$workdir/$archive.sha256"
(cd "$workdir" && sha256sum -c "$archive.sha256" >/dev/null) || {
  echo "metagent install: checksum mismatch for $archive" >&2
  exit 1
}

tar -xzf "$workdir/$archive" -C "$workdir"
mkdir -p "$install_dir"
install -m 0755 "$workdir/metagent" "$install_dir/metagent"

if ! "$install_dir/metagent" --help >/dev/null 2>&1; then
  echo "metagent install: the binary did not start. It needs glibc 2.35+ and libcurl4" >&2
  echo "(Debian/Ubuntu: apt-get install -y libcurl4)." >&2
  exit 1
fi
echo "Installed $install_dir/metagent"

case ":$PATH:" in
  *":$install_dir:"*) ;;
  *) echo "Note: $install_dir is not on PATH; add it to use \`metagent\` directly." ;;
esac

for client in $mcp_clients; do
  "$install_dir/metagent" mcp install --client "$client" --apply
done
