#!/bin/sh
# Wrap the built binary for a release: tests/package.sh <version> <target>
set -e
cd "$(dirname "$0")/.."
version="$1"
target="$2"
name="krtek-$version-$target"
mkdir -p "$name"
# The man page travels with the binary: the Homebrew formula installs it.
cp zig-out/bin/krtek README.md docs/krtek.1 "$name/"
tar czf "$name.tar.gz" "$name"
if command -v shasum >/dev/null 2>&1; then
	shasum -a 256 "$name.tar.gz" > "$name.tar.gz.sha256"
else
	sha256sum "$name.tar.gz" > "$name.tar.gz.sha256"
fi
ls -la "$name.tar.gz"
