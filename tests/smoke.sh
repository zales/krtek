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

python3 - <<'PY'
import sqlite3, os
if os.path.exists("smoke.db"):
	os.remove("smoke.db")
c = sqlite3.connect("smoke.db")
c.execute("create table notes (id integer primary key, body text)")
c.execute("insert into notes (body) values ('it drew this')")
c.commit()
PY

# The screen is read after a fixed wait, and the wait is a guess: six tenths of
# a second, which the first run of a binary that has only just been built can
# overrun on a slow machine. The Intel Mac in CI once had nothing on screen by
# then, with a build that was fine, and failed the job that every release waits
# for. So it is asked up to three times, each wait twice the last - and each in
# a configuration nobody has started in, because a second try in the first
# one's directory would not be a first start any more.
base=${SCREEN_SLOW:-1}
for times in 1 2 4; do
	export XDG_CONFIG_HOME="$CONFIG/$times"
	mkdir -p "$XDG_CONFIG_HOME"
	slow=$(awk "BEGIN { print $base * $times }")
	SCREEN_SLOW=$slow python3 tests/screen.py smoke.db '{keep}' | tee smoke.txt
	if grep -q "it drew this" smoke.txt; then
		echo "the binary runs and draws"
		exit 0
	fi
	echo "--- the table was not on screen after $(awk "BEGIN { print 0.6 * $slow }") s" >&2
done
echo "FAIL: the binary starts and draws nothing" >&2
exit 1
