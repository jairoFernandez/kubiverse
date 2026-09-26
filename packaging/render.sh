#!/usr/bin/env bash
# Fills the Homebrew formula/cask and the winget manifest with a release's
# version and SHA-256s.  packaging/render.sh 0.1.8 dist/out out/packaging
set -euo pipefail
version=$1 files=$2 out=$3
mkdir -p "$out"
sha() { if [ -f "$files/$1" ]; then shasum -a 256 "$files/$1" | cut -d' ' -f1; else echo "MISSING-$1"; fi; }
for f in packaging/homebrew/kubiverse-bridge.rb packaging/homebrew/kubiverse.rb packaging/winget/JairoFernandez.KubiverseBridge.yaml; do
  sed -e "s/@VERSION@/$version/g" \
      -e "s/@SHA_DARWIN_ARM64@/$(sha kubiverse-bridge-darwin-arm64)/" \
      -e "s/@SHA_DARWIN_AMD64@/$(sha kubiverse-bridge-darwin-amd64)/" \
      -e "s/@SHA_LINUX_ARM64@/$(sha kubiverse-bridge-linux-arm64)/" \
      -e "s/@SHA_LINUX_AMD64@/$(sha kubiverse-bridge-linux-amd64)/" \
      -e "s/@SHA_WINDOWS_AMD64@/$(sha kubiverse-bridge-windows-amd64.exe)/" \
      -e "s/@SHA_WINDOWS_ARM64@/$(sha kubiverse-bridge-windows-arm64.exe)/" \
      -e "s/@SHA_MACOS_APP@/$(sha kubiverse-macos.zip)/" \
      "$f" > "$out/$(basename "$f")"
done
if grep -l MISSING- "$out"/* >/dev/null; then echo "some release files are missing:"; grep -h MISSING- "$out"/*; exit 1; fi
echo "rendered into $out"
