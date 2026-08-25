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
{
	printf 'books\t%s\n' "/tmp/krtek-sizes.db"
	# More connections than a window is tall, because that is the shape that
	# showed the list did not scroll at all: the cursor walked off the bottom and
	# everything past it was unreachable.
	i=1
	while [ "$i" -le 30 ]; do
		printf 'saved-%02d\t/tmp/krtek-%02d.db\n' "$i" "$i"
		i=$((i + 1))
	done
} > "$CONFIG/krtek/connections"

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
		# Wherever the cursor is, it is on screen. A list longer than the window
		# used to stop drawing where the room ran out, so `end` put the cursor
		# somewhere nobody could see and nothing below it could be reached.
		case "$name" in
		connections)
			far=$(SCREEN_COLS="$cols" SCREEN_ROWS="$rows" python3 tests/screen.py "" \
				'{sleep}' '{end}' '{sleep}' '{keep}' 2>&1) || fail "the list did not draw at $size"
			printf '%s' "$far" | grep -q '> saved-30' || {
				echo
				printf '%s\n' "$far" >&2
				fail "the last connection is out of sight at $size"
			}
			# Nothing is drawn over this one, so its frame has to close. It did not:
			# the list took three rows more than it had and pushed the bottom line
			# off the screen, which reads as a panel that goes on forever.
			printf '%s' "$out" | grep -q '╰' || {
				echo
				printf '%s\n' "$out" >&2
				fail "the panel's frame does not close at $size"
			}
			# On a window with room for all of it, all of it is there. Closing the
			# frame wherever the room ran out is the right answer on a short window
			# and the wrong one on a tall one, where it would quietly hide the keys
			# instead - so the tall case is checked for what it should contain.
			# The notes are the last thing drawn, so they are what falls off first
			# when the list is sized a few rows too generously - the keys survive
			# that and would not notice.
			if [ "$rows" -ge 30 ]; then
				printf '%s' "$out" | grep -q 'a file path opens SQLite' || {
					echo
					printf '%s\n' "$out" >&2
					fail "the bottom of the panel was pushed off the screen at $size"
				}
			fi
			;;
		esac
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
