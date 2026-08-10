#!/bin/sh
# Build a Linux binary that needs nothing at all: static against musl, with the
# client libraries inside it. Meant for an Alpine box or container - see
# .github/workflows for how CI does it.
#
# Alpine's postgresql-dev has a complete static libpq; its MariaDB connector
# ships only a shared library, so that one is built here. It takes about a minute.
set -e
cd "$(dirname "$0")/.."

CONNECTOR=${CONNECTOR:-3.4.5}
PREFIX=${PREFIX:-/tmp/mariadb-static}

if [ ! -f "$PREFIX/lib/libmariadb.a" ]; then
	echo "building the MariaDB connector $CONNECTOR as a static library"
	curl -fsSL "https://github.com/mariadb-corporation/mariadb-connector-c/archive/refs/tags/v$CONNECTOR.tar.gz" -o /tmp/connector.tar.gz
	mkdir -p /tmp/connector && tar xzf /tmp/connector.tar.gz -C /tmp/connector --strip-components=1
	cmake -S /tmp/connector -B /tmp/connector/build -Wno-dev \
		-DCMAKE_BUILD_TYPE=Release -DWITH_SSL=OPENSSL -DWITH_UNIT_TESTS=OFF >/dev/null
	cmake --build /tmp/connector/build --target mariadbclient -j"$(nproc)" >/dev/null
	mkdir -p "$PREFIX/lib" "$PREFIX/include/mariadb" "$PREFIX/lib/pkgconfig"
	# The archive is called mariadbclient; everything else calls it mariadb.
	cp /tmp/connector/build/libmariadb/libmariadbclient.a "$PREFIX/lib/libmariadb.a"
	cp -r /tmp/connector/include/. "$PREFIX/include/mariadb/"
	cp /tmp/connector/build/include/*.h "$PREFIX/include/mariadb/" 2>/dev/null || true
	cat > "$PREFIX/lib/pkgconfig/libmariadb.pc" <<PC
prefix=$PREFIX
libdir=\${prefix}/lib
includedir=\${prefix}/include/mariadb
Name: libmariadb
Description: MariaDB Connector/C, built static
Version: $CONNECTOR
Libs: -L\${libdir} -lmariadb
Libs.private: -lssl -lcrypto -lz
Cflags: -I\${includedir}
PC
fi

export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
zig build "-Doptimize=${OPTIMIZE:-ReleaseSafe}" -Dstatic -Dmariadb="$PREFIX" "$@"
file zig-out/bin/krtek
