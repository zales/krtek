#!/bin/sh
# The list of saved connections, when its file cannot be written:
#
#     zig build && ./tests/saved.sh
#
# There is no server to bring up: the connections are SQLite files, and what
# this is about is the file the list itself is kept in. A list that could not
# be written used to be a list that said nothing - a connection saved from the
# form, one removed, one marked read-only were each on the screen as done and
# gone the next time the program started.
#
# What it looks for: that every change somebody asked for says so when it did
# not reach the file, that it is still said after the connection the form goes
# on to open has written its own line over the first one, that the list itself
# goes on saying it, that opening a connection - which only moves it to the
# front - is not complained about, and that a file that can be written is
# written and nothing is said at all.
#
# SCREEN_SLOW=3 waits three times as long for the app, on a machine that is busy.
set -e
cd "$(dirname "$0")/.."
ROOT=$(pwd)

BIN=zig-out/bin/krtek
test -x "$BIN" || { echo "$BIN is not there - zig build first" >&2; exit 1; }

# Nothing refuses root a file, so there is no list here that root cannot write.
if [ "$(id -u)" = 0 ]; then
	echo "skipped: a file root cannot write is not something a test can make"
	exit 0
fi

WORK=$(mktemp -d)
trap 'chmod -R u+w "$WORK"; rm -rf "$WORK"' EXIT
export XDG_CONFIG_HOME="$WORK/config"
mkdir -p "$XDG_CONFIG_HOME/krtek"
LIST="$XDG_CONFIG_HOME/krtek/connections"
SCREEN="$WORK/screen.txt"
export SCREEN_ROWS=24 SCREEN_COLS=110

python3 - "$WORK" <<'PY'
import sqlite3, sys
for name in ("one", "two"):
	c = sqlite3.connect("%s/%s.db" % (sys.argv[1], name))
	c.execute("create table notes (id integer primary key, body text)")
	c.commit()
PY
# Something that is there and is not a database, for a connection that is saved
# and then cannot be opened.
mkdir "$WORK/adir"

fail() {
	echo "FAIL: $1" >&2
	test -f "$SCREEN" && cat "$SCREEN" >&2
	exit 1
}

# From the directory the files are in, so a path typed into the form is a few
# keys and not a hundred - each key is a third of a second here.
screen() {
	(cd "$WORK" && python3 "$ROOT/tests/screen.py" "$@" '{keep}') > "$SCREEN"
}

# The list as it is on disk, without the comment at its head.
listed() {
	grep -v '^#' "$LIST" | cut -f1 | tr '\n' ' '
}

SAID="the connection list could not be written"

printf 'one\tone.db\n' > "$LIST"
chmod 0444 "$LIST"

screen '' 'r'
grep -q "$SAID" "$SCREEN" || fail "a mark that was not written was not said"
grep -q "not written to" "$SCREEN" || fail "the list does not say it is not in its file"
test "$(cat "$LIST")" = "$(printf 'one\tone.db')" || fail "a file that cannot be written was written"

# Removing one is asked about first, and it is the yes that is not written.
screen '' 'd'
grep -q "remove one from the list?" "$SCREEN" || fail "a connection was removed without being asked about"
screen '' 'd' 'y' '{enter}'
grep -q "$SAID" "$SCREEN" || fail "a removal that was not written was not said"
grep -q "removed from the list" "$SCREEN" && fail "a connection still in the file was said to be removed"

# Opening one moves it to the front and nothing else. Nobody asked for that, so
# a list kept read-only on purpose opens its connections without a word.
screen '' '{enter}'
grep -q "one.db - SQLite" "$SCREEN" || fail "the connection did not open"
grep -q "$SAID" "$SCREEN" && fail "an order that was not kept was complained about"

# The form saves and then connects, and the connection writes the status line.
# What could not be saved has to be what is on it afterwards.
screen '' 'a' 'two' '{tab}' '{tab}' 'two.db' '{ctrl-s}'
grep -q "enter opens" "$SCREEN" || fail "the connection from the form did not open"
grep -q "$SAID" "$SCREEN" || fail "a connection that was not saved was not said once it had opened"

# And where it does not open, the line says why not - which is the more urgent
# of the two - and the list under it says the other.
screen '' 'a' 'bad' '{tab}' '{tab}' 'adir' '{ctrl-s}'
grep -q "cannot open adir" "$SCREEN" || fail "a file that cannot be opened was not said"
grep -q "not written to" "$SCREEN" || fail "the list does not say it is not in its file, under a failed connect"

# A target on the command line is remembered, and that is a change as well.
screen 'two.db'
grep -q "$SAID" "$SCREEN" || fail "a target that was not remembered was not said"
test "$(listed)" = "one " || fail "the file changed while it could not be written: $(listed)"

# The same things with a file that can be written: written, and nothing said.
chmod 0644 "$LIST"
screen '' 'a' 'two' '{tab}' '{tab}' 'two.db' '{ctrl-s}'
grep -q "two.db - SQLite" "$SCREEN" || fail "the connection from the form did not open"
grep -q "$SAID" "$SCREEN" && fail "a list that was written was said not to be"
test "$(listed)" = "two one " || fail "a saved connection is not in the file: $(listed)"

screen '' 'd' 'y' '{enter}'
grep -q "two removed from the list" "$SCREEN" || fail "the removal was not said"
grep -q "saved in" "$SCREEN" || fail "the list does not say where it is kept"
test "$(listed)" = "one " || fail "a removed connection is still in the file: $(listed)"

echo "a list that cannot be written says so"
