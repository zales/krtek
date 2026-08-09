#!/bin/sh
# Wrap the built binary for a release: tests/package.sh <version> <target>
set -e
cd "$(dirname "$0")/.."
version="$1"
target="$2"
name="krtek-$version-$target"
mkdir -p "$name"
cp zig-out/bin/krtek README.md "$name/"
tar czf "$name.tar.gz" "$name"
if command -v shasum >/dev/null 2>&1; then
	shasum -a 256 "$name.tar.gz" > "$name.tar.gz.sha256"
else
	sha256sum "$name.tar.gz" > "$name.tar.gz.sha256"
fi
ls -la "$name.tar.gz"
