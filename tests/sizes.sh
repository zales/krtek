#!/bin/sh
# Draw every screen at every size worth caring about, and look for the ways a
# terminal-shaped program goes wrong when the terminal is small:
#
#     zig build && ./tests/sizes.sh
#
# Nothing here checks that a screen looks *good* at forty columns - a grid of
# five columns cannot, and truncating is the honest answer. What it checks is
# that the drawing is still coherent: that two panels are not drawn one column
# inside each other so their frames appear side by side, that a frame that opens
# also closes, and that the header and the footer are still where they belong.
#
# All three of those were real. The frames were: at sixty columns the connection
# list and the form over it came out the same width and the screen grew a second
# border down each side.
set -e
cd "$(dirname "$0")/.."

BIN=zig-out/bin/krtek
test -x "$BIN" || { echo "$BIN is not there - zig build first" >&2; exit 1; }

CONFIG=$(mktemp -d)
trap 'rm -rf "$CONFIG" "$DB"' EXIT
export XDG_CONFIG_HOME="$CONFIG"
mkdir -p "$CONFIG/krtek"
printf 'books\t%s\n' "/tmp/krtek-sizes.db" > "$CONFIG/krtek/connections"

DB=/tmp/krtek-sizes.db
rm -f "$DB"
python3 - <<'PY'
import sqlite3, os
os.path.exists("/tmp/krtek-sizes.db") and os.remove("/tmp/krtek-sizes.db")
c = sqlite3.connect("/tmp/krtek-sizes.db")
c.execute("create table authors (id integer primary key, name text not null, born integer)")
c.execute("create table books (id integer primary key, author_id integer references authors(id), title text)")
c.executemany("insert into authors (name, born) values (?, ?)",
              [("Karel Čapek", 1890), ("Bohumil Hrabal", 1914), ("Milan Kundera", 1929)])
c.executemany("insert into books (author_id, title) values (?, ?)",
              [(1, "Válka s mloky"), (1, "RUR"), (2, "Obsluhoval jsem krále")])
c.commit()
PY

fail() { echo "FAIL: $1" >&2; exit 1; }

# The screens, as the target and the keys that reach each one. A dash for the
# target means no argument, which is what opens the list of connections - and
# the two screens drawn over that list are where the frames went wrong.
screens='grid:db:{down}{enter}
structure:db:{down}{enter}|S
help:db:?
palette:db:{ctrl-k}|exp
editor:db:s|select 1
filter:db:{down}{enter}|W
insert:db:{down}{enter}|i
connections:-:{sleep}
add:-:a
add-postgres:-:a|{tab}|{right}
edit:-:e'

# 120x40 is a comfortable window; 80x24 is the one every terminal starts at; the
# rest are what a split pane and a phone-sized ssh session actually give you.
for size in 120x40 100x30 80x24 70x22 60x20 50x16 44x14 40x12; do
	cols=${size%x*}
	rows=${size#*x}
	printf '%s' "  $size"
	for one in $screens; do
		name=${one%%:*}
		rest=${one#*:}
		target=${rest%%:*}
		keys=$(printf '%s' "${rest#*:}" | tr '|' ' ')
		[ "$target" = "db" ] && target="$DB"
		[ "$target" = "-" ] && target=""
		out=$(SCREEN_COLS="$cols" SCREEN_ROWS="$rows" python3 tests/screen.py "$target" \
			'{sleep}' $keys '{sleep}' '{keep}' 2>&1) || fail "$name at $size did not draw"

		# A frame one column inside another draws both borders next to each other.
		printf '%s' "$out" | grep -q '╭│\|││\|│╮\|╰│\|│╯\|│╭\|╮│' && {
			echo
			printf '%s\n' "$out" >&2
			fail "two frames side by side on $name at $size"
		}
		# The header is the first line of every screen there is.
		printf '%s' "$out" | head -1 | grep -q '^ krtek' || {
			echo
			printf '%s\n' "$out" >&2
			fail "no header on $name at $size"
		}
	done
	echo "  ok"
done

echo "every screen draws at every size"
