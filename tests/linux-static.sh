#!/bin/sh
# Build a Linux binary that needs nothing at all: static against musl, with the
# client libraries inside it. Meant for an Alpine box or container - see
# .github/workflows for how CI does it.
#
# Alpine's postgresql-dev has a complete static libpq; its MariaDB connector
# ships only a shared library, so that one is built first, by tests/connector.sh.
# It takes about a minute.
set -e
cd "$(dirname "$0")/.."

PREFIX=${PREFIX:-/tmp/mariadb-static}
PREFIX="$PREFIX" ./tests/connector.sh

export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
zig build "-Doptimize=${OPTIMIZE:-safe}" -Dstatic -Dmariadb="$PREFIX" "$@"
file zig-out/bin/krtek

# The tests link the same libraries, so they need the same two flags - there is no
# shared library here for a plain `zig build test` to find.
if [ "${TEST:-0}" = "1" ]; then
	zig build test -Dstatic -Dmariadb="$PREFIX"
	# And malformed bytes at the protocol parsers, from a fixed seed.
	zig build fuzz -Doptimize=safe -Dstatic -Dmariadb="$PREFIX" -- 150000
fi
