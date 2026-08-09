#!/bin/sh
# Download the SQLite amalgamation into vendor/ - it is not kept in the repository.
set -e
cd "$(dirname "$0")"

VERSION=3500400 # 3.50.4
YEAR=2025

if [ -f vendor/sqlite3.c ]; then
	echo "vendor/sqlite3.c is already there"
	exit 0
fi

mkdir -p vendor
cd vendor
curl -sSfO "https://sqlite.org/$YEAR/sqlite-amalgamation-$VERSION.zip"
unzip -q -o "sqlite-amalgamation-$VERSION.zip"
mv "sqlite-amalgamation-$VERSION"/sqlite3.c "sqlite-amalgamation-$VERSION"/sqlite3.h .
rm -r "sqlite-amalgamation-$VERSION" "sqlite-amalgamation-$VERSION.zip"
grep -m1 'define SQLITE_VERSION ' sqlite3.h
