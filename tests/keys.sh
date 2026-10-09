#!/bin/sh
# What the keys do, where getting it wrong costs somebody their rows or their
# session - checked against the file afterwards rather than against what the
# screen says about itself:
#
#     zig build && ./tests/keys.sh
#
# It needs no server: a SQLite file it makes for itself, and the pty harness.
# Every check here is something that was wrong once. A row ticked on one page
# and `x` pressed on the next deleted a row nobody had ticked; `x` deleted on
# one key; `q` in the key map ended the program; the page keys did nothing on a
# table shorter than a page; a field had no cursor in it.
#
# SCREEN_SLOW=3 waits three times as long for the app, on a machine that is busy.
set -e
cd "$(dirname "$0")/.."

BIN=zig-out/bin/krtek
test -x "$BIN" || { echo "$BIN is not there - zig build first" >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
# A configuration of its own: the app remembers every connection it opens.
export XDG_CONFIG_HOME="$WORK/config"
mkdir -p "$XDG_CONFIG_HOME/krtek"
# Wide enough that nothing here is cut, and short enough that forty rows are
# more than a screen of them.
export SCREEN_COLS=110 SCREEN_ROWS=18

DB="$WORK/cisla.db"
SCREEN="$WORK/screen.txt"

fail() {
	echo "FAIL: $1" >&2
	test -f "$SCREEN" && cat "$SCREEN" >&2
	exit 1
}

# The database as it is before every check: forty rows, so that ten to a page
# is four pages, and a second table wide enough to run off the side.
fresh() {
	rm -f "$DB"
	python3 - "$DB" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("create table cisla (id integer primary key, slovo text not null, pozn text)")
c.executemany("insert into cisla values (?, ?, ?)", [(i, "slovo-%02d" % i, None) for i in range(1, 41)])
names = ["a%02d" % i for i in range(1, 19)]
c.execute("create table siroka (id integer primary key, %s)" % ", ".join(n + " text" for n in names))
c.execute("insert into siroka values (1, %s)" % ", ".join("'%s'" % (n * 4) for n in names))
c.commit()
PY
}

# One answer from the file, as text.
ask() {
	python3 - "$DB" "$1" <<'PY'
import sqlite3, sys
rows = sqlite3.connect(sys.argv[1]).execute(sys.argv[2]).fetchall()
print(",".join(str(v) for row in rows for v in row))
PY
}

# The last frame after these keys.
keys() {
	python3 tests/screen.py "$@" '{keep}' > "$SCREEN" 2>&1 || fail "the harness could not run"
}

# The same in a window too short for what is being looked at.
short() {
	SCREEN_ROWS=10 python3 tests/screen.py "$@" '{keep}' > "$SCREEN" 2>&1 || fail "the harness could not run"
}

shows() {
	grep -q -- "$2" "$SCREEN" || fail "$1"
	echo "ok: $1"
}

hides() {
	grep -q -- "$2" "$SCREEN" && fail "$1"
	echo "ok: $1"
}

# --- rows that are marked ---

# The table is the first in the list, so enter opens it. Ten rows to a page,
# the third of them ticked, the page turned, and `x` pressed four rows down:
# what goes is the row that was ticked. It used to be the third row of the page
# on screen - row 13, which nobody had ticked and nobody was on.
fresh
keys "$DB" '{enter}' ':' 'limit 10' '{enter}' j j ' '
shows "a marked row is drawn with its mark" '\*  *3 slovo-03'
shows "and counted in the title" '1 marked'
keys "$DB" '{enter}' ':' 'limit 10' '{enter}' j j ' ' g n j j j j x
shows "x on marked rows asks, with how many" 'delete 1 marked row?'
test "$(ask 'select count(*) from cisla')" = "40" || fail "the question deleted something by being asked"
keys "$DB" '{enter}' ':' 'limit 10' '{enter}' j j ' ' g n j j j j x y '{enter}'
test "$(ask 'select count(*) from cisla where id = 3')" = "0" || fail "the marked row is still there"
test "$(ask 'select count(*) from cisla')" = "39" || fail "more than the marked row went: $(ask 'select count(*) from cisla') left"
echo "ok: the row that was marked is the one deleted, whatever page is on screen"
shows "and the line says so in words" '1 row deleted'

# A run of them: `V` where it starts, `V` where it ends.
fresh
keys "$DB" '{enter}' j V j j j V
shows "V and V again marks the rows between" '4 marked'
keys "$DB" '{enter}' j V j j j V '{esc}'
hides "and esc unmarks them" '[0-9] marked'

# --- one row ---

fresh
keys "$DB" '{enter}' j x
shows "x on a row waits for x again" 'x again deletes this row'
test "$(ask 'select count(*) from cisla')" = "40" || fail "one x deleted a row"
keys "$DB" '{enter}' j x j
test "$(ask 'select count(*) from cisla')" = "40" || fail "x and another key deleted a row"
echo "ok: and any other key leaves it"
keys "$DB" '{enter}' j x x
test "$(ask 'select count(*) from cisla where id = 2')" = "0" || fail "x x did not delete the row under the cursor"
test "$(ask 'select count(*) from cisla')" = "39" || fail "x x deleted more than one row"
echo "ok: x x deletes the row under the cursor, and only that"

# --- leaving ---

# Whether the program is still there is asked by pressing something after it:
# `S` draws the structure, and draws nothing in a program that has gone.
fresh
keys "$DB" '{enter}' '?' q S
shows "q in the key map closes the key map, not the program" 'structure of cisla'
keys "$DB" '{enter}' '{ctrl-c}'
shows "ctrl+c with nothing to stop says what a second one does" 'ctrl+c again quits'
keys "$DB" '{enter}' '{ctrl-c}' S
shows "and one on its own does not quit" 'structure of cisla'

# --- moving ---

fresh
keys "$DB" '{enter}'
hides "forty rows are more than this window shows" 'slovo-17'
keys "$DB" '{enter}' '{ctrl-d}'
shows "ctrl+d goes down half a screen of them" 'slovo-17'
keys "$DB" '{enter}' '{pgdn}' '{pgdn}'
shows "pgdn a whole one, on a table of one page" 'slovo-30'
keys "$DB" '{enter}' ':' 'limit 10' '{enter}' '{pgdn}' '{pgdn}'
shows "and on to the next page where the rows in hand run out" '11-20 of 40'
keys "$DB" '{enter}' ':' 'limit 10' '{enter}' g n g n g p
shows "gn and gp turn the page outright" '11-20 of 40'

# The structure is longer than a window this short, and its end is the table's
# own definition.
short "$DB" '{enter}' S
hides "the structure does not fit a short window" 'CREATE TABLE'
shows "and says which lines of it are on screen" 'lines 1-'
short "$DB" '{enter}' S G
shows "G goes to the end of it" 'CREATE TABLE'

# Columns that do not fit are said to be there, and the first one stays.
keys "$DB" j '{enter}'
shows "a table wider than the window says which columns are on screen" 'columns 1-[0-9]* of 19 ›'
keys "$DB" j '{enter}' '$'
shows "at the last one the arrow is on the other side" '‹ columns'
shows "and the first column is still there, behind a rule" 'id *│'

# --- finding ---

fresh
keys "$DB" '{enter}' / 'SLOVO-23' '{enter}'
shows "/ in the rows finds text whatever its case" '/SLOVO-23   1 of 1 on this page'
keys "$DB" '{enter}' / 'slovo-3' '{enter}' n n
shows "n goes on to the next place it is" '3 of 10 on this page'
keys "$DB" / 'sir' '{enter}'
shows "/ in the list, and enter, opens the first match" 'siroka  1-1 of 1'

# --- typing ---

# A cell, changed at its beginning: the cursor goes there and what is typed
# goes in there. There was no cursor, and no way to the beginning but backspace.
fresh
keys "$DB" '{enter}' l e '{home}' 'X' '{right}' '{right}' '{bs}' '{enter}'
test "$(ask 'select slovo from cisla where id = 1')" = "Xsovo-01" || fail "a cell edited in the middle is $(ask 'select slovo from cisla where id = 1')"
echo "ok: a value is edited where the cursor is"

# A row through the form: one tab from a value to the next value.
keys "$DB" '{enter}' i 41 '{tab}' 'nove' '{tab}' 'pozn' '{ctrl-s}'
test "$(ask 'select slovo, pozn from cisla where id = 41')" = "nove,pozn" || fail "the row from the form is $(ask 'select slovo, pozn from cisla where id = 41')"
echo "ok: tab goes from one value of a row to the next"

# The line after `:` remembers what was typed there, and nothing else.
keys "$DB" '{enter}' ':' 'limit 7' '{enter}' ':' '{up}'
shows "up after : brings back the last command" '^ :limit 7'

# --- the editor ---

fresh
keys "$DB" '{enter}' s 'selec 1' '{ctrl-s}'
shows "a statement that failed leaves the editor open" '\[INSERT\]'
shows "with what the engine said" 'syntax error'
keys "$DB" '{enter}' s 'select 41 as odpoved' '{ctrl-s}'
shows "a statement that reads stays above its rows" 's edits it again'
shows "which are under it" 'odpoved'
shows "and the line says how many came back" '^ 1 row '
keys "$DB" '{enter}' s 'select 41 as odpoved' '{ctrl-s}' s ' where 1 = 1' '{ctrl-s}'
shows "s puts the typing back after the statement" 'select 41 as odpoved where 1 = 1'
keys "$DB" '{enter}' s "insert into cisla values (50, 'x', null) returning id" '{ctrl-s}' s
hides "a statement that writes is not kept for running again" 'returning'
test "$(ask 'select count(*) from cisla where id = 50')" = "1" || fail "the insert was run $(ask 'select count(*) from cisla where id = 50') times"
echo "ok: and was run once"

# --- what is asked about first ---

keys "$WORK/neni.db"
shows "a file that is not there is asked about" 'neni.db is not there - make a new, empty database?'
test ! -e "$WORK/neni.db" || fail "the file was made by being asked about"
keys "$WORK/neni.db" n '{enter}'
test ! -e "$WORK/neni.db" || fail "the file was made after a no"
echo "ok: and is not made without a yes"
keys "$WORK/neni.db" y '{enter}'
shows "a yes opens it" 'no tables yet'

printf '# krtek connections\njedna\t%s\n' "$DB" > "$XDG_CONFIG_HOME/krtek/connections"
keys '' x
shows "removing a saved connection asks first" 'remove jedna from the list?'
grep -q '^jedna	' "$XDG_CONFIG_HOME/krtek/connections" || fail "the connection went before the answer"
keys '' x y '{enter}'
grep -q '^jedna	' "$XDG_CONFIG_HOME/krtek/connections" && fail "the connection is still in the list after a yes"
echo "ok: and goes after a yes"

echo "the keys do what they say, and nothing goes on one of them"
