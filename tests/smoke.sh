#!/bin/sh
# Does the binary start, find its terminal and draw something? The harness feeds
# it keys through a pseudo terminal and reads back what it drew, so this catches
# a build that links and then falls over on the first frame.
set -e
cd "$(dirname "$0")/.."

# A configuration of its own. The app remembers every connection it opens, and a
# test that opened one into the user's own list would edit a file it was never
# asked to touch - which is exactly what this did until somebody noticed.
CONFIG=$(mktemp -d)
trap 'rm -rf "$CONFIG"' EXIT
export XDG_CONFIG_HOME="$CONFIG"

python3 - <<'PY'
import sqlite3, os
if os.path.exists("smoke.db"):
	os.remove("smoke.db")
c = sqlite3.connect("smoke.db")
c.execute("create table notes (id integer primary key, body text)")
c.execute("insert into notes (body) values ('it drew this')")
c.commit()
PY

python3 tests/screen.py smoke.db '{keep}' | tee smoke.txt
grep -q "it drew this" smoke.txt
echo "the binary runs and draws"
