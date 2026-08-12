#!/bin/sh
# Wrap the built binary as a Debian package:
#
#     packaging/deb.sh <version> <arch>       # 0.3.0 or v0.3.0, and amd64|arm64
#
# The binary is static, so the package Depends on nothing at all: it installs on
# any Debian or Ubuntu of any age, and on anything that reads a .deb.
#
# Needs dpkg-deb, which is on the machine that builds the .deb rather than in the
# Alpine container that builds the binary - see .github/workflows/release.yml.
set -e
cd "$(dirname "$0")/.."

version=${1#v}   # a Debian version does not start with a v
arch=$2
: "${version:?usage: packaging/deb.sh <version> <arch>}"
: "${arch:?usage: packaging/deb.sh <version> <arch>}"
maintainer=${MAINTAINER:-"Ondrej Zalesky <o.zalesky@gmail.com>"}

binary=zig-out/bin/krtek
test -x "$binary" || { echo "$binary is not there - build first" >&2; exit 1; }

root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
install -D -m 0755 "$binary" "$root/usr/bin/krtek"
install -D -m 0644 docs/krtek.1 "$root/usr/share/man/man1/krtek.1"
gzip -9n "$root/usr/share/man/man1/krtek.1"
install -D -m 0644 README.md "$root/usr/share/doc/krtek/README.md"
install -D -m 0644 LICENSE "$root/usr/share/doc/krtek/LICENSE"

# What is inside the binary, and what that means for whoever passes it on: the
# MariaDB connector is LGPL, which asks that its object code can be replaced.
# It can - the whole thing builds from source with one command - so this file
# says where from.
cat > "$root/usr/share/doc/krtek/copyright" <<'EOF'
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: krtek
Source: https://github.com/zales/krtek

Files: *
Copyright: 2026 Ondrej Zalesky
License: Expat
 Permission is hereby granted, free of charge, to any person obtaining a copy
 of this software and associated documentation files (the "Software"), to deal
 in the Software without restriction, including without limitation the rights
 to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 copies of the Software, and to permit persons to whom the Software is
 furnished to do so, subject to the following conditions:
 .
 The above copyright notice and this permission notice shall be included in
 all copies or substantial portions of the Software.
 .
 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
 IN THE SOFTWARE.

Files: vendor/sqlite3.c
Copyright: SQLite authors
License: public-domain
 SQLite is in the public domain. See https://sqlite.org/copyright.html

Files: linked-in libraries
Copyright: PostgreSQL Global Development Group; MariaDB Corporation Ab and
 others; The OpenSSL Project
License: PostgreSQL and LGPL-2.1+ and Apache-2.0
 This binary is statically linked against libpq (PostgreSQL licence), the
 MariaDB Connector/C (LGPL 2.1 or later), OpenSSL (Apache 2.0) and zlib.
 .
 For the LGPL part: the linked-in object code can be replaced with another
 version of the connector by building krtek from its source, which is public
 at the address above and needs one command -
 .
     zig build -Dstatic -Dmariadb=<prefix of the connector>
 .
 On Debian systems the full text of the LGPL 2.1 is in
 /usr/share/common-licenses/LGPL-2.1 and of Apache 2.0 in
 /usr/share/common-licenses/Apache-2.0
EOF

# A native Debian changelog would be a lie - the releases are krtek's own - so
# this points at where they are written down.
mkdir -p "$root/usr/share/doc/krtek"
cat > "$root/usr/share/doc/krtek/changelog.Debian" <<EOF
krtek ($version-1) unstable; urgency=low

  * krtek $version. What changed is in the release notes:
    https://github.com/zales/krtek/releases/tag/v$version

 -- $maintainer  $(date -R 2>/dev/null || date)
EOF
gzip -9n "$root/usr/share/doc/krtek/changelog.Debian"

size=$(du -ks "$root/usr" | cut -f1)
mkdir -p "$root/DEBIAN"
cat > "$root/DEBIAN/control" <<EOF
Package: krtek
Version: $version-1
Architecture: $arch
Maintainer: $maintainer
Installed-Size: $size
Section: database
Priority: optional
Homepage: https://github.com/zales/krtek
Description: database manager for the terminal
 krtek browses, edits, alters, dumps and imports a database on a text screen,
 with SQLite, PostgreSQL, MySQL/MariaDB, Redis, Kafka, S3, Azure Blob and
 RabbitMQ behind one interface.
 .
 It needs nothing installed: the client libraries are linked into the binary,
 which is static all the way down, and the rest are spoken directly.
 .
 A statement that takes too long can be given up on, a password is kept only
 where the connection says, and ctrl+k finds any command by a few letters of
 its name.
EOF

out="krtek_${version}-1_${arch}.deb"
rm -f "$out"
# --root-owner-group instead of fakeroot: everything in the package is root's.
dpkg-deb --build --root-owner-group "$root" "$out" >/dev/null
if command -v shasum >/dev/null 2>&1; then
	shasum -a 256 "$out" > "$out.sha256"
else
	sha256sum "$out" > "$out.sha256"
fi
dpkg-deb --info "$out" | sed -n '1,6p'
ls -la "$out"
