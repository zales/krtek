#!/bin/sh
# A CSV file, opened and changed through the interface, and then compared with
# what it should be - byte for byte, because that is what the file's owner will
# do with a diff:
#
#     zig build && ./tests/csv.sh
#
# The file is the one a spreadsheet in half of Europe writes: semicolons between
# the fields, CRLF at the end of the lines, a comma in the numbers, and a quoted
# value with a line break inside it. Everything about reading and writing one is
# in the unit tests of src/db/sheet.zig; what is here is the part they cannot
# reach, which is that a key pressed in the grid ends up in the file.
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
mkdir -p "$XDG_CONFIG_HOME"

FILE="$WORK/lide.csv"
SCREEN="$WORK/screen.txt"

fail() {
	echo "FAIL: $1" >&2
	test -f "$SCREEN" && cat "$SCREEN" >&2
	exit 1
}

# The file, and what it should be afterwards. `printf` rather than a here
# document, because the carriage returns are the point.
same() {
	printf "$1" > "$WORK/expected.csv"
	cmp -s "$FILE" "$WORK/expected.csv" || {
		echo "--- expected" >&2
		cat -v "$WORK/expected.csv" >&2
		echo "--- the file" >&2
		cat -v "$FILE" >&2
		fail "$2"
	}
}

HEADER='id;jmeno;plat;poznamka\r\n'
ADA='1;Ada;100,50;"prvni; se strednikem"\r\n'
GRACE='2;Grace;1200,00;\r\n'
EDSGER='10;Edsger;99,90;"dva\r\nradky"\r\n'
printf "$HEADER$ADA$GRACE$EDSGER" > "$FILE"

# Looking is not writing. Sorted by the salary, downwards: as numbers Grace is
# first, as text she would be in the middle - and a file that was only sorted
# on the screen is the file it was.
python3 tests/screen.py "$FILE" '{tab}' '{right}' '{right}' o o '{keep}' > "$SCREEN"
grep -q "order plat desc" "$SCREEN" || fail "the grid was not sorted by the column"
order=$(grep -oE "Ada|Grace|Edsger" "$SCREEN" | tr '\n' ' ')
test "$order" = "Grace Ada Edsger " || fail "a comma decimal did not sort as a number: $order"
same "$HEADER$ADA$GRACE$EDSGER" "looking at a file wrote it"
test -z "$(ls "$WORK" | grep krtek-tmp)" || fail "something was left beside the file"

# One cell, changed in place. One line of the file is different afterwards, and
# it is written the way its column writes numbers.
python3 tests/screen.py "$FILE" '{tab}' '{right}' '{right}' e \
	'{bs}' '{bs}' '{bs}' '{bs}' '{bs}' '150.5' '{enter}' '{keep}' > "$SCREEN"
grep -q "updated" "$SCREEN" || fail "the cell was not updated"
ADA='1;Ada;150,50;"prvni; se strednikem"\r\n'
same "$HEADER$ADA$GRACE$EDSGER" "a changed cell is not in the file as it should be"

# A row through the form: it goes on the end, quoted where this file needs it.
python3 tests/screen.py "$FILE" '{tab}' i 11 '{tab}' '{tab}' Karel '{tab}' '{tab}' 5 \
	'{tab}' '{tab}' 'a "b"; c' '{ctrl-s}' '{keep}' > "$SCREEN"
grep -q "row inserted" "$SCREEN" || fail "the row was not inserted"
KAREL='11;Karel;5,00;"a ""b""; c"\r\n'
same "$HEADER$ADA$GRACE$EDSGER$KAREL" "an inserted row is not in the file as it should be"

# A column through the alter form, which writes the table again: the header
# gains a name, every row a gap, and the prices keep their two digits.
python3 tests/screen.py "$FILE" a '{ctrl-n}' mesto '{ctrl-s}' '{keep}' > "$SCREEN"
grep -q "mesto" "$SCREEN" || fail "the column was not added"
same 'id;jmeno;plat;poznamka;mesto\r\n1;Ada;150,50;"prvni; se strednikem";\r\n2;Grace;1200,00;;\r\n10;Edsger;99,90;"dva\r\nradky";\r\n11;Karel;5,00;"a ""b""; c";\r\n' \
	"altering the table did not leave the file as it should be"

# A second table would be gone when the file is closed, so it is not offered.
python3 tests/screen.py "$FILE" c '{keep}' > "$SCREEN"
grep -q "a CSV file is one table" "$SCREEN" || fail "creating a table in a CSV file was not refused"

# And a file that cannot be a table says why, and is not made.
python3 tests/screen.py "$WORK/missing.csv" '{keep}' > "$SCREEN"
grep -q "No such file" "$SCREEN" || fail "a missing file did not say it was missing"
test ! -e "$WORK/missing.csv" || fail "a missing CSV file was created"

echo "a CSV file is read, changed and written back as it was found"
