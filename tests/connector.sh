#!/bin/sh
# Build the MariaDB connector as a static library that can log in by itself:
#
#     ./tests/connector.sh        # into /tmp/mariadb-static, or $PREFIX
#
# and then `zig build -Dstatic -Dmariadb=/tmp/mariadb-static`, with
# /tmp/mariadb-static/lib/pkgconfig in PKG_CONFIG_PATH. It takes about a minute,
# and nothing at all the second time.
#
# Nobody ships an archive that will do. Alpine has only the shared library.
# Homebrew has an archive, built the way the connector builds by default: every
# way of logging in but the oldest is a plugin it loads from a directory at run
# time - one that is only on the machine that built it. So a binary with that
# archive inside could log in only with mysql_native_password, and MySQL 8 asks
# for caching_sha2_password by default. On Linux it said `Dynamic loading not
# supported`; on a Mac it went looking in Homebrew's Cellar, which whoever
# downloaded the release does not have.
set -e

CONNECTOR=${CONNECTOR:-3.4.9}
PREFIX=${PREFIX:-/tmp/mariadb-static}

if [ -f "$PREFIX/lib/libmariadb.a" ]; then
	exit 0
fi

# What only a Mac has to be told. OpenSSL there is Homebrew's, which is not
# where cmake looks. zlib is the system's: left alone the connector builds the
# copy it carries, which would be a second zlib in a binary whose libpq uses the
# system's. And a warning is not an error: the connector makes it one, and the
# compiler here is whichever Xcode the machine has this month - 3.4.5 stopped
# building on a newer clang over a single warning.
openssl=
mac=
if [ "$(uname)" = Darwin ]; then
	openssl=$(brew --prefix openssl@3)
	mac="-DOPENSSL_ROOT_DIR=$openssl -DWITH_EXTERNAL_ZLIB=ON -DCMAKE_COMPILE_WARNING_AS_ERROR=OFF"
fi

echo "building the MariaDB connector $CONNECTOR as a static library"
curl -fsSL "https://github.com/mariadb-corporation/mariadb-connector-c/archive/refs/tags/v$CONNECTOR.tar.gz" -o /tmp/connector.tar.gz
mkdir -p /tmp/connector && tar xzf /tmp/connector.tar.gz -C /tmp/connector --strip-components=1
# The ways of logging in that a server may ask for, inside the archive.
# caching_sha2_password and sha256_password are MySQL's, ed25519 is MariaDB's.
cmake -S /tmp/connector -B /tmp/connector/build -Wno-dev \
	-DCMAKE_BUILD_TYPE=Release -DWITH_SSL=OPENSSL -DWITH_UNIT_TESTS=OFF \
	-DCLIENT_PLUGIN_CACHING_SHA2_PASSWORD=STATIC \
	-DCLIENT_PLUGIN_SHA256_PASSWORD=STATIC \
	-DCLIENT_PLUGIN_CLIENT_ED25519=STATIC $mac >/dev/null
cmake --build /tmp/connector/build --target mariadbclient \
	-j"$(nproc 2>/dev/null || sysctl -n hw.ncpu)" >/dev/null
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
Libs.private: ${openssl:+-L$openssl/lib }-lssl -lcrypto -lz
Cflags: -I\${includedir}
PC
