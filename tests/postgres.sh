#!/bin/sh
# Bring up a PostgreSQL and check the driver against it:
#
#     zig build && ./tests/postgres.sh
#
# This one was the last engine to get a suite and had the most to lose by not
# having one: PostgreSQL and SQLite are what most people open, and everything
# else here - Kafka, S3, a cluster, SQL Server - was being checked against a
# real server while these two were not.
#
# What it looks for is what this driver does that the others do not: it reads
# through the catalogs rather than information_schema, it streams a result one
# row at a time, it has schemas that are not databases, and it can be asked to
# stop a statement that is still running.
set -e
cd "$(dirname "$0")/.."

NAME=${NAME:-krtek-postgres-test}
IMAGE=${IMAGE:-postgres:17-alpine}
PASSWORD=${PASSWORD:-krtek}
PORT=${PORT:-5433}

BIN=zig-out/bin/krtek
test -x "$BIN" || { echo "$BIN is not there - zig build first" >&2; exit 1; }

CONFIG=$(mktemp -d)
trap 'docker rm -f "$NAME" >/dev/null 2>&1 || true; rm -rf "$CONFIG"' EXIT
export XDG_CONFIG_HOME="$CONFIG"

echo "starting $IMAGE"
docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --name "$NAME" -p "$PORT:5432" -e "POSTGRES_PASSWORD=$PASSWORD" "$IMAGE" >/dev/null

# -i, or the heredoc below is written to a docker client that keeps it to itself
# and psql inside the container reads nothing at all.
#
# Over TCP rather than the socket, and that is the whole readiness check. The
# image builds its database by starting a server of its own first, one that
# listens on the socket and nothing else, running whatever init it has to, and
# then shutting it down and starting the real one. Ask over the socket and the
# answer is yes while that temporary server is up - and the first statement
# after it lands in the shutdown: `terminating connection due to administrator
# command`. Over TCP there is nothing to hear until the server that stays is
# listening.
PSQL="docker exec -i -e PGPASSWORD=$PASSWORD $NAME psql -h 127.0.0.1 -U postgres -v ON_ERROR_STOP=1"
printf 'waiting for the server'
tries=0
until $PSQL -c 'SELECT 1' >/dev/null 2>&1; do
	tries=$((tries + 1))
	if [ "$tries" -gt 60 ]; then
		echo " gave up" >&2; docker logs --tail 30 "$NAME" >&2; exit 1
	fi
	printf .
	sleep 1
done
echo " up"

$PSQL -c 'CREATE DATABASE demo' >/dev/null
$PSQL -d demo >/dev/null <<'SQL'
CREATE SCHEMA sklad;
CREATE TABLE zakaznici (
  id serial PRIMARY KEY,
  jmeno text NOT NULL,
  email text UNIQUE,
  mesto text,
  vernostni boolean NOT NULL DEFAULT false,
  zalozeno timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ix_mesto ON zakaznici (mesto);
CREATE TABLE objednavky (
  id serial PRIMARY KEY,
  zakaznik_id integer NOT NULL REFERENCES zakaznici(id) ON DELETE CASCADE,
  castka numeric(12,2) NOT NULL,
  stav text NOT NULL DEFAULT 'nova',
  data jsonb
);
CREATE VIEW velke AS SELECT id, castka FROM objednavky WHERE castka > 1000;
CREATE TABLE sklad.pohyby (id bigserial PRIMARY KEY, zmena integer NOT NULL);
INSERT INTO zakaznici (jmeno, email, mesto, vernostni) VALUES
 ('Řehoř Dvořák', 'rehor@example.cz', 'Ostrava', true),
 ('Ludmila Čermáková', 'ludmila@example.cz', 'Plzeň', false),
 ('Šimon Kučera', NULL, 'Liberec', false);
INSERT INTO objednavky (zakaznik_id, castka, data) VALUES
 (1, 2499.50, '{"kanal":"web"}'), (2, 129.00, NULL), (1, 8100.00, '{"kanal":"telefon"}');
SQL

# --- and now the driver ---

fail() { echo "FAIL: $1" >&2; exit 1; }

ROOT="postgres://postgres:$PASSWORD@127.0.0.1:$PORT"

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

check "the server says what it is" "$ROOT/demo" "PostgreSQL 17"
check "and which database it landed in" "$ROOT/demo" "connected: postgres@127.0.0.1:$PORT/demo"
# Schemas are not databases here, which is the thing this engine has and MySQL
# does not: `public` is where the tables are and `sklad` is one somebody made.
check "public is a schema" "$ROOT/demo" "schema public"
check "and so is one that was made" "$ROOT/demo" "schema sklad"
check "a table, with the planner's estimate of its size" "$ROOT/demo" "table public.zakaznici" zakaznici
check "a view is a view" "$ROOT/demo" "view public.velke" zakaznici
# format_type, not the raw pg_type name: `character varying` and not `varchar`.
check "a column's type is written the way psql writes it" "$ROOT/demo" "column castka numeric(12,2)" objednavky
check "a serial says where its numbers come from" "$ROOT/demo" "default=nextval" zakaznici
check "not null is read from the catalog" "$ROOT/demo" "column jmeno text NOT NULL" zakaznici
check "the primary key is told from the other indexes" "$ROOT/demo" "PRIMARY (id)" zakaznici
check "a unique index over one column is one" "$ROOT/demo" "UNIQUE (email)" zakaznici
check "an index of its own" "$ROOT/demo" "index ix_mesto INDEX (mesto)" zakaznici
check "a foreign key, and what it does on delete" \
	"$ROOT/demo" "fk zakaznik_id -> zakaznici.id on delete CASCADE" objednavky
check "a row is addressed by its key" "$ROOT/demo" "row key: id (usable=true)" zakaznici
check "accented text survives the trip out" "$ROOT/demo" "jmeno=Řehoř Dvořák" zakaznici
# numeric must not go through a float on the way to the screen.
check "a numeric keeps its digits" "$ROOT/demo" "castka=2499.50" objednavky
check "jsonb comes back as it went in" "$ROOT/demo" "kanal" objednavky
check "paging reaches every row exactly once" "$ROOT/demo" "paged: 3 records, 3 distinct" zakaznici
# A view has no key, so it is read-only rather than half-editable.
check "a view cannot be edited" "$ROOT/demo" "row key: - (usable=false)" velke
check "the settings come from the server" "$ROOT/demo" "search_path"

# libpq knows the difference between a server that wants a password and one that
# refused the password it got, and says which.
check "a wrong password says so" \
	"postgres://postgres:nonsense@127.0.0.1:$PORT/demo" "password authentication failed"
check "a database that is not there says so" \
	"$ROOT/neexistuje" "does not exist"
# libpq's own words, which say more than anything this could put in their place.
check "a port with nothing behind it says what happened" \
	"postgres://postgres:$PASSWORD@127.0.0.1:5599/demo" "Connection refused"

screen "the grid draws the table" "Řehoř" '{sleep}' '{end}' '{enter}' '{sleep}'
# A schema is picked from a list: `#`, a few letters of its name, and enter. It
# was a form with one field, turned a name at a time and sent with ctrl+s.
screen "# lists the schemas, with the one in force marked" "public .* now" '{sleep}' '#' '{sleep}'
screen "and enter moves to the one that was typed" "SCHEMA sklad" '{sleep}' '#' 'skl' '{enter}' '{sleep}'
screen "whose tables are then the ones listed" "pohyby" '{sleep}' '#' 'skl' '{enter}' '{sleep}'
screen "esc leaves the schema as it was" "SCHEMA public" '{sleep}' '#' 'skl' '{esc}' '{sleep}'
screen "a batch is split and the last statement is what shows" "zbylo" \
	'{sleep}' 's' "select count(*) as zbylo from zakaznici" '{ctrl-s}' '{sleep}'
# PostgreSQL runs a batch in one implicit transaction and reports only the last
# result, which is why the statements are split before they are sent.
screen "a statement inside a transaction is inside it" "v_transakci" \
	'{sleep}' 's' "begin; delete from objednavky; select count(*) as v_transakci from objednavky" \
	'{ctrl-s}' '{sleep}'
$PSQL -d demo -tAc 'SELECT count(*) FROM objednavky' | grep -qx 3 \
	|| fail "a transaction nobody committed changed the table anyway"
echo "ok: an uncommitted transaction leaves nothing behind"

# The cancel goes down a second connection while the first is still busy, which
# is the part that only a real server can show.
screen "a statement that will not finish can be stopped" "stopped\|given up\|cancel" \
	'{sleep}' 's' "select pg_sleep(30)" '{ctrl-s}' '{sleep}' '{ctrl-c}' '{sleep}'
screen "and the connection is still good afterwards" "po_zruseni" \
	'{sleep}' 's' "select pg_sleep(30)" '{ctrl-s}' '{sleep}' '{ctrl-c}' '{sleep}' \
	's' '{ctrl-u}' "select count(*) as po_zruseni from zakaznici" '{ctrl-s}' '{sleep}'

screen "an edited value keeps its accents" "Ludmila Čermáková-změna" \
	'{sleep}' '{end}' '{enter}' '{sleep}' '{down}' '{right}' 'e' '{ctrl-u}' 'Ludmila Čermáková-změna' '{enter}' '{sleep}'
$PSQL -d demo -tAc "SELECT count(*) FROM zakaznici WHERE jmeno = 'Ludmila Čermáková-změna'" \
	| grep -qx 1 || fail "the accented value did not reach the table intact"
echo "ok: and the server has it, character for character"

# The unit test that needs a server rather than a laptop: every schema statement
# this driver writes, run as written. It is where a trigger that was a syntax
# error would have been found, and where a table that numbers its own rows is
# altered - which PostgreSQL refused, whichever column the change was to.
echo "the unit tests that want a server"
zig build test -Dagainst="KRTEK_POSTGRES=$ROOT/demo"

# And the same two through the interface, where the statement is the form's.
# The trigger form used to write SQLite's dialect whatever it was talking to.
$PSQL -d demo >/dev/null <<'SQL'
CREATE TABLE zaznam (co text);
CREATE TABLE faktury (
  id integer GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  cislo text NOT NULL,
  velke text GENERATED ALWAYS AS (upper(cislo)) STORED
);
INSERT INTO faktury (cislo) VALUES ('f-1');
SQL
# Two statements, because a trigger here is a function and then the trigger.
screen "a trigger made in the form is one the server takes" "2 statements, 0 rows affected" \
	'{sleep}' 'T' 'hlidac' '{tab}' '{tab}' '{tab}' '{ctrl-u}' 'faktury' '{tab}' '{tab}' \
	"INSERT INTO zaznam VALUES (NEW.cislo)" '{ctrl-s}' '{sleep}'
$PSQL -d demo -c "INSERT INTO faktury (cislo) VALUES ('f-2')" >/dev/null
$PSQL -d demo -tAc 'SELECT co FROM zaznam' | grep -qx 'f-2' \
	|| fail "the trigger from the form did not fire"
echo "ok: and it fires"

# A column taken out of the alter form, which nothing was written for: the form
# closed, said nothing, and the column was still in the table. Only SQLite acted
# on it, because SQLite writes the table again from the columns it is handed.
# Two go here - `stara` is simply removed, and `cena` is removed with a new
# column put in under its name, which only works with the old one dropped first.
$PSQL -d demo >/dev/null <<'SQL'
CREATE TABLE sloupce (id integer PRIMARY KEY, nazev text NOT NULL, stara text, cena integer);
INSERT INTO sloupce VALUES (1, 'šroub', 'pryč', 5);
SQL
# The table is picked by name. Then eleven tabs to the third column's name: the
# table's own field, and five to a column. A row removed leaves the cursor on the
# one that moved up into its place.
screen "a column removed in the alter form is dropped" "3 statements, 0 rows affected" \
	'{sleep}' '/' 'sloupce' '{enter}' '{sleep}' 'a' '{sleep}' \
	'{tab}{tab}{tab}{tab}{tab}{tab}{tab}{tab}{tab}{tab}{tab}' '{ctrl-x}' '{ctrl-x}' \
	'{ctrl-n}' 'cena' '{ctrl-s}' '{sleep}'
$PSQL -d demo -tAc "SELECT string_agg(column_name || ' ' || data_type, ',' ORDER BY ordinal_position)
	FROM information_schema.columns WHERE table_name = 'sloupce'" \
	| grep -qx 'id integer,nazev text,cena text' || fail "the columns removed in the form are not what the table lost"
echo "ok: and the server no longer has it"

# The table's name is a field of that form as well, and the rename is the last
# statement of what the form writes. Nothing here is in a transaction, so where
# an earlier statement is refused the script stops and the table is still called
# what it was - which is the name the grid has to go on reading. `cena` has a
# NULL in it and is asked to have none: thirteen tabs to its `not null`.
called() {
	$PSQL -d demo -tAc "SELECT string_agg(tablename, ',' ORDER BY tablename) FROM pg_tables
		WHERE tablename IN ('sloupce', 'soucastky')"
}
screen "an alter refused before its rename leaves the grid on the table as it was" "sloupce  1-1 of 1" \
	'{sleep}' '/' 'sloupce' '{enter}' '{sleep}' 'a' '{sleep}' \
	'{ctrl-u}' 'soucastky' '{tab}{tab}{tab}{tab}{tab}{tab}{tab}{tab}{tab}{tab}{tab}{tab}{tab}' ' ' \
	'{ctrl-s}' '{sleep}'
called | grep -qx 'sloupce' || fail "a rename the script never reached was made anyway: $(called)"
echo "ok: and the server still has it under that name"

# And where it goes through, the grid reads the table by its new name. It went
# on asking for the old one: the list beside it showed the rename had worked,
# and the grid said `relation "public.sloupce" does not exist`.
screen "a table renamed in the alter form is read by its new name" "soucastky  1-1 of 1" \
	'{sleep}' '/' 'sloupce' '{enter}' '{sleep}' 'a' '{sleep}' \
	'{ctrl-u}' 'soucastky' '{ctrl-s}' '{sleep}'
called | grep -qx 'soucastky' || fail "the table renamed in the form is not what the server has: $(called)"
echo "ok: and that is what the server calls it"

echo "all good"
