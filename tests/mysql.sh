#!/bin/sh
# Bring up a MySQL and check the driver against it:
#
#     zig build && ./tests/mysql.sh
#
# MariaDB's connector talks to both, and this checks the things that make MySQL
# different from the other two SQL engines here: a database *is* a schema, so
# `#` switches between databases; the session runs in ANSI_QUOTES and
# NO_BACKSLASH_ESCAPES so that one shared way of quoting is right for all three;
# and an alter is a CHANGE COLUMN, which renames and retypes in one statement.
set -e
cd "$(dirname "$0")/.."

NAME=${NAME:-krtek-mysql-test}
IMAGE=${IMAGE:-mysql:8}
PASSWORD=${PASSWORD:-krtek}
PORT=${PORT:-3307}

BIN=zig-out/bin/krtek
test -x "$BIN" || { echo "$BIN is not there - zig build first" >&2; exit 1; }

CONFIG=$(mktemp -d)
trap 'docker rm -f "$NAME" >/dev/null 2>&1 || true; rm -rf "$CONFIG"' EXIT
export XDG_CONFIG_HOME="$CONFIG"

echo "starting $IMAGE"
docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --name "$NAME" -p "$PORT:3306" -e "MYSQL_ROOT_PASSWORD=$PASSWORD" "$IMAGE" >/dev/null

# -i, or the heredoc below is written to a docker client that keeps it to itself
# and the client inside the container reads nothing at all.
MYSQL="docker exec -i $NAME mysql -uroot -p$PASSWORD --default-character-set=utf8mb4"
printf 'waiting for the server'
tries=0
until echo 'SELECT 1' | $MYSQL >/dev/null 2>&1; do
	tries=$((tries + 1))
	if [ "$tries" -gt 90 ]; then
		echo " gave up" >&2; docker logs --tail 30 "$NAME" >&2; exit 1
	fi
	printf .
	sleep 2
done
echo " up"

$MYSQL >/dev/null 2>&1 <<'SQL'
CREATE DATABASE demo CHARACTER SET utf8mb4;
CREATE DATABASE archiv;
USE demo;
CREATE TABLE zakaznici (
  id int NOT NULL AUTO_INCREMENT PRIMARY KEY,
  jmeno varchar(80) NOT NULL,
  email varchar(120) UNIQUE,
  mesto varchar(60),
  vernostni tinyint(1) NOT NULL DEFAULT 0,
  zalozeno datetime NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;
CREATE INDEX ix_mesto ON zakaznici (mesto);
CREATE TABLE objednavky (
  id int NOT NULL AUTO_INCREMENT PRIMARY KEY,
  zakaznik_id int NOT NULL,
  castka decimal(12,2) NOT NULL,
  data json,
  CONSTRAINT fk_zakaznik FOREIGN KEY (zakaznik_id) REFERENCES zakaznici(id) ON DELETE CASCADE
) ENGINE=InnoDB;
CREATE VIEW velke AS SELECT id, castka FROM objednavky WHERE castka > 1000;
INSERT INTO zakaznici (jmeno, email, mesto, vernostni) VALUES
 ('Řehoř Dvořák', 'rehor@example.cz', 'Ostrava', 1),
 ('Ludmila Čermáková', 'ludmila@example.cz', 'Plzeň', 0),
 ('Šimon Kučera', NULL, 'Liberec', 0);
INSERT INTO objednavky (zakaznik_id, castka, data) VALUES
 (1, 2499.50, '{"kanal":"web"}'), (2, 129.00, NULL), (1, 8100.00, '{"kanal":"telefon"}');
SQL

# --- and now the driver ---

fail() { echo "FAIL: $1" >&2; exit 1; }

ROOT="mysql://root:$PASSWORD@127.0.0.1:$PORT"

check() {
	what=$1; target=$2; wanted=$3; table=$4
	out=$(zig build dbcheck -- "$target" $table 2>&1 || true)
	printf '%s' "$out" | grep -q "$wanted" || {
		echo "--- what came back:" >&2; printf '%s\n' "$out" >&2; fail "$what"
	}
	echo "ok: $what"
}

screen() {
	what=$1; shift; wanted=$1; shift
	out=$(SCREEN_COLS=110 SCREEN_ROWS=20 python3 tests/screen.py "$ROOT/demo" "$@" '{keep}' 2>&1 || true)
	printf '%s' "$out" | grep -q "connect to a database" && {
		echo "--- the server was not there; the app fell back to its connection list:" >&2
		printf '%s\n' "$out" >&2; fail "$what"
	}
	printf '%s' "$out" | grep -q "$wanted" || {
		echo "--- what it drew:" >&2; printf '%s\n' "$out" >&2; fail "$what"
	}
	echo "ok: $what"
}

check "the server says what it is" "$ROOT/demo" "MySQL 8"
check "and which database it landed in" "$ROOT/demo" "connected: root@127.0.0.1:$PORT/demo"
# A database is a schema here, so what `#` switches between is the databases -
# and the one in use comes first, the way the other engines order theirs.
check "the database in use is the first schema" "$ROOT/demo" "schema demo"
check "another database is another schema" "$ROOT/demo" "schema archiv"
check "a table, with the row count the engine keeps" "$ROOT/demo" "table demo.zakaznici" zakaznici
check "a view is a view" "$ROOT/demo" "view demo.velke" zakaznici
check "a declared length is a length that is shown" "$ROOT/demo" "column jmeno varchar(80) NOT NULL" zakaznici
check "and so are the digits of a decimal" "$ROOT/demo" "column castka decimal(12,2)" objednavky
# AUTO_INCREMENT is a column attribute here rather than a type or a default, and
# the form asks for it where a default goes.
check "auto_increment says where its numbers come from" "$ROOT/demo" "default=AUTO_INCREMENT" zakaznici
check "the primary key is told from the other indexes" "$ROOT/demo" "PRIMARY (id)" zakaznici
check "a unique index over one column is one" "$ROOT/demo" "UNIQUE (email)" zakaznici
check "an index of its own" "$ROOT/demo" "index ix_mesto INDEX (mesto)" zakaznici
check "a foreign key, and what it does on delete" \
	"$ROOT/demo" "fk zakaznik_id -> zakaznici.id on delete CASCADE" objednavky
check "a row is addressed by its key" "$ROOT/demo" "row key: id (usable=true)" zakaznici
check "accented text survives the trip out" "$ROOT/demo" "jmeno=Řehoř Dvořák" zakaznici
check "a decimal keeps its digits" "$ROOT/demo" "castka=2499.50" objednavky
check "json comes back as it went in" "$ROOT/demo" "kanal" objednavky
check "paging reaches every row exactly once" "$ROOT/demo" "paged: 3 records, 3 distinct" zakaznici
# The session mode, which is what makes one shared quoting right for all three
# SQL engines - and it is worth checking that it is actually set rather than
# assumed.
check "the session runs in ANSI_QUOTES" "$ROOT/demo" "ANSI_QUOTES"
check "and without backslash escapes" "$ROOT/demo" "NO_BACKSLASH_ESCAPES"

check "a wrong password says so" \
	"mysql://root:nonsense@127.0.0.1:$PORT/demo" "Access denied"
check "a database that is not there says so" "$ROOT/neexistuje" "Unknown database"
check "a port with nothing behind it says what happened" \
	"mysql://root:$PASSWORD@127.0.0.1:3399/demo" "onnect"

screen "the grid draws the table" "Řehoř" '{sleep}' '{end}' '{enter}' '{sleep}'
screen "a batch is split and the last statement is what shows" "zbylo" \
	'{sleep}' 's' "select count(*) as zbylo from zakaznici" '{ctrl-s}' '{sleep}'
# ANSI_QUOTES is set on the session, which is what lets one shared quoting be
# right for all three SQL engines: "jmeno" is a name here and not a string.
screen "a double quoted name is a name, not a string" "Řehoř" \
	'{sleep}' 's' 'select "jmeno" from zakaznici' '{ctrl-s}' '{sleep}'
screen "a statement inside a transaction is inside it" "v_transakci" \
	'{sleep}' 's' "start transaction; delete from objednavky; select count(*) as v_transakci from objednavky" \
	'{ctrl-s}' '{sleep}'
echo 'SELECT count(*) FROM demo.objednavky' | $MYSQL -N 2>/dev/null | grep -qx 3 \
	|| fail "a transaction nobody committed changed the table anyway"
echo "ok: an uncommitted transaction leaves nothing behind"

# The cancel is a KILL QUERY down a second connection while the first is busy.
screen "a statement that will not finish can be stopped" "stopped\|given up\|nterrupt" \
	'{sleep}' 's' "select sleep(30)" '{ctrl-s}' '{sleep}' '{ctrl-c}' '{sleep}'
screen "and the connection is still good afterwards" "po_zruseni" \
	'{sleep}' 's' "select sleep(30)" '{ctrl-s}' '{sleep}' '{ctrl-c}' '{sleep}' \
	's' '{ctrl-u}' "select count(*) as po_zruseni from zakaznici" '{ctrl-s}' '{sleep}'

screen "an edited value keeps its accents" "Ludmila Čermáková-změna" \
	'{sleep}' '{end}' '{enter}' '{sleep}' '{down}' '{right}' 'e' '{ctrl-u}' 'Ludmila Čermáková-změna' '{enter}' '{sleep}'
printf "SELECT count(*) FROM demo.zakaznici WHERE jmeno = 'Ludmila Čermáková-změna'\n" | $MYSQL -N 2>/dev/null \
	| grep -qx 1 || fail "the accented value did not reach the table intact"
echo "ok: and the server has it, character for character"

echo "all good"
