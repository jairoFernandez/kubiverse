#!/bin/sh
# Downloads the latest k8s-bridge release for this machine, checks its SHA256
# against the release's SHA256SUMS.txt and runs it. Extra args go to the bridge:
#   curl -fsSL https://raw.githubusercontent.com/jairoFernandez/kubiverse/main/bridge/get-bridge.sh | sh -s -- --allow-origin https://jairofernandez.github.io
set -eu
REPO=jairoFernandez/kubiverse

os=$(uname -s | tr '[:upper:]' '[:lower:]')
case "$os" in
  darwin|linux) ;;
  *) echo "unsupported OS: $os (on Windows use get-bridge.ps1)" >&2; exit 1 ;;
esac
arch=$(uname -m)
case "$arch" in
  x86_64|amd64) arch=amd64 ;;
  arm64|aarch64) arch=arm64 ;;
  *) echo "unsupported CPU: $arch" >&2; exit 1 ;;
esac

name=k8s-bridge-$os-$arch
dir=${KUBIVERSE_HOME:-$HOME/.kubecraft}/bin
base=https://github.com/$REPO/releases/latest/download
mkdir -p "$dir"
echo "Downloading $name (latest release of $REPO)..."
curl -fL --progress-bar -o "$dir/$name.tmp" "$base/$name"
curl -fsSL -o "$dir/SHA256SUMS.txt" "$base/SHA256SUMS.txt"

want=$(awk -v n="$name" '$2 == n { print $1 }' "$dir/SHA256SUMS.txt")
if command -v sha256sum >/dev/null 2>&1; then
  got=$(sha256sum "$dir/$name.tmp" | awk '{ print $1 }')
else
  got=$(shasum -a 256 "$dir/$name.tmp" | awk '{ print $1 }')
fi
if [ -z "$want" ] || [ "$want" != "$got" ]; then
  rm -f "$dir/$name.tmp"
  echo "checksum mismatch for $name: not running it" >&2
  exit 1
fi
chmod +x "$dir/$name.tmp"
mv "$dir/$name.tmp" "$dir/k8s-bridge"
echo "Checksum OK. Starting $dir/k8s-bridge (Ctrl+C stops it)."
exec "$dir/k8s-bridge" "$@"
